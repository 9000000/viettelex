import XCTest

/// Thứ tự ưu tiên slot thanh gợi ý (SuggestionSlots) — CÙNG bảng ca với Android
/// SuggestionSlotsTests.kt (so payload). Tầng: hoàn tác > clipboard > "Thêm dấu" >
/// chip số (giữa) > chữ.
final class SuggestionSlotsTests: XCTestCase {
    typealias S = KeyboardView.SuggestionSet
    private let N = KeyboardView.numberToken
    private let ADD = KeyboardView.addTonesToken
    private let UNDO = KeyboardView.undoTonesToken
    private let PASTE = KeyboardView.pasteToken
    private func clip(_ v: String) -> String { KeyboardView.clipTokenPrefix + v }
    private var otp: (display: String, insert: String) { ("Dán OTP 482913", clip("482913")) }
    private var stk: (display: String, insert: String) { ("Dán STK 0123456789", clip("0123456789")) }

    private func payloads(_ set: S, pill: Bool = false, middle: Bool = false) -> String {
        switch SuggestionSlots.arrange(set, undoAsPill: pill, bestInMiddle: middle) {
        case .pill(let c): return "pill:" + c.payload
        case .pasteCard: return "paste"
        case .chips(let c): return "chips:" + c.map(\.payload).joined(separator: "|")
        case .slots(let s, let e):
            return s.map { $0?.payload ?? "-" }.joined(separator: "|") + (e.isEmpty ? "" : " e:" + e.joined())
        }
    }

    func testWordsOnly() {
        var s = S(); s.literal = "anh"; s.word = "ánh"; s.word2 = "ảnh"
        XCTAssertEqual(payloads(s), "anh|ánh|ảnh")
        s.emojis = ["😀"]
        XCTAssertEqual(payloads(s), "anh|ánh|- e:😀")
        var n = S(); n.nextWords = ["a", "b", "c"]
        XCTAssertEqual(payloads(n), "a|b|c")
        XCTAssertEqual(payloads(n, middle: true), "b|a|c")
        // nhãn nguyên văn iOS có ngoặc kép, payload là chữ thô
        if case .slots(let sl, _) = SuggestionSlots.arrange(s) { XCTAssertEqual(sl[0]?.label, "\u{201C}anh\u{201D}") }
    }

    func testNumberChipAlwaysMiddle() {
        var s = S(); s.literal = "12"; s.word = "mười"; s.number = "mười hai"
        XCTAssertEqual(payloads(s), "12|\(N)|mười")
        s.emojis = ["😀"]
        XCTAssertEqual(payloads(s), "12|\(N)|- e:😀")
        var n = S(); n.nextWords = ["a", "b", "c"]; n.number = "x"
        XCTAssertEqual(payloads(n), "a|\(N)|b")
    }

    func testUndoBeatsEverything() {
        var busy = S(); busy.nextWords = ["a", "b"]; busy.paste = true; busy.clipChips = [otp]
        busy.number = "x"; busy.actionLabel = "Thêm dấu"; busy.actionPayload = ADD
        busy.restoreLabel = "↩︎ Khôi phục"
        XCTAssertEqual(payloads(busy), "\(KeyboardView.restoreToken)|\(N)|a")
        XCTAssertEqual(payloads(busy, pill: true), "pill:\(KeyboardView.restoreToken)")
        busy.restorePayload = KeyboardView.toolUndoToken          // hoàn tác công cụ văn bản
        XCTAssertEqual(payloads(busy), "\(KeyboardView.toolUndoToken)|\(N)|a")
        var tones = S(); tones.nextWords = ["a", "b"]; tones.number = "x"
        tones.actionLabel = "↩︎ Hoàn tác"; tones.actionPayload = UNDO
        XCTAssertEqual(payloads(tones), "\(UNDO)|\(N)|a")
        XCTAssertEqual(payloads(tones, pill: true), "pill:\(UNDO)")
        var typing = S(); typing.literal = "anh"; typing.word = "ánh"; typing.restoreLabel = "↩︎ Khôi phục"
        XCTAssertEqual(payloads(typing), "\(KeyboardView.restoreToken)|anh|ánh")
    }

    func testClipboardBeatsAddTonesAndNumber() {
        var s = S(); s.nextWords = ["a"]; s.paste = true; s.clipChips = [otp, stk, otp]; s.number = "x"
        s.actionLabel = "Thêm dấu"; s.actionPayload = ADD
        XCTAssertEqual(payloads(s), "chips:\(clip("482913"))|\(clip("0123456789"))|\(PASTE)")
        s.clipChips = []
        XCTAssertEqual(payloads(s), "paste")
        s.paste = false; s.clipChips = [otp]
        XCTAssertEqual(payloads(s), "chips:\(clip("482913"))")
    }

    func testAddTonesLeadsThenNumberMiddle() {
        var s = S(); s.nextWords = ["a", "b", "c"]; s.actionLabel = "Thêm dấu"; s.actionPayload = ADD
        XCTAssertEqual(payloads(s), "\(ADD)|a|b")
        XCTAssertEqual(payloads(s, middle: true), "\(ADD)|a|b")
        s.number = "x"
        XCTAssertEqual(payloads(s), "\(ADD)|\(N)|a")
    }

    /// "↩︎ từ cũ" sau khi vuốt sửa lại từ trước: slot đầu, biến thể vuốt dời phải.
    func testReviseUndoLeadsSwipeAlternatives() {
        let r = KeyboardView.undoReviseToken
        var s = S(); s.nextWords = ["a", "b", "c"]; s.actionLabel = "↩︎ có"; s.actionPayload = r
        XCTAssertEqual(payloads(s), "\(r)|a|b")
        XCTAssertEqual(payloads(s, pill: true), "\(r)|a|b")
    }

    /// Đường thật trên KeyboardView: chip số giữa + "Thêm dấu" đầu; clipboard thay bar.
    @MainActor func testKeyboardViewRendersArrangement() throws {
        let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: { _ in })
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb); kb.frame = host.bounds
        kb.setSuggestionsEnabled(true)
        kb.layoutIfNeeded()
        var s = S(); s.nextWords = ["a", "b", "c"]; s.number = "x"; s.actionLabel = "Thêm dấu"; s.actionPayload = ADD
        kb.showSuggestions(s)
        XCTAssertEqual(kb.debugSlotPayloads(), [ADD, N, "a"])
        var c = S(); c.paste = true; c.clipChips = [otp]; c.number = "x"
        kb.showSuggestions(c)
        XCTAssertEqual(kb.debugSlotPayloads(), [clip("482913"), PASTE, nil])
    }

    /// Bug 27/09/2026: kết quả gợi ý nền về GIỮA chạm xuống và nhấc tay thay ô ⇒ trước đây
    /// chèn từ mới (đọc payload lúc nhấc). Phải chèn đúng chữ đang hiện lúc chạm xuống.
    @MainActor func testTapCommitsPayloadShownAtTouchDown() {
        let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: { _ in })
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb); kb.frame = host.bounds
        kb.setSuggestionsEnabled(true)
        kb.layoutIfNeeded()
        var got: [String] = []
        kb.onSuggestion = { got.append($0) }
        kb.showSuggestions(S(literal: "casn", word: "cánh", word2: "cắn"))
        let slot = kb.debugSlotControl(2)
        slot.sendActions(for: .touchDown)
        kb.showSuggestions(S(literal: "casn", word: "cánh", word2: "cân"))   // kết quả nền mới
        slot.sendActions(for: .touchUpInside)
        XCTAssertEqual(got, ["cắn"])
        slot.sendActions(for: .touchDown); slot.sendActions(for: .touchUpInside)
        XCTAssertEqual(got, ["cắn", "cân"])
    }

    /// Hit-area slot phủ cả phần strip dưới bar 20pt (trước đây bar UIStackView 20pt chặn
    /// ⇒ chạm thấp trên gợi ý là vùng chết), không lấn hàng phím.
    @MainActor func testSlotHitAreaCoversStripBelowBar() throws {
        let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: { _ in })
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb); kb.frame = host.bounds
        kb.setSuggestionsEnabled(true)
        kb.layoutIfNeeded()
        kb.showSuggestions(S(nextWords: ["a", "b", "c"]))
        let cell = kb.debugSuggestionGeometry().cells[1]
        XCTAssertTrue(kb.hitTest(CGPoint(x: cell.midX, y: cell.midY), with: nil) === kb.debugSlotControl(1))
        // Strip mở thực tế (iPhone: theo thanh dự đoán stock 29, iPad 34) = đỉnh vùng phím.
        let strip = kb.debugRowsTop
        let low = CGPoint(x: cell.midX, y: strip - 1)
        XCTAssertTrue(kb.hitTest(low, with: nil) === kb.debugSlotControl(1))
        XCTAssertFalse(kb.hitTest(CGPoint(x: cell.midX, y: strip + 6), with: nil)
                       === kb.debugSlotControl(1))
    }

    /// Bug 27/09/2026: gõ "casn" (ý "caan", a trượt sang s) bar chỉ có "casn" | cánh | cắn.
    @MainActor func testToneSlipOffersIntendedWordOnBar() {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        for (i, c) in "casn".enumerated() { _ = rig.key(c, index: i + 1, drain: 0.05) }
        KeyboardBenchTests.spin(0.2)
        XCTAssertTrue(rig.vc.debugKeyboard.debugSlotPayloads().contains("Cân"),
                      "\(rig.vc.debugKeyboard.debugSlotPayloads())")
    }

    // MARK: Shift ⇒ gợi ý viết hoa như Gboard (feedback 10/2026)

    /// Ô gợi ý là TỪ (bắt đầu bằng chữ cái) — bỏ token điều khiển/emoji.
    @MainActor private func wordSlots(_ kb: KeyboardView) -> [String] {
        kb.debugSlotPayloads().compactMap { $0 }.filter { $0.first?.isLetter == true }
    }
    private func capitalized(_ w: String) -> Bool { w.first?.isUppercase == true }
    private func allCaps(_ w: String) -> Bool { w == w.uppercased() && w != w.lowercased() }

    @MainActor private func shiftRig(autocap: UITextAutocapitalizationType = .sentences) -> KeyboardBenchTests.Rig {
        let rig = KeyboardBenchTests.Rig()
        rig.proxy.autocapitalizationType = autocap
        return rig
    }

    /// Bấm Shift giữa câu (chưa gõ từ mới): bar đổi NGAY sang Hoa đầu; bấm đúp = Caps
    /// Lock ⇒ HOA HẾT; tắt ⇒ về thường. Không cần gõ phím nào.
    @MainActor func testShiftToggleRefreshesBarImmediately() throws {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = shiftRig()
        defer { rig.close() }
        let kb = rig.vc.debugKeyboard
        for (i, c) in "toi di ".enumerated() { _ = rig.key(c, index: i + 1, drain: 0.04) }
        KeyboardBenchTests.spin(0.1)
        XCTAssertFalse(kb.debugShiftOn)
        let before = wordSlots(kb)
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { !capitalized($0) }, "\(before)")
        let shiftKey = try XCTUnwrap(kb.debugControl("Shift"))
        shiftKey.sendActions(for: .touchDown)
        KeyboardBenchTests.spin(0.05)
        let once = wordSlots(kb)
        XCTAssertEqual(once.map { $0.lowercased() }, before.map { $0.lowercased() })
        XCTAssertTrue(once.allSatisfy(capitalized), "\(once)")
        XCTAssertFalse(once.allSatisfy(allCaps), "\(once)")
        shiftKey.sendActions(for: .touchDown)          // < 0.3 s ⇒ Caps Lock
        KeyboardBenchTests.spin(0.05)
        let caps = wordSlots(kb)
        XCTAssertTrue(caps.allSatisfy(allCaps), "\(caps)")
        KeyboardBenchTests.spin(0.35)
        shiftKey.sendActions(for: .touchDown)          // tắt Caps
        KeyboardBenchTests.spin(0.05)
        XCTAssertEqual(wordSlots(kb), before)
    }

    /// Chạm gợi ý khi Shift một-lần: chèn đúng dạng đang hiện ("Bên") rồi nhả Shift như
    /// gõ một chữ. Ô không tự viết hoa (autocap .none) để auto-shift không che kết quả.
    @MainActor func testCommitInsertsShiftedFormAndReleasesShift() throws {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = shiftRig(autocap: .none)
        defer { rig.close() }
        let kb = rig.vc.debugKeyboard
        for (i, c) in "toi di ".enumerated() { _ = rig.key(c, index: i + 1, drain: 0.04) }
        KeyboardBenchTests.spin(0.1)
        if kb.debugShiftOn { kb.debugControl("Shift")?.sendActions(for: .touchDown); KeyboardBenchTests.spin(0.35) }
        try XCTUnwrap(kb.debugControl("Shift")).sendActions(for: .touchDown)
        KeyboardBenchTests.spin(0.05)
        XCTAssertTrue(kb.debugShiftOn)
        let payloads = kb.debugSlotPayloads()
        let i = try XCTUnwrap(payloads.firstIndex { $0?.first?.isLetter == true })
        let shown = try XCTUnwrap(payloads[i])
        XCTAssertTrue(capitalized(shown), shown)
        let slot = kb.debugSlotControl(i)
        slot.sendActions(for: .touchDown); slot.sendActions(for: .touchUpInside)
        KeyboardBenchTests.spin(0.05)
        XCTAssertTrue(rig.proxy.text.hasSuffix(" " + shown + " "), rig.proxy.text)
        XCTAssertFalse(kb.debugShiftOn, "Shift một-lần phải nhả sau khi chọn gợi ý")
        // bar sau đó về thường (Shift đã nhả)
        XCTAssertTrue(wordSlots(kb).allSatisfy { !capitalized($0) }, "\(wordSlots(kb))")
    }

    /// Đầu câu (auto-shift) = Shift tay: gợi ý mở đầu Hoa đầu; gõ "be" (ra "Be") ⇒ ứng viên
    /// đang gõ cũng Hoa đầu ("Bên"), trước đây ra "bên" và chạm thì mất chữ hoa.
    @MainActor func testSentenceStartAndTypedCapitalCarryToCandidates() throws {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = shiftRig()
        defer { rig.close() }
        let kb = rig.vc.debugKeyboard
        KeyboardBenchTests.spin(0.1)
        XCTAssertTrue(kb.debugShiftOn)
        let open = wordSlots(kb)
        XCTAssertFalse(open.isEmpty)
        XCTAssertTrue(open.allSatisfy(capitalized), "\(open)")
        for (i, c) in "be".enumerated() { _ = rig.key(c, index: i + 1, drain: 0.04) }
        KeyboardBenchTests.spin(0.2)
        XCTAssertEqual(rig.proxy.text, "Be")
        let typing = wordSlots(kb)
        XCTAssertGreaterThan(typing.count, 1)
        XCTAssertTrue(typing.allSatisfy(capitalized), "\(typing)")
        XCTAssertFalse(typing.allSatisfy(allCaps), "\(typing)")
    }
}
