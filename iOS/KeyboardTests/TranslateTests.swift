// TranslateTests — Dịch trên máy (Plus): luật chiều dịch (đích chọn trong app, chữ đã là
// đích ⇒ về tiếng Việt), nhận ra ngôn ngữ, giữ khoảng trắng, thay chữ sau khi chờ (strict)
// + hoàn tác, cài đặt đích (App Group + sao lưu). Bản dịch thật (Apple Translation) không
// chạy được trên simulator (mọi cặp "unsupported", đo 13/10/2026) — kiểm trên máy thật.
import XCTest

private final class FakeProxy: TextProxyLike {
    var before: String
    var selected: String
    var isSecure = false
    init(_ before: String, selected: String = "") { self.before = before; self.selected = selected }
    var contextBeforeInput: String? { before }
    var contextAfterInput: String? { "" }
    var hasSelection: Bool { !selected.isEmpty }
    func insertText(_ t: String) { selected = ""; before += t }
    func deleteBackward() {
        if !selected.isEmpty { selected = ""; return }
        if !before.isEmpty { before.removeLast() }
    }
}

final class TranslateTests: XCTestCase {
    private typealias Pair = TranslateDirection.Pair

    // MARK: chiều dịch

    func testDefaultTargetEnglish() {
        XCTAssertEqual(TranslateDirection.resolve(detected: "vi", target: "en"), Pair(source: "vi", target: "en"))
        // Chữ đã là tiếng Anh ⇒ về tiếng Việt (khứ hồi bằng cùng một nút).
        XCTAssertEqual(TranslateDirection.resolve(detected: "en", target: "en"), Pair(source: "en", target: "vi"))
    }

    func testNonEnglishTargetJapanese() {
        XCTAssertEqual(TranslateDirection.resolve(detected: "vi", target: "ja"), Pair(source: "vi", target: "ja"))
        XCTAssertEqual(TranslateDirection.resolve(detected: "ja", target: "ja"), Pair(source: "ja", target: "vi"))
        // Ngôn ngữ thứ ba vẫn dịch SANG đích đã chọn.
        XCTAssertEqual(TranslateDirection.resolve(detected: "en", target: "ja"), Pair(source: "en", target: "ja"))
    }

    func testRegionalTargetComparesBaseLanguage() {
        // Đích zh-TW, chữ nhận ra là zh ⇒ đã là đích ⇒ dịch về tiếng Việt, nguồn dùng mã đích.
        XCTAssertEqual(TranslateDirection.resolve(detected: "zh", target: "zh-TW"), Pair(source: "zh-TW", target: "vi"))
        XCTAssertEqual(TranslateDirection.resolve(detected: "en", target: "en-GB"), Pair(source: "en-GB", target: "vi"))
        XCTAssertEqual(TranslateDirection.resolve(detected: "vi", target: "pt-PT"), Pair(source: "vi", target: "pt-PT"))
    }

    func testUnknownLanguageOrBadTarget() {
        XCTAssertNil(TranslateDirection.resolve(detected: nil, target: "en"))
        XCTAssertNil(TranslateDirection.resolve(detected: "", target: "ja"))
        // Đích lưu sai thành tiếng Việt ⇒ coi như mặc định (tiếng Anh).
        XCTAssertEqual(TranslateDirection.resolve(detected: "vi", target: "vi"), Pair(source: "vi", target: "en"))
    }

    // MARK: nhận ra ngôn ngữ

    func testLooksVietnamese() {
        XCTAssertTrue(TranslateText.looksVietnamese("Hôm nay trời đẹp quá"))
        XCTAssertTrue(TranslateText.looksVietnamese("Cảm ơn bạn nhiều"))
        XCTAssertTrue(TranslateText.looksVietnamese("ok, gặp lại sau nhé"))
        // NFD (ô tổ hợp) cũng nhận.
        XCTAssertTrue(TranslateText.looksVietnamese("Hôm nay trời đẹp".decomposedStringWithCanonicalMapping))
        // Dấu sắc/huyền/ngã/mũ một mình là của tiếng Pháp/Bồ… — không tính.
        XCTAssertFalse(TranslateText.looksVietnamese("Café au lait très bon"))
        XCTAssertFalse(TranslateText.looksVietnamese("São Paulo é grande"))
        XCTAssertFalse(TranslateText.looksVietnamese("Good morning"))
        XCTAssertFalse(TranslateText.looksVietnamese("123 !!"))
    }

    func testDetect() {
        XCTAssertEqual(TranslateText.detect("Hôm nay trời đẹp quá"), "vi")
        XCTAssertEqual(TranslateText.detect("The weather is really nice today, isn't it?"), "en")
        XCTAssertEqual(TranslateText.detect("今日はとてもいい天気ですね"), "ja")
        XCTAssertNil(TranslateText.detect("123 456"))
    }

    // MARK: khoảng trắng

    func testRewrapKeepsOriginalWhitespace() {
        XCTAssertEqual(TranslateText.rewrap(original: "xin chào ", translated: "hello"), "hello ")
        XCTAssertEqual(TranslateText.rewrap(original: "  xin chào\u{00A0}", translated: " Hello\n"), "  Hello\u{00A0}")
        XCTAssertEqual(TranslateText.splitWhitespace("   ").core, "")
        XCTAssertEqual(TranslateText.splitWhitespace(" a b ").core, "a b")
    }

    // MARK: thay chữ sau khi chờ + hoàn tác

    func testReplaceBeforeCursorAndUndo() {
        let p = FakeProxy("Dòng 1\nxin chào bạn ")
        let src = TextTools.source(selected: nil, before: p.before)!
        XCTAssertEqual(src.text, "xin chào bạn ")
        let out = TranslateText.rewrap(original: src.text, translated: "hello friend")
        guard case .applied(let u) = TextToolRunner.replace(src, with: out, proxy: p, strict: true) else {
            return XCTFail("phải thay")
        }
        XCTAssertEqual(p.before, "Dòng 1\nhello friend ")
        XCTAssertTrue(TextToolRunner.undo(u, proxy: p))
        XCTAssertEqual(p.before, "Dòng 1\nxin chào bạn ")
    }

    func testReplaceSelection() {
        let p = FakeProxy("A ", selected: "cảm ơn")
        let src = TextTools.source(selected: p.selected, before: p.before)!
        XCTAssertTrue(src.isSelection)
        guard case .applied = TextToolRunner.replace(src, with: "thank you", proxy: p, strict: true,
                                                     currentSelection: p.selected) else {
            return XCTFail("phải thay")
        }
        XCTAssertEqual(p.before, "A thank you")
    }

    /// Người dùng gõ tiếp / đổi vùng chọn trong lúc chờ bản dịch ⇒ không động vào ô.
    func testStrictRefusesWhenFieldChangedWhileWaiting() {
        let p = FakeProxy("xin chào")
        let src = TextTools.source(selected: nil, before: p.before)!
        p.before += " nhé"
        XCTAssertEqual(TextToolRunner.replace(src, with: "hello", proxy: p, strict: true), .failsafe)
        XCTAssertEqual(p.before, "xin chào nhé")

        let q = FakeProxy("", selected: "cảm ơn")
        let s2 = TextTools.source(selected: q.selected, before: q.before)!
        XCTAssertEqual(TextToolRunner.replace(s2, with: "thanks", proxy: q, strict: true, currentSelection: "cảm"), .failsafe)
        XCTAssertEqual(TextToolRunner.replace(s2, with: "thanks", proxy: q, strict: true, currentSelection: nil), .failsafe)
        XCTAssertEqual(q.selected, "cảm ơn")
    }

    func testUnchangedTranslationLeavesField() {
        let p = FakeProxy("OK")
        let src = TextTools.source(selected: nil, before: p.before)!
        XCTAssertEqual(TextToolRunner.replace(src, with: "OK", proxy: p, strict: true), .unchanged)
    }

    // MARK: cài đặt đích

    func testTargetPrefs() {
        let d = UserDefaults(suiteName: "TranslateTests")!
        d.removePersistentDomain(forName: "TranslateTests")
        XCTAssertEqual(TranslatePrefs.target(d), "en")
        TranslatePrefs.setTarget("ja", d)
        XCTAssertEqual(TranslatePrefs.target(d), "ja")
        TranslatePrefs.setTarget("vi-VN", d)
        XCTAssertEqual(TranslatePrefs.target(d), "en")
        XCTAssertEqual(TranslatePrefs.target(nil), "en")
        XCTAssertFalse(TranslatePrefs.knownTargets.contains { TranslatePrefs.base($0) == "vi" })
        XCTAssertTrue(TranslatePrefs.knownTargets.contains("ja"))
    }

    func testPickerTargetsExcludeVietnameseDedupedSorted() {
        let ids = TranslatePrefs.pickerTargets(["ja", "vi", "en", "ja", "fr"], uiLanguage: "en")
        XCTAssertEqual(ids, ["en", "fr", "ja"])   // English, French, Japanese
        XCTAssertEqual(TranslatePrefs.displayName("ja", uiLanguage: "vi"), "Tiếng Nhật")
        XCTAssertEqual(TranslatePrefs.displayName("ja", uiLanguage: "en"), "Japanese")
    }

    func testBackupSpecAcceptsKnownTargetsOnly() {
        XCTAssertEqual(SettingValue.fromSyncString("ja", key: TranslatePrefs.targetKey), .string("ja"))
        XCTAssertEqual(SettingValue.fromSyncString("zh-TW", key: TranslatePrefs.targetKey), .string("zh-TW"))
        XCTAssertNil(SettingValue.fromSyncString("vi", key: TranslatePrefs.targetKey))
        XCTAssertNil(SettingValue.fromSyncString("xx", key: TranslatePrefs.targetKey))
    }

    // MARK: Plus

    func testPlusFeature() {
        XCTAssertTrue(PlusFeature.allCases.contains(.translate))
        XCTAssertTrue(PlusFeature.translate.howTo.contains("☰"))
        if #available(iOS 26.0, *) {
            XCTAssertTrue(PlusFeature.translate.isAvailableOnDevice)
            XCTAssertTrue(TranslateText.isSupportedOS)
        }
        XCTAssertTrue(PlusFeature.textTools.isAvailableOnDevice)
    }
}
