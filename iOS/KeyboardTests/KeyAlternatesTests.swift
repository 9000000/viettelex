// KeyAlternatesTests — giữ phím chữ ra số / ký hiệu (issue #98). Bảng theo fixture chung
// Fixtures/key-alternates.txt (android KeyAlternatesTests.kt đọc cùng file).
import XCTest
import UIKit

final class KeyAlternatesTests: XCTestCase {
    private func fixture() throws -> [(group: String, key: Character, alt: String)] {
        let url = try XCTUnwrap(Bundle(for: KeyAlternatesTests.self)
            .url(forResource: "key-alternates", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { l in
                let c = l.split(separator: "\t").map(String.init)
                return (c[0], Character(c[1]), c[2])
            }
    }

    func testTablesMatchSharedFixture() throws {
        let f = try fixture()
        var digits: [Character: String] = [:], symbols: [Character: String] = [:]
        for r in f { if r.group == "numbers" { digits[r.key] = r.alt } else { symbols[r.key] = r.alt } }
        XCTAssertEqual(digits, KeyAlternates.digits)
        XCTAssertEqual(symbols, KeyAlternates.symbols)
        XCTAssertEqual(Set(digits.keys), Set("qwertyuiop"))
        XCTAssertEqual(Set(symbols.keys), Set("asdfghjklzxcvbnm"))
    }

    func testNoDuplicateAndNoLetters() {
        let all = Array(KeyAlternates.digits.values) + Array(KeyAlternates.symbols.values)
        XCTAssertEqual(Set(all).count, all.count, "không trùng ký tự phụ")
        for a in all { XCTAssertFalse(a.first!.isLetter, a) }
        // Bản Việt: ' ; ít dùng → % / (ngày tháng, link); $ thay ₫ (₫ ở bàn ký hiệu).
        XCTAssertEqual(KeyAlternates.symbols["d"], "$")
        XCTAssertEqual(KeyAlternates.symbols["c"], "%")
        XCTAssertEqual(KeyAlternates.symbols["b"], "/")
    }

    /// Giữ "," ra "." khi có ít nhất một công tắc giữ phím đang có hiệu lực.
    func testCommaHoldGating() {
        func on(_ n: Bool, _ s: Bool, row: Bool = false, pad: Bool = false, ax: Bool = false) -> Bool {
            KeyAlternates.commaHold(alternates: KeyAlternates.map(numbers: n, symbols: s, numberRow: row,
                                                                  isPad: pad, accessibility: ax))
        }
        XCTAssertTrue(on(true, false))
        XCTAssertTrue(on(false, true))
        XCTAssertTrue(on(true, true))
        XCTAssertFalse(on(false, false))
        XCTAssertFalse(on(true, false, row: true), "công tắc số không hiệu lực khi hàng số bật")
        XCTAssertTrue(on(true, true, row: true))
        XCTAssertFalse(on(true, true, pad: true), "iPad không đổi")
        XCTAssertFalse(on(true, true, ax: true))
        XCTAssertEqual(KeyAlternates.commaAlt, ".")
    }

    func testHoldCommaSwapsPendingCommit() {
        let q = KeyCommitQueue(), id = ObjectIdentifier(q)
        var out = ""
        q.arm(id) { out += "," }
        XCTAssertTrue(KeyAlternates.holdComma(q, id: id) { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ".")
        out = ""
        q.arm(id) { out += "," }
        q.flush()                                               // ngón khác chạm trước khi đủ giờ
        XCTAssertFalse(KeyAlternates.holdComma(q, id: id) { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ",", "đã chốt phẩy thì hết giờ không đổi gì")
    }

    /// "." giữ từ "," chốt từ đang gõ y như "," (cùng đường .text → boundary).
    func testCommaHoldPeriodCommitsComposition() {
        for punct in [",", "."] {
            let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings())
            for ch in "tieengs" { b.letter(ch, proxy: p) }
            XCTAssertTrue(b.isComposing)
            b.boundary(punct, proxy: p)
            XCTAssertFalse(b.isComposing)
            XCTAssertEqual(p.text, "tiếng" + punct)
        }
    }

    func testMapGating() {
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: false, numberRow: false), KeyAlternates.digits)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: false, numberRow: true).isEmpty,
                      "hàng số bật ⇒ giữ q ra số vô nghĩa")
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: true, numberRow: true), KeyAlternates.symbols)
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: true, numberRow: false).count, 26)
        XCTAssertTrue(KeyAlternates.map(numbers: false, symbols: false, numberRow: false).isEmpty)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: true, numberRow: false, isPad: true).isEmpty)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: true, numberRow: false, accessibility: true).isEmpty)
        XCTAssertTrue(KeyAlternates.numbersSettingVisible(numberRow: false))
        XCTAssertFalse(KeyAlternates.numbersSettingVisible(numberRow: true))
    }

    func testHoldStateMachine() {
        var h = KeyAlternates.Hold(alt: "3", start: .zero)
        XCTAssertFalse(h.move(to: CGPoint(x: 6, y: 6)))       // trong slop
        XCTAssertNil(h.commit)                                  // chưa đủ giờ = chạm thường
        XCTAssertTrue(h.fire())
        XCTAssertEqual(h.commit, "3")
        XCTAssertFalse(h.move(to: CGPoint(x: 80, y: 0)))       // đã bắn: trôi không hủy
        h.cancel()
        XCTAssertEqual(h.commit, "3")

        var d = KeyAlternates.Hold(alt: "@", start: .zero)
        XCTAssertTrue(d.move(to: CGPoint(x: KeyAlternates.slop + 1, y: 0)))
        XCTAssertFalse(d.fire(), "trôi trước khi đủ giờ ⇒ không bao giờ thành ký tự phụ")
        XCTAssertNil(d.commit)

        var c = KeyAlternates.Hold(alt: "@", start: .zero)
        c.cancel()                                              // ngón khác / thành vuốt
        XCTAssertFalse(c.fire())
    }

    func testThresholdBetweenTrackpadAndOtherHolds() {
        XCTAssertGreaterThan(KeyAlternates.holdDelay, 0.3)
        XCTAssertLessThan(KeyAlternates.holdDelay, 0.45)
    }

    /// Luồng controller cho .replaceLastLetter: huỷ đúng phím chữ (checkpoint, không ⌫) rồi
    /// chốt từ + chèn ký tự phụ như gõ hàng số.
    func testRollbackKeepsTelexComposition() {
        let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings())
        for ch in "tie" { b.letter(ch, proxy: p) }
        b.letter("e", proxy: p)                                 // chạm e: "tiê"
        XCTAssertEqual(p.text, "tiê")
        XCTAssertTrue(b.undoLastLetter(proxy: p))
        b.boundary("3", proxy: p)
        XCTAssertEqual(p.text, "tie3")
        b.letter("a", proxy: p)                                 // từ mới sau ký tự phụ
        XCTAssertEqual(p.text, "tie3a")

        let p2 = MockProxy(), b2 = EngineBridge(settings: KeyboardSettings())
        for ch in "tieng" { b2.letter(ch, proxy: p2) }
        b2.letter("s", proxy: p2)                               // phím dấu: "tiéng"
        XCTAssertTrue(b2.undoLastLetter(proxy: p2))
        b2.boundary("#", proxy: p2)
        XCTAssertEqual(p2.text, "tieng#")
    }

    // MARK: KeyboardView (iPhone)

    @MainActor private func makeKeyboard(numbers: Bool, symbols: Bool, numberRow: Bool = false,
                                         side: SpaceSideKey = .comma,
                                         log: @escaping (String) -> Void) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { k in
            switch k {
            case .letter(let c): log("L\(c.lowercased())")   // shift đầu ô bật sẵn
            case .replaceLastLetter(let s): log("R\(s)")
            case .text(let s): log("T\(s)")
            default: log("?")
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.numberRowEnabled = numberRow
        kb.spaceSideKey = side
        kb.configureKeyAlternates(numbers: numbers, symbols: symbols)
        kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor func testHoldReplacesLetterWithAlternate() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad dùng vuốt xuống")
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: true) { out.append($0) }
        XCTAssertEqual(kb.debugAltHint("e"), "3")
        XCTAssertEqual(kb.debugAltHint("a"), "@")
        XCTAssertTrue(kb.debugHold("e"))
        XCTAssertEqual(out.suffix(2), ["Le", "R3"])
        out = []
        kb.debugHold("e", fire: false)                          // nhả trước khi đủ giờ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("e", drift: 30)                            // trôi ⇒ không phải giữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("m")
        XCTAssertEqual(out, ["Lm", "R?"])
        withExtendedLifetime(host) {}
    }

    /// Đã bắn mà ngón khác chạm: ký tự phụ chốt TRƯỚC phím mới (checkpoint đúng phím).
    @MainActor func testSecondTouchAfterFireCommitsAlternateFirst() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { out.append($0) }
        kb.debugHold("q", secondTouch: "a")
        XCTAssertEqual(out, ["Lq", "R1", "La"])
        withExtendedLifetime(host) {}
    }

    @MainActor func testOffMeansNoHintsNoTimer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: false, symbols: false) { out.append($0) }
        XCTAssertNil(kb.debugAltHint("q"))
        XCTAssertFalse(kb.debugHold("q"), "tắt ⇒ không hẹn giờ")
        XCTAssertEqual(out, ["Lq"])
        XCTAssertFalse(kb.altHoldActive)
        // Hàng số bật ⇒ công tắc số không còn tác dụng; ký hiệu vẫn chạy.
        let (kb2, host2) = makeKeyboard(numbers: true, symbols: true, numberRow: true) { _ in }
        XCTAssertNil(kb2.debugAltHint("q"))
        XCTAssertEqual(kb2.debugAltHint("s"), "#")
        withExtendedLifetime((host, host2)) {}
    }

    @MainActor func testCommaHoldTypesPeriod() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { out.append($0) }
        XCTAssertEqual(kb.debugCommaHint, ".")
        XCTAssertTrue(kb.debugCommaHold())
        XCTAssertEqual(out, ["T."])
        out = []
        kb.debugCommaHold(fire: false)                          // nhả trước khi đủ giờ
        XCTAssertEqual(out, ["T,"])
        out = []
        kb.debugCommaHold(secondTouch: "a")                     // đã bắn: "." chốt TRƯỚC phím mới
        XCTAssertEqual(out, ["T.", "La"])
        out = []
        kb.debugCommaHold(secondTouch: "a", secondBeforeFire: true)   // ngón khác chạm trước khi đủ giờ
        XCTAssertEqual(out, ["T,", "La"])
        withExtendedLifetime(host) {}
    }

    @MainActor func testCommaHoldOffIsPlainComma() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: false, symbols: false) { out.append($0) }
        XCTAssertNil(kb.debugCommaHint)
        XCTAssertFalse(kb.debugCommaHold(), "tắt ⇒ không hẹn giờ")
        XCTAssertEqual(out, ["T,"])
        out = []
        // Chỉ công tắc số mà hàng số bật ⇒ không có hiệu lực ⇒ "," thường.
        let (kb2, host2) = makeKeyboard(numbers: true, symbols: false, numberRow: true) { out.append($0) }
        XCTAssertNil(kb2.debugCommaHint)
        XCTAssertFalse(kb2.debugCommaHold())
        XCTAssertEqual(out, ["T,"])
        // Chỉ ký hiệu ⇒ bật.
        let (kb3, host3) = makeKeyboard(numbers: false, symbols: true) { _ in }
        XCTAssertEqual(kb3.debugCommaHint, ".")
        withExtendedLifetime((host, host2, host3)) {}
    }

    @MainActor func testVoiceOverDisablesAlternates() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host) = makeKeyboard(numbers: true, symbols: true) { _ in }
        kb.altAccessibility = true
        kb.layoutIfNeeded()
        XCTAssertNil(kb.debugAltHint("q"))
        XCTAssertNil(kb.debugCommaHint)
        XCTAssertFalse(kb.altHoldActive)
        withExtendedLifetime(host) {}
    }

    // MARK: KeyboardView (iPad) — giữ phím chữ = ký tự phụ in trên phím (bug Phil 27/09:
    // giữ "w" không ra "2"; trước chỉ vuốt xuống được).

    @MainActor private func makePadKeyboard(log: @escaping (String) -> Void) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: true, inputController: nil) { k in
            switch k {
            case .letter(let c): log("L\(c.lowercased())")
            case .replaceLastLetter(let s): log("R\(s)")
            case .text(let s): log("T\(s)")
            default: log("?")
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 834, height: 300))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.configureKeyAlternates(numbers: false, symbols: false)   // công tắc iPhone không ảnh hưởng iPad
        kb.layoutIfNeeded()
        return (kb, host)
    }

    func testPadMapIsTheHintPrintedOnKeys() {
        XCTAssertEqual(KeyAlternates.padMap().count, 26)
        XCTAssertEqual(KeyAlternates.padMap()["w"], "2")
        XCTAssertEqual(KeyAlternates.padMap()["a"], "@")
        XCTAssertEqual(KeyAlternates.padMap()["f"], "&", "bảng iPad khác iPhone (f → _)")
        for (k, v) in KeyAlternates.padHints { XCTAssertEqual(KeyboardView.padSecondary[String(k)], v) }
    }

    /// Giữ phím 2 tầng "?." / "!," trên trang chữ iPad rồi nhấc ⇒ balloon phải tắt
    /// (trước đây kẹt lại trên phím — Phil 27/09).
    @MainActor func testPadPunctHoldHidesBalloonOnRelease() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makePadKeyboard { out.append($0) }
        _ = host
        for label in [".", ","] {
            let b = try XCTUnwrap(kb.debugControl(label) as? UIControl, label)
            b.sendActions(for: .touchDown)
            kb.debugChoosePadAlt(b)
            XCTAssertTrue(kb.debugBalloonVisible, "\(label): giữ ⇒ balloon hiện")
            b.sendActions(for: .touchUpInside)
            XCTAssertFalse(kb.debugBalloonVisible, "\(label): nhấc ⇒ balloon tắt")
        }
        XCTAssertEqual(out, ["T?", "T!"])
    }

    @MainActor func testPadHoldTypesHint() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makePadKeyboard { out.append($0) }
        XCTAssertTrue(kb.altHoldActive, "iPad: nhãn luôn hiện ⇒ giữ luôn bật")
        XCTAssertEqual(kb.debugPadHint("w") ?? kb.debugPadHint("W"), "2")
        XCTAssertTrue(kb.debugHold("w"))
        XCTAssertEqual(out, ["Lw", "R2"])
        out = []
        kb.debugHold("a")
        XCTAssertEqual(out, ["La", "R@"])
        out = []
        kb.debugHold("e")                                        // "tie" + giữ e ⇒ R3 (rollback ở bridge)
        XCTAssertEqual(out, ["Le", "R3"])
        out = []
        kb.debugHold("e", fire: false)                          // chạm thường ⇒ chữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("e", drift: 30)                            // trôi ngang ⇒ không phải giữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("q", secondTouch: "s")                     // đã bắn: chốt "1" trước phím mới
        XCTAssertEqual(out, ["Lq", "R1", "Ls"])
        // Vuốt xuống vẫn ra ký tự phụ (không cần đợi giờ giữ).
        out = []
        let x = try XCTUnwrap(kb.debugLetterFrame("x"))
        let c = CGPoint(x: x.midX, y: x.midY)
        kb.debugTouch(from: c, through: [CGPoint(x: c.x, y: c.y + 12), CGPoint(x: c.x, y: c.y + 25)], start: 10)
        XCTAssertEqual(out, ["Lx", "R-"])
        // Chạm thường.
        out = []
        kb.debugTouch(from: c, through: [], start: 20)
        XCTAssertEqual(out, ["Lx"])
        withExtendedLifetime(host) {}
    }

    /// Toàn luồng như controller: "tie" + giữ e trên iPad ⇒ huỷ đúng phím e (checkpoint,
    /// không ⌫) rồi chốt "3" ⇒ "tie3" (giống iPhone).
    @MainActor func testPadHoldRollbackThroughBridge() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let p = MockProxy(), br = EngineBridge(settings: KeyboardSettings())
        for ch in "tie" { br.letter(ch, proxy: p) }
        let kb = KeyboardView(needsGlobe: true, inputController: nil) { k in
            switch k {
            case .letter(let c): br.letter(Character(c.lowercased()), proxy: p)
            case .replaceLastLetter(let s): if br.undoLastLetter(proxy: p) { _ = br.boundary(s, proxy: p) }
            default: break
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 834, height: 300))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.layoutIfNeeded()
        kb.debugHold("e")
        XCTAssertEqual(p.text, "tie3")
        withExtendedLifetime(host) {}
    }

    /// Bàn chữ iPad: không phím "," riêng cạnh space (stock), không giữ "," ra ".".
    @MainActor func testPadLettersBottomRowHasNoComma() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host) = makePadKeyboard { _ in }
        for compact in [false, true] {
            kb.debugSetPadStyle(compact: compact)
            kb.layoutIfNeeded()
            let rows = kb.debugRowLabels()
            XCTAssertEqual(rows.last?.count, 6, "\(rows.last ?? [])")
            XCTAssertFalse(rows.last?.contains(",") ?? true)
            XCTAssertEqual(rows.last?.first, "Bàn phím tiếp theo")
            XCTAssertEqual(rows.last?[3], "Dấu cách")
            XCTAssertNil(kb.debugCommaHint)
        }
        withExtendedLifetime(host) {}
    }

    // MARK: "Phím cạnh dấu cách" (16/10/2026) — Dấu phẩy (mặc định) / Dấu chấm / Tắt

    func testSpaceSideKeyPure() {
        XCTAssertEqual(SpaceSideKey.defaultValue, .comma)
        XCTAssertEqual(SpaceSideKey.parse(nil), .comma)
        XCTAssertEqual(SpaceSideKey.parse("dot"), .comma)
        XCTAssertEqual(SpaceSideKey.parse(3), .comma)
        XCTAssertEqual(SpaceSideKey.parse("period"), .period)
        XCTAssertEqual(SpaceSideKey.parse("off"), .off)
        XCTAssertEqual(SpaceSideKey.key, "spaceSideKey")   // cùng khoá Android Keys.SPACE_SIDE_KEY
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.comma), [","])
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.period), ["."])
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.off), [])
        XCTAssertEqual(SpaceSideKey.comma.holdAlt, ".")
        XCTAssertEqual(SpaceSideKey.period.holdAlt, ",")
        XCTAssertNil(SpaceSideKey.off.holdAlt)
        // Sao lưu: có Spec, mặc định "comma", chỉ 3 giá trị.
        let spec = BackupSettings.all.first { $0.key == SpaceSideKey.key }
        XCTAssertNotNil(spec)
        if case .string(let def, let allowed)? = spec?.kind {
            XCTAssertEqual(def, "comma")
            XCTAssertEqual(Set(allowed), Set(SpaceSideKey.allCases.map(\.rawValue)))
        } else { XCTFail("spaceSideKey phải là .string") }
    }

    func testHoldCommaCustomAlt() {
        let q = KeyCommitQueue(), id = ObjectIdentifier(q)
        var out = ""
        q.arm(id) { out += "." }
        XCTAssertTrue(KeyAlternates.holdComma(q, id: id, alt: ",") { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ",")
    }

    @MainActor private func punctsRightOfSpace(_ kb: KeyboardView) -> [String] {
        let row = kb.debugRowLabels().last ?? []
        guard let si = row.firstIndex(of: "Dấu cách") else { return ["?"] }
        return row[(si + 1)...].filter { [",", ".", "@", "/"].contains($0) }
    }

    @MainActor func testSpaceSideKeyBottomRow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { _ in }
        XCTAssertEqual(kb.spaceSideKey, .comma, "mặc định = bố cục cũ")
        XCTAssertEqual(punctsRightOfSpace(kb), [","])
        let row0 = kb.debugRowLabels().last ?? []
        let space0 = try XCTUnwrap(kb.debugControl("Dấu cách"))
        let commaW = try XCTUnwrap(kb.debugKeyButton(",")).bounds.width
        XCTAssertEqual(commaW, 390 * KeyLayout.phoneLettersComma, accuracy: 1)
        let spaceW0 = space0.bounds.width

        let (kbP, hostP) = makeKeyboard(numbers: true, symbols: false, side: .period) { _ in }
        XCTAssertEqual(punctsRightOfSpace(kbP), ["."])
        XCTAssertEqual((kbP.debugRowLabels().last ?? []).count, row0.count, "cùng số phím")
        let dot = try XCTUnwrap(kbP.debugKeyButton("."))
        XCTAssertEqual(dot.bounds.width, commaW, accuracy: 0.5, "cùng cỡ phím ','")
        XCTAssertEqual(try XCTUnwrap(kbP.debugControl("Dấu cách")).bounds.width, spaceW0, accuracy: 0.5)

        let (kbO, hostO) = makeKeyboard(numbers: true, symbols: false, side: .off) { _ in }
        XCTAssertEqual(punctsRightOfSpace(kbO), [])
        XCTAssertNil(kbO.debugKeyButton(","))
        XCTAssertNil(kbO.debugKeyButton("."))
        XCTAssertEqual((kbO.debugRowLabels().last ?? []).count, row0.count - 1)
        XCTAssertGreaterThan(try XCTUnwrap(kbO.debugControl("Dấu cách")).bounds.width, spaceW0 + commaW - 1)
        // Đổi tuỳ chọn khi đang hiện ⇒ dựng lại hàng đáy.
        kb.spaceSideKey = .off
        XCTAssertEqual(punctsRightOfSpace(kb), [])
        kb.spaceSideKey = .period
        XCTAssertEqual(punctsRightOfSpace(kb), ["."])
        withExtendedLifetime((hostP, hostO)) {}

        // Ô email / URL / thanh địa chỉ: giữ nguyên dù tuỳ chọn nào.
        for side in SpaceSideKey.allCases {
            kb.spaceSideKey = side
            kb.configureInputKind(.email); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), ["@", "."], "\(side)")
            kb.configureInputKind(.url); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), [".", "/"], "\(side)")
            kb.configureInputKind(.search); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), ["."], "\(side)")
            kb.configureInputKind(.normal); kb.layoutIfNeeded()
        }
        withExtendedLifetime(host) {}
    }

    /// Dấu chấm: giữ "." ra "," (nhãn "," nhỏ góc phím), chạm thường ra ".".
    @MainActor func testPeriodSideKeyHoldTypesComma() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, side: .period) { out.append($0) }
        XCTAssertEqual(kb.debugCommaHint, ",")
        XCTAssertTrue(kb.debugCommaHold())
        XCTAssertEqual(out, ["T,"])
        out = []
        kb.debugCommaHold(fire: false)
        XCTAssertEqual(out, ["T."])
        out = []
        kb.debugCommaHold(secondTouch: "a")
        XCTAssertEqual(out, ["T,", "La"])
        // Giữ phím ra ký tự phụ tắt ⇒ "." thường, không nhãn.
        out = []
        let (kb2, host2) = makeKeyboard(numbers: false, symbols: false, side: .period) { out.append($0) }
        XCTAssertNil(kb2.debugCommaHint)
        XCTAssertFalse(kb2.debugCommaHold())
        XCTAssertEqual(out, ["T."])
        // Tắt ⇒ không có phím để giữ.
        kb2.spaceSideKey = .off
        kb2.layoutIfNeeded()
        XCTAssertFalse(kb2.debugCommaHold())
        withExtendedLifetime((host, host2)) {}
    }
}
