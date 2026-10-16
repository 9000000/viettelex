// EngineBridge unit tests — a scripted mock proxy records the exact
// deleteBackward/insertText stream, so the whole iOS typing path (minus UIKit)
// is verified against the real engine.
import XCTest
import TelexCore

final class MockProxy: TextProxyLike {
    var text = ""
    var isSecure = false
    /// Mô phỏng context host báo: nil (mặc định) = đúng text thật; .some(nil) = host
    /// trả nil; .some("…") = host báo context LỆCH (con trỏ dời, host gán lại text…).
    var fakeContext: String?? = nil
    var contextBeforeInput: String? { fakeContext ?? text }
    /// Chữ sau con trỏ (con trỏ đứng giữa `text` và `textAfter`). fakeAfter như fakeContext.
    var textAfter = ""
    var fakeAfter: String?? = nil
    var contextAfterInput: String? { fakeAfter ?? textAfter }
    var hasSelection = false
    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

final class EngineBridgeTests: XCTestCase {

    private func type(_ keys: String, secure: Bool = false,
                      settings: KeyboardSettings = KeyboardSettings()) -> String {
        let proxy = MockProxy()
        proxy.isSecure = secure
        let bridge = EngineBridge(settings: settings)
        for ch in keys {
            if ch == " " { bridge.boundary(" ", proxy: proxy) }
            else if ch == "⌫" { bridge.backspace(proxy: proxy) }
            else { bridge.letter(ch, proxy: proxy) }
        }
        return proxy.text
    }

    func testBasicVietnamese() {
        XCTAssertEqual(type("vieetj "), "việt ")
        XCTAssertEqual(type("Tieengs Vieetj raats hay "), "Tiếng Việt rất hay ")
        XCTAssertEqual(type("dduwowngf "), "đường ")
    }

    func testAutoRestoreAndCollisions() {
        XCTAssertEqual(type("google "), "google ")
        // Chính sách 2026-07-23: collision THẬT thì tiếng Việt thắng (his ≡ hí)
        XCTAssertEqual(type("his "), "hí ")
        // POLICY V2 (31/07/2026): gõ đúp CUỐI từ = huỷ dấu, giữ composed (off→of)
        XCTAssertEqual(type("off "), "of ")
        XCTAssertEqual(type("Deffault "), "Default ")   // cancel keeps composed
    }

    func testBackspace() {
        XCTAssertEqual(type("vieetj⌫"), "việ")
        XCTAssertEqual(type("toans⌫"), "tóa")       // tone re-render on delete (old-style placement)
        XCTAssertEqual(type("a⌫"), "")
        XCTAssertEqual(type("⌫"), "")               // empty engine → plain delete
    }

    func testSecureFieldBypassesEngine() {
        XCTAssertEqual(type("vieejt ", secure: true), "vieejt ")
    }

    func testResetDropsComposition() {
        let proxy = MockProxy()
        let bridge = EngineBridge(settings: KeyboardSettings())
        for ch in "vie" { bridge.letter(ch, proxy: proxy) }
        bridge.reset()
        // new word starts clean: 'e' does not merge into the abandoned "vie"
        for ch in "em" { bridge.letter(ch, proxy: proxy) }
        bridge.boundary(" ", proxy: proxy)
        XCTAssertEqual(proxy.text, "vieem ")
    }

    func testSettingsRespected() {
        var s = KeyboardSettings()
        s.simpleTelex = true
        XCTAssertEqual(type("cw ", settings: s), "cw ")   // simple: lone w stays
        s.simpleTelex = false
        XCTAssertEqual(type("nhw ", settings: s), "như ")
    }

    /// Quyết định theo ngữ cảnh (như macOS, mặc định bật).
    func testContextualEnglish() {
        var s = KeyboardSettings()
        XCTAssertTrue(s.contextualEnglish)
        XCTAssertEqual(type("he is ", settings: s), "he is ")
        XCTAssertEqual(type("sao is ", settings: s), "sao í ")
        s.contextualEnglish = false
        XCTAssertEqual(type("he is ", settings: s), "he í ")
    }

    /// Issue #94 (25/09/2026): teencode spelling is a toggle, default OFF like macOS.
    func testTeencodeToggle() {
        var s = KeyboardSettings()                    // iOS default: Simple Telex ON
        XCTAssertFalse(s.teencode)
        XCTAssertEqual(type("was ", settings: s), "was ")     // English survives
        XCTAssertEqual(type("kos ", settings: s), "kos ")
        s.teencode = true
        XCTAssertEqual(type("was ", settings: s), "wá ")      // chat spelling = quá
        XCTAssertEqual(type("kos ", settings: s), "kó ")
        XCTAssertEqual(type("thiks ", settings: s), "thík ")
    }
}

final class SuggestionTests: XCTestCase {
    func testEmojiSameForViAndEn() {
        // "love"/"yêu" → 3 ứng viên giống nhau (❤️ 💕 💗), như stock QuickType
        XCTAssertEqual(EmojiSuggest.emojis(for: "love").count, 3)
        XCTAssertEqual(EmojiSuggest.emojis(for: "yêu"), EmojiSuggest.emojis(for: "love"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "mèo"), EmojiSuggest.emojis(for: "cat"))
        XCTAssertTrue(EmojiSuggest.emojis(for: "").isEmpty)
    }

    func testInlineDiacriticCompatibleMatch() {
        // spec user 2026-07-24: "to" khớp mọi biến thể; "tô" chỉ khớp họ ô
        let to = VNSuggest.matches("to").map { $0.word }
        XCTAssertTrue(to.contains("tôi"))
        XCTAssertTrue(to.contains("toàn"))
        let toCirc = VNSuggest.matches("tô").map { $0.word }
        XCTAssertTrue(toCirc.contains("tôi"))
        XCTAssertTrue(toCirc.contains("tối") || toCirc.contains("tồi") || toCirc.contains("tội"))
        XCTAssertFalse(toCirc.contains("toàn"))     // quality đã chốt ô
        XCTAssertFalse(toCirc.contains("tơi"))      // ơ ≠ ô
        // tone đã chốt huyền: loại ngang/sắc; quality chưa chốt nên "tồi" vẫn hợp lệ
        let toGrave = VNSuggest.matches("tò").map { $0.word }
        XCTAssertTrue(toGrave.contains("tòa"))
        XCTAssertFalse(toGrave.contains("tôi"))     // ngang ≠ huyền
        XCTAssertFalse(toGrave.contains("tới"))     // sắc ≠ huyền
        // 1 phím: hot-path bucket có kết quả tần suất cao
        XCTAssertTrue(VNSuggest.matches("t").map { $0.word }.contains("tôi"))
        // nguoi → người đứng top nhờ tần suất
        XCTAssertEqual(VNSuggest.matches("nguoi").first?.word, "người")
        // contains: lexicon membership
        XCTAssertTrue(VNSuggest.contains("người"))
        XCTAssertFalse(VNSuggest.contains("nguo"))
    }
}

final class UserLangModelTests: XCTestCase {
    private func freshModel() -> UserLangModel {
        let m = UserLangModel(appGroup: nil)   // in-memory
        m.isKnownWord = { _ in true }          // tests ranking không dính threshold
        return m
    }

    func testLearnAndSuggest() {
        let m = freshModel()
        for _ in 0..<3 { m.record(word: "anh", after: nil) }
        for _ in 0..<3 { m.record(word: "ơi", after: "anh") }
        m.record(word: "đang", after: "anh")
        m.record(word: "chào", after: nil)
        // đầu câu: top từ hay dùng
        XCTAssertEqual(m.topWords(limit: 1), ["anh"])
        // sau "anh": bigram cá nhân thắng, seed vẫn có mặt
        let next = m.nextWords(after: "anh", limit: 4)
        XCTAssertEqual(next.first, "ơi")
        XCTAssertTrue(next.contains("đang"))
        // seed thuần khi chưa học gì
        XCTAssertEqual(freshModel().nextWords(after: "cảm", limit: 1), ["ơn"])
        // shrinkage: MỘT lần gõ nhầm không đè nổi seed đầu bảng
        let m2 = freshModel()
        m2.record(word: "xong", after: "cảm")
        XCTAssertEqual(m2.nextWords(after: "cảm", limit: 1), ["ơn"])
        // không học rác
        m.record(word: "abc123", after: "anh")
        XCTAssertEqual(m.count(of: "abc123"), 0)
        XCTAssertFalse(UserLangModel.learnable("heeeyyy"))
    }

    func testTrigramContext(){
        let m = freshModel()
        // nền bigram (cảm→ơn) đủ 2 rồi trigram (cảm,ơn)→nhiều mới được ghi
        for _ in 0..<2 { m.record(word: "ơn", after: "cảm") }
        for _ in 0..<3 { m.record(word: "nhiều", after: "ơn", prev2: "cảm") }
        m.record(word: "anh", after: "ơn", prev2: "cảm")
        XCTAssertEqual(m.nextWords(after: "ơn", prev2: "cảm", limit: 1), ["nhiều"])
    }

    func testUnknownWordThreshold() {
        let m = UserLangModel(appGroup: nil)   // isKnownWord = false mặc định
        m.record(word: "blib", after: nil)
        m.record(word: "blib", after: nil)
        XCTAssertTrue(m.topWords(limit: 3).isEmpty)      // 2 lần: chưa được gợi ý
        m.record(word: "blib", after: nil)
        XCTAssertEqual(m.topWords(limit: 3), ["blib"])   // lần 3: đủ ngưỡng
    }

    func testTriggerExpansion() {
        // research 2026-07-24: done/xong/hoàn thành cùng bộ với đúng
        XCTAssertEqual(EmojiSuggest.emojis(for: "done"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "xong"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "hoàn thành"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "failed"), EmojiSuggest.emojis(for: "sai"))
        XCTAssertFalse(EmojiSuggest.emojis(for: "trời ơi").isEmpty)   // cụm 2 token
        XCTAssertFalse(EmojiSuggest.emojis(for: "hoan thanh").isEmpty) // folded cụm
    }

    func testEmojiFoldedKeys() {
        // gõ mộc không dấu cũng ra emoji: yeu ≡ yêu
        XCTAssertEqual(EmojiSuggest.emojis(for: "yeu"), EmojiSuggest.emojis(for: "yêu"))
        XCTAssertFalse(EmojiSuggest.emojis(for: "meo").isEmpty)
    }
}

final class SeedDataTests: XCTestCase {
    func testSeedInjection() {
        let m = UserLangModel(appGroup: nil)
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        // seed nạp được và có mặt trong gợi ý
        XCTAssertFalse(m.topWords(limit: 3).isEmpty)
        XCTAssertTrue(m.nextWords(after: "cảm", limit: 2).contains("ơn"))
        XCTAssertTrue(m.nextWords(after: "hôm", limit: 2).contains("nay"))
        // đã có dữ liệu → seed lần hai là no-op
        let before = m.count(of: "không")
        m.seedIfEmpty(unigrams: ["xxx": 99], bigrams: [])
        XCTAssertEqual(m.count(of: "không"), before)
        XCTAssertEqual(m.count(of: "xxx"), 0)
        // weight hợp đồng: max seed ≤ 50
        XCTAssertLessThanOrEqual(SeedData.unigrams.values.max() ?? 0, 50)
    }
}

final class DisplayCaseTests: XCTestCase {
    func testProperNounDisplay() {
        XCTAssertEqual(DisplayCase.apply("senprints"), "SenPrints")
        XCTAssertEqual(DisplayCase.apply("printik"), "Printik")
        XCTAssertEqual(DisplayCase.apply("iphone"), "iPhone")
        XCTAssertEqual(DisplayCase.apply("macos"), "macOS")
        XCTAssertEqual(DisplayCase.apply("nguyễn"), "Nguyễn")
        XCTAssertEqual(DisplayCase.apply("github"), "GitHub")
        XCTAssertEqual(DisplayCase.apply("chatgpt"), "ChatGPT")
        XCTAssertEqual(DisplayCase.apply("claude"), "Claude")
        // từ thường giữ nguyên; token nhập nhằng KHÔNG được hoa
        XCTAssertEqual(DisplayCase.apply("cảm"), "cảm")
        XCTAssertEqual(DisplayCase.apply("trang"), "trang")
        // theo ngữ cảnh chuỗi: hà→Nội, nha→Trang; đơn lẻ vẫn thường
        XCTAssertEqual(DisplayCase.apply("nội", after: "hà"), "Nội")
        XCTAssertEqual(DisplayCase.apply("nội", after: "Hà"), "Nội")
        XCTAssertEqual(DisplayCase.apply("nội"), "nội")
        XCTAssertEqual(DisplayCase.apply("trang", after: "nha"), "Trang")
        XCTAssertEqual(DisplayCase.apply("văn", after: "nguyễn"), "Văn")
        XCTAssertEqual(DisplayCase.apply("văn"), "văn")
        XCTAssertEqual(DisplayCase.apply("vũ"), "vũ")
    }

    func testLearningStaysCaseFolded() {
        // bấm nhận "SenPrints" → datastore vẫn đếm dưới khóa thường
        let m = UserLangModel(appGroup: nil)
        m.record(word: "SenPrints", after: nil)
        XCTAssertEqual(m.count(of: "senprints"), 1)
        XCTAssertEqual(m.count(of: "SenPrints"), 1)   // count(of:) tự lowercase
    }
}

/// Feedback 10/2026: bật Shift mà gợi ý không viết hoa như Gboard. SuggestionCase thuần
/// (song sinh Android SuggestionCaseTests).
final class SuggestionCaseTests: XCTestCase {
    private func d(_ w: String, _ s: SuggestionCase.Shift, _ typed: String = "") -> String {
        SuggestionCase.display(w, shift: s, typed: typed)
    }

    /// Chưa gõ (gợi ý từ kế tiếp): Shift tắt / một-lần / Caps Lock.
    func testShiftStatesWithEmptyComposing() {
        XCTAssertEqual(d("bên", .off), "bên")
        XCTAssertEqual(d("bên", .once), "Bên")
        XCTAssertEqual(d("bên", .capsLock), "BÊN")
        // chữ Việt: đ/ư/ơ/ă có dạng hoa dựng sẵn
        XCTAssertEqual(d("đi", .once), "Đi")
        XCTAssertEqual(d("đường", .capsLock), "ĐƯỜNG")
        XCTAssertEqual(d("ước", .once), "Ước")
        XCTAssertEqual(d("ăn", .once), "Ăn")
        // NFD (dấu tổ hợp) vẫn hoa đúng cụm đầu
        XCTAssertEqual(d("e\u{0300}m", .once), "E\u{0300}m")
    }

    /// Đang gõ dở: hoa/thường theo chữ đã gõ, Shift (một-lần) không còn quyết định.
    func testTypedPrefixCasingWins() {
        XCTAssertEqual(d("bên", .off, "Bê"), "Bên")
        XCTAssertEqual(d("bên", .off, "B"), "Bên")
        XCTAssertEqual(d("bên", .off, "BÊ"), "BÊN")
        XCTAssertEqual(d("bên", .off, "bê"), "bên")
        XCTAssertEqual(d("bên", .once, "bê"), "bên")       // shift bật giữa từ: cho phím kế
        XCTAssertEqual(d("bên", .capsLock, "B"), "BÊN")    // Caps: 1 chữ cũng HOA HẾT
        XCTAssertEqual(d("đường", .off, "Đư"), "Đường")
        XCTAssertEqual(d("đường", .off, "ĐƯ"), "ĐƯỜNG")
        XCTAssertEqual(d("bên", .off, "bÊ"), "bên")        // chữ đầu thường ⇒ giữ
    }

    /// Không phá tên riêng / viết tắt / emoji / số / chip URL-email.
    func testLeavesSpecialCandidatesAlone() {
        XCTAssertEqual(d("iPhone", .once), "iPhone")
        XCTAssertEqual(d("SenPrints", .once), "SenPrints")
        XCTAssertEqual(d("FPT", .once), "FPT")
        XCTAssertEqual(d("Nguyễn", .off), "Nguyễn")
        XCTAssertEqual(d("iPhone", .capsLock), "IPHONE")
        XCTAssertEqual(d("😀", .once), "😀")
        XCTAssertEqual(d("😀", .capsLock), "😀")
        XCTAssertEqual(d("100.000", .capsLock), "100.000")
        XCTAssertEqual(d("@gmail.com", .capsLock), "@gmail.com")
        XCTAssertEqual(d("", .once), "")
    }

    func testModeTable() {
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: ""), .asIs)
        XCTAssertEqual(SuggestionCase.mode(shift: .once, typed: ""), .capitalized)
        XCTAssertEqual(SuggestionCase.mode(shift: .capsLock, typed: ""), .upper)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "A"), .capitalized)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "AB"), .upper)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "Ab"), .capitalized)
    }
}

final class SensitiveWordsTests: XCTestCase {
    func testFilterGate() {
        let words = ["vcl", "vui", "đcm", "cảm"]
        XCTAssertEqual(SensitiveWords.filter(words, enabled: true), ["vui", "cảm"])
        XCTAssertEqual(SensitiveWords.filter(words, enabled: false), words)
        // từ bạo lực phổ thông KHÔNG bị lọc (từ vựng đời thường/báo chí)
        XCTAssertEqual(SensitiveWords.filter(["cướp", "giết"], enabled: true), ["cướp", "giết"])
    }
}

final class SeedOrderTests: XCTestCase {
    func testEmptyFieldTop3() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { _ in true }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        XCTAssertEqual(m.topWords(limit: 3), ["em", "anh", "tôi"])
    }
}

/// Ô email (người nhận Gmail/Outlook, iOS 1.2.15): gõ tên tiếng Việt để tìm danh bạ, nhưng địa chỉ
/// phải đúng phím thô. Phím đi như controller: chữ → letter, số (VNI) → vniDigit rồi boundary,
/// ký hiệu/"@"/"." → boundary, "⌫" → backspace, "␣" → dấu cách. Song sinh Android EmailFieldTest.
final class EmailFieldBridgeTests: XCTestCase {
    private func bridge(email: Bool = true, passthrough: Bool = false,
                        settings: KeyboardSettings = KeyboardSettings()) -> EngineBridge {
        let b = EngineBridge(settings: settings)
        b.passthrough = passthrough
        b.emailField = email
        b.reachBackAllowed = !email
        b.shortcutsAllowed = !email
        return b
    }

    private func feed(_ keys: String, _ b: EngineBridge, _ p: MockProxy) {
        for ch in keys {
            switch ch {
            case "⌫": b.backspace(proxy: p)
            case "␣": b.boundary(" ", proxy: p)
            default:
                if ch.isLetter { b.letter(ch, proxy: p) }
                else if ch.isNumber, b.vniDigit(ch, proxy: p) {}
                else { b.boundary(String(ch), proxy: p) }
            }
        }
    }

    private func type(_ keys: String, email: Bool = true, passthrough: Bool = false,
                      settings: KeyboardSettings = KeyboardSettings()) -> String {
        let p = MockProxy()
        feed(keys, bridge(email: email, passthrough: passthrough, settings: settings), p)
        return p.text
    }

    func testVietnameseNameComposes() {
        XCTAssertEqual(type("Sown"), "Sơn")
        XCTAssertEqual(type("Nguyeenx␣Sown"), "Nguyễn Sơn")
        XCTAssertEqual(type("Sown,"), "Sơn,")
    }

    func testAddressesStayRaw() {
        XCTAssertEqual(type("phuc.nguyen@gmail.com"), "phuc.nguyen@gmail.com")
        XCTAssertEqual(type("dduc@vn.com"), "dduc@vn.com")
        XCTAssertEqual(type("tuan.anh@"), "tuan.anh@")
        XCTAssertEqual(type("nguyeenx@"), "nguyeenx@")           // quy tắc: đúng phím thô
        XCTAssertEqual(type("Sown.nguyeenx@gmail.com"), "Sown.nguyeenx@gmail.com")
        XCTAssertEqual(type("tuaans_anh1@vn.vn"), "tuaans_anh1@vn.vn")
        XCTAssertEqual(type("ddax-ddi+1@x.com"), "ddax-ddi+1@x.com")
        XCTAssertEqual(type("viet.nam"), "viet.nam")             // "." cũng khoá token
        XCTAssertEqual(type("hoaf@ddaif.vn"), "hoaf@ddaif.vn")
    }

    func testDigitsAndSymbolsComposeUntilMark() {
        XCTAssertEqual(type("tuaans_anh"), "tuấn_anh")           // chưa có @ / . ⇒ vẫn soạn
        XCTAssertEqual(type("tuaans_anh␣"), "tuấn_anh ")
    }

    func testTokenAfterSeparatorComposesAgain() {
        XCTAssertEqual(type("an@x.com,␣Sown"), "an@x.com, Sơn")
        XCTAssertEqual(type("an@x.com;Sown"), "an@x.com;Sơn")
        XCTAssertEqual(type("an@x.com␣Sown"), "an@x.com Sơn")
    }

    func testBackspaceInsideAddressAndAcrossMark() {
        XCTAssertEqual(type("ddu@⌫c"), "dduc")                  // xoá "@" ⇒ token lại là chữ
        XCTAssertEqual(type("ddu@⌫c@"), "dduc@")
        XCTAssertEqual(type("phuc@gmx⌫ail.com"), "phuc@gmail.com")
    }

    func testPasswordAndLiteralFieldsUnchanged() {
        XCTAssertEqual(type("Sown", passthrough: true), "Sown")          // ô URL/username: literal
        let p = MockProxy(); p.isSecure = true
        feed("Sown@", bridge(), p)
        XCTAssertEqual(p.text, "Sown@")                                    // mật khẩu
        XCTAssertEqual(type("Sown@", email: false), "Sơn@")               // ô thường: như cũ
    }

    func testNeverRewritesTextTheAppInserted() {
        // Gmail biến người nhận thành chip / chèn chữ: bridge reset, chữ có sẵn không bị viết lại.
        let p = MockProxy()
        let b = bridge()
        p.text = "Đức"                      // app chèn (không phải phím của mình)
        b.reset()
        feed("@vn.com", b, p)
        XCTAssertEqual(p.text, "Đức@vn.com")
        // host gán lại chữ trong lúc đang soạn (không báo): fail-safe, không xoá mù
        let q = MockProxy()
        let c = bridge()
        feed("dduc", c, q)
        q.text = "Đức Nguyễn <"
        feed("@", c, q)
        XCTAssertEqual(q.text, "Đức Nguyễn <@")
    }

    func testExistingAddressTokenStaysRawAfterReset() {
        let p = MockProxy()
        let b = bridge()
        p.text = "phuc@gmail.co"
        b.reset()                             // con trỏ dời tới cuối địa chỉ có sẵn
        feed("om", b, p)
        XCTAssertEqual(p.text, "phuc@gmail.coom")
    }

    func testVNIDigitsInAddress() {
        var s = KeyboardSettings(); s.vniMode = true
        XCTAssertEqual(type("So7n", settings: s), "Sơn")
        XCTAssertEqual(type("d9uc1@vn.com", settings: s), "d9uc1@vn.com")
        XCTAssertEqual(type("an@x2.com", settings: s), "an@x2.com")
    }

    func testEmailChipInsertionRestoresFirst() {
        // acceptEmailChip đi qua boundary(chip.insert)
        let p = MockProxy()
        let b = bridge()
        feed("dduc", b, p)
        b.boundary("@gmail.com", proxy: p)
        XCTAssertEqual(p.text, "dduc@gmail.com")
    }

    func testNoShortcutPreviewAndNothingToLearnAtMark() {
        let p = MockProxy()
        let b = bridge()
        feed("an", b, p)
        XCTAssertNil(b.shortcutPreview)
        XCTAssertEqual(b.boundary("@", proxy: p), "")
    }
}
