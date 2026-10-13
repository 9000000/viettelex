// TextToolsTests — công cụ văn bản (HOA/thường/Hoa Đầu Từ/Hoa đầu câu/Xoá dấu) theo fixture
// chung Fixtures/text-tools.txt (cùng bộ ca với android TextToolsTests.kt) + luồng thay chữ
// trên proxy giả (vùng chọn / đoạn trước con trỏ / fail-safe / hoàn tác).
import XCTest

/// Proxy giả có vùng chọn: `before` + [selected] + `after`; insertText thay vùng chọn.
private final class SelProxy: TextProxyLike {
    var before: String
    var selected: String
    var after = ""
    var isSecure = false
    var fakeContext: String?? = nil
    var deletes = 0
    init(_ before: String, selected: String = "") { self.before = before; self.selected = selected }
    var text: String { before + selected + after }
    var contextBeforeInput: String? { fakeContext ?? before }
    var contextAfterInput: String? { after }
    var hasSelection: Bool { !selected.isEmpty }
    func insertText(_ t: String) { selected = ""; before += t }
    func deleteBackward() {
        deletes += 1
        if !selected.isEmpty { selected = ""; return }
        if !before.isEmpty { before.removeLast() }
    }
}

final class TextToolsTests: XCTestCase {

    private func decode(_ s: Substring) -> String {
        s.replacingOccurrences(of: "␣", with: " ").replacingOccurrences(of: "⏎", with: "\n")
    }

    func testFixture() throws {
        let url = try XCTUnwrap(Bundle(for: TextToolsTests.self)
            .url(forResource: "text-tools", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var n = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "|", omittingEmptySubsequences: false)
            XCTAssertEqual(c.count, 3, "dòng fixture lạ: \(line)")
            let opParts = c[0].split(separator: "@")
            let tool = try XCTUnwrap(TextTool(rawValue: String(opParts[0])), "op lạ \(c[0])")
            var input = decode(c[1])
            if opParts.count > 1 { input = input.decomposedStringWithCanonicalMapping }
            let expected = decode(c[2])
            let got = TextTools.apply(tool, input)
            // so từng scalar: kết quả phải đúng NFC, không chỉ tương đương chuẩn
            XCTAssertEqual(Array(got.unicodeScalars), Array(expected.unicodeScalars),
                           "\(c[0]) «\(input)» → «\(got)», cần «\(expected)»")
            n += 1
        }
        XCTAssertGreaterThan(n, 140)
    }

    /// 67 chữ có dấu × hoa/thường = 134: khứ hồi HOA ⇄ thường, xoá dấu ra đúng chữ gốc.
    func testAllVietnameseLettersRoundTrip() {
        let tones = ["\u{300}", "\u{301}", "\u{303}", "\u{309}", "\u{323}"]
        var lower: [String] = []
        for v in "aăâeêioôơuưy" {
            if !"aeiouy".contains(v) { lower.append(String(v)) }
            for t in tones { lower.append((String(v) + t).precomposedStringWithCanonicalMapping) }
        }
        lower.append("đ")
        XCTAssertEqual(lower.count, 67)
        let base: [Character: String] = ["ă": "a", "â": "a", "ê": "e", "ô": "o", "ơ": "o", "ư": "u", "đ": "d"]
        for l in lower {
            let u = TextTools.apply(.upper, l)
            XCTAssertEqual(u.unicodeScalars.count, 1, "«\(l)» HOA phải là 1 ký tự dựng sẵn")
            XCTAssertNotEqual(u, l)
            XCTAssertEqual(TextTools.apply(.lower, u), l)
            XCTAssertEqual(TextTools.apply(.upper, u), u)
            XCTAssertEqual(TextTools.apply(.title, l), u)
            XCTAssertEqual(TextTools.apply(.sentence, u), u)
            // NFD vào vẫn ra NFC
            XCTAssertEqual(Array(TextTools.apply(.upper, l.decomposedStringWithCanonicalMapping).unicodeScalars),
                           Array(u.unicodeScalars))
            let plain = TextTools.apply(.stripDiacritics, l)
            let first = l.decomposedStringWithCanonicalMapping.unicodeScalars.first.map { Character($0) }!
            XCTAssertEqual(plain, base[first] ?? base[Character(l)] ?? String(first), "xoá dấu «\(l)»")
            XCTAssertEqual(TextTools.apply(.stripDiacritics, u), plain.uppercased())
        }
    }

    // MARK: nguồn chữ

    func testSourcePrefersSelection() {
        XCTAssertEqual(TextTools.source(selected: "chào", before: "xin "),
                       .init(text: "chào", isSelection: true))
        // chọn toàn khoảng trắng / số → dùng đoạn trước con trỏ
        XCTAssertEqual(TextTools.source(selected: "  ", before: "xin chào"),
                       .init(text: "xin chào", isSelection: false))
    }

    func testSourceStopsAtNewline() {
        XCTAssertEqual(TextTools.source(selected: nil, before: "dòng một\ndòng hai "),
                       .init(text: "dòng hai ", isSelection: false))
        XCTAssertEqual(TextTools.source(selected: nil, before: "a\r\nbé"),
                       .init(text: "bé", isSelection: false))
        XCTAssertNil(TextTools.source(selected: nil, before: "chữ\n"))
        XCTAssertNil(TextTools.source(selected: nil, before: "123 !"))
        XCTAssertNil(TextTools.source(selected: nil, before: nil))
        XCTAssertNil(TextTools.source(selected: nil, before: ""))
    }

    func testSourceTruncatedDropsPartialWord() {
        XCTAssertEqual(TextTools.source(selected: nil, before: "ếng việt", truncatedStart: true),
                       .init(text: "việt", isSelection: false))
        XCTAssertNil(TextTools.source(selected: nil, before: "ếng", truncatedStart: true))
        // có xuống dòng thì không cần cắt
        XCTAssertEqual(TextTools.source(selected: nil, before: "x\nếng việt", truncatedStart: true),
                       .init(text: "ếng việt", isSelection: false))
    }

    // MARK: luồng thay chữ

    func testReplaceBeforeCursorAndUndo() {
        let p = SelProxy("Mở đầu\nxin chào thế giới")
        guard case .applied(let u) = TextToolRunner.apply(.upper, proxy: p, selectedText: nil) else {
            return XCTFail("phải áp")
        }
        XCTAssertEqual(p.text, "Mở đầu\nXIN CHÀO THẾ GIỚI")
        XCTAssertEqual(u, .init(original: "xin chào thế giới", result: "XIN CHÀO THẾ GIỚI"))
        XCTAssertTrue(TextToolRunner.undo(u, proxy: p))
        XCTAssertEqual(p.text, "Mở đầu\nxin chào thế giới")
    }

    func testReplaceSelectionOnlyTouchesSelection() {
        let p = SelProxy("Tôi nói ", selected: "tiếng việt")
        p.after = " hay"
        guard case .applied(let u) = TextToolRunner.apply(.stripDiacritics, proxy: p,
                                                           selectedText: p.selected) else {
            return XCTFail("phải áp")
        }
        XCTAssertEqual(p.text, "Tôi nói tieng viet hay")
        XCTAssertEqual(p.deletes, 0, "vùng chọn: insertText thay thẳng, không xoá")
        XCTAssertTrue(TextToolRunner.undo(u, proxy: p))
        XCTAssertEqual(p.text, "Tôi nói tiếng việt hay")
    }

    func testUnchangedDoesNothing() {
        let p = SelProxy("ĐÃ HOA")
        XCTAssertEqual(TextToolRunner.apply(.upper, proxy: p, selectedText: nil), .unchanged)
        XCTAssertEqual(p.deletes, 0)
        XCTAssertEqual(TextToolRunner.apply(.upper, proxy: SelProxy("\n"), selectedText: nil), .noSource)
    }

    func testFailsafeNFDFieldNoDelete() {
        // Ô NFD: deleteBackward × Character sẽ cắt vào dấu tổ hợp → không động vào.
        let nfd = "tiếng việt".decomposedStringWithCanonicalMapping
        let p = SelProxy(nfd)
        XCTAssertEqual(TextToolRunner.apply(.upper, proxy: p, selectedText: nil), .failsafe)
        XCTAssertEqual(p.deletes, 0)
        XCTAssertEqual(Array(p.text.unicodeScalars), Array(nfd.unicodeScalars))
    }

    func testFailsafeContextChangedBetweenReads() {
        // Đọc lần đầu thấy "abc xyz", lúc kiểm trước khi xoá context đã lệch → không xoá.
        final class Shifty: TextProxyLike {
            var reads = 0
            var text = "abc xyz"
            var isSecure = false
            var contextBeforeInput: String? { reads += 1; return reads == 1 ? text : "khác hẳn" }
            var contextAfterInput: String? { nil }
            var hasSelection = false
            func insertText(_ t: String) { text += t }
            func deleteBackward() { text.removeLast() }
        }
        let p = Shifty()
        XCTAssertEqual(TextToolRunner.apply(.upper, proxy: p, selectedText: nil), .failsafe)
        XCTAssertEqual(p.text, "abc xyz")
    }

    func testUndoRefusesWhenTextMoved() {
        let p = SelProxy("xin chào")
        guard case .applied(let u) = TextToolRunner.apply(.title, proxy: p, selectedText: nil) else {
            return XCTFail()
        }
        XCTAssertEqual(p.text, "Xin Chào")
        p.before += "!"                                   // người dùng gõ thêm
        XCTAssertFalse(TextToolRunner.undo(u, proxy: p))
        XCTAssertEqual(p.text, "Xin Chào!")
        p.fakeContext = .some(nil)                        // host không cho biết → không xoá mù
        p.before = "Xin Chào"
        XCTAssertFalse(TextToolRunner.undo(u, proxy: p))
        XCTAssertEqual(p.text, "Xin Chào")
    }

    // MARK: công tắc "Công cụ văn bản" (mặc định BẬT) — hiện thật = Plus mở VÀ công tắc bật

    func testSwitchDefaultOnAndEffectiveFlag() {
        XCTAssertTrue(KeyboardSettings().textToolsEnabled, "mặc định BẬT — người dùng cũ không đổi gì")
        var s = KeyboardSettings()
        XCTAssertTrue(s.textToolsActive(unlocked: true))
        XCTAssertFalse(s.textToolsActive(unlocked: false))
        s.textToolsEnabled = false
        XCTAssertFalse(s.textToolsActive(unlocked: true))
        XCTAssertFalse(s.textToolsActive(unlocked: false))
        // Màn Plus / Gõ tắt ghi ĐÚNG key bàn phím đọc.
        XCTAssertEqual(PlusFeature.textTools.settingKey, "textToolsEnabled")
        XCTAssertTrue(PlusFeature.textTools.settingDefault)
        XCTAssertFalse(PlusFeature.sentenceDiacritics.settingDefault)
        let saved = UserDefaultsProvider.shared
        defer { UserDefaultsProvider.shared = saved }
        let d = KeyboardBenchTests.makeDefaults("TT")
        UserDefaultsProvider.shared = d
        XCTAssertTrue(KeyboardSettings.load().textToolsEnabled, "chưa đặt ⇒ BẬT")
        d.set(false, forKey: PlusFeature.textTools.settingKey!)
        XCTAssertFalse(KeyboardSettings.load().textToolsEnabled)
    }

    func testSwitchInBackup() throws {
        guard case .bool(true)? = BackupSettings.byKey["textToolsEnabled"]?.kind else {
            return XCTFail("thiếu spec sao lưu textToolsEnabled (bool, mặc định true)")
        }
        var p = BackupPayload(createdAt: nil, platform: "ios", settings: ["textToolsEnabled": .bool(false)],
                              shortcuts: [:], templates: nil, learnedWords: nil)
        XCTAssertEqual(try BackupCodec.decode(BackupCodec.encode(p)), p)
        p.settings = ["textToolsEnabled": .bool(true)]
        XCTAssertEqual(try BackupCodec.decode(BackupCodec.encode(p)).settings?["textToolsEnabled"], .bool(true))
    }

    /// Luồng thật: công tắc tắt ⇒ bàn phím không có chip công cụ (lần hiện kế tiếp đọc lại).
    @MainActor func testKeyboardHonoursSwitch() {
        let saved = UserDefaultsProvider.shared
        let savedPaywall = PlusGate.paywallEnabled
        defer { UserDefaultsProvider.shared = saved; PlusGate.paywallEnabled = savedPaywall }
        PlusGate.paywallEnabled = false                     // Plus mở cho mọi người
        for on in [true, false] {
            let d = KeyboardBenchTests.makeDefaults("TT")
            d.set(on, forKey: "textToolsEnabled")
            UserDefaultsProvider.shared = d
            let rig = KeyboardBenchTests.Rig()
            XCTAssertEqual(rig.vc.debugKeyboard.textToolsEnabled, on, "textToolsEnabled=\(on)")
            rig.close()
        }
    }
}
