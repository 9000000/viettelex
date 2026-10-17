// CaretSuggestionsTests — logic THUẦN của ba gợi ý cạnh con trỏ (CaretSuggestions.swift):
// sửa lỗi gõ sai (cổng kích hoạt, bản sửa, chữ hoa, giữ ranh giới, Esc nhớ từ), thêm dấu cho
// cụm không dấu (bộ đếm ở ranh giới, cụm đọc từ màn hình, kết quả), ngày giờ (cụm kích hoạt,
// định dạng, thay cụm) + luật phím chung (chỉ Tab) + tắt ⇒ không làm gì. Không tạo cửa sổ.
// Số đo precision/recall của sửa lỗi gõ: TypoFixEvalTests.
import XCTest
@testable import VietTelex
import TelexCore

final class CaretSuggestionsTests: XCTestCase {
    override func tearDown() { CaretHint.shared.setPendingForTesting(nil) }

    // MARK: Tiếng Anh nhẹ

    /// EnglishLite (mmap + offset) phải trả lời y hệt SwipeEnglish (giải mã đầy đủ).
    func testEnglishLiteMatchesSwipeEnglish() {
        let words = SwipeEnglish.lexicon.words
        XCTAssertGreaterThan(words.count, 1000)
        XCTAssertEqual(EnglishLite.count, words.count)
        for w in words { XCTAssertTrue(EnglishLite.contains(w), w) }
        for w in ["tpoi", "zzzq", "", "githubx", "aaaaaaaaaaaaaaaaaaaaaaaaa"] where !words.contains(w) {
            XCTAssertFalse(EnglishLite.contains(w), w)
        }
    }

    // MARK: 1. Sửa lỗi gõ sai

    private let flags = AppState.EngineFlags()
    private func fix(_ raw: String) -> String? { TypoFixLogic.lexiconCorrection(raw: raw, flags: flags) }

    func testTypoGateOnlyInvalidLetterWordsAtBoundary() {
        XCTAssertTrue(TypoFixLogic.worthChecking(boundary: " ", raw: "tpoi", word: "tpoi"))
        XCTAssertTrue(TypoFixLogic.worthChecking(boundary: ",", raw: "tpoi", word: "tpoi"))
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: ".", raw: "tpoi", word: "tpoi"))   // tên miền, giờ
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: "'", raw: "tpoi", word: "tpoi"))
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: "\n", raw: "tpoi", word: "tpoi"))  // Enter có thể đã gửi
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: " ", raw: "tooi", word: "tôi"))    // âm tiết hợp lệ
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: " ", raw: "kp", word: "kp"))       // quá ngắn
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: " ", raw: "tp1i", word: "tp1i"))   // có số
        XCTAssertFalse(TypoFixLogic.worthChecking(boundary: " ", raw: "tpoi", word: "(tpoi"))  // dính ký hiệu
    }

    func testTypoFixesAdjacentKeyAndSwap() {
        XCTAssertEqual(fix("tpoi"), "tôi")          // p kề o
        XCTAssertEqual(fix("Tpoi"), "Tôi")
        XCTAssertEqual(fix("khoong"), nil)          // đã đúng (không)
        XCTAssertEqual(fix("khpong"), "không")      // p kề o
        XCTAssertEqual(fix("nhuwng"), nil)          // đúng: nhưng
    }

    /// Tiếng Anh (Phil 16/10/2026): không có bản sửa tiếng Việt ⇒ bản sửa tiếng Anh MỘT sửa trên
    /// phím thô, chỉ khi phổ biến và bỏ xa ứng viên thứ hai (TypoFixEvalTests đo P/R).
    func testTypoFixesEnglish() {
        XCTAssertEqual(fix("spellnig"), "spelling")   // đảo hai phím, từ dài: ngưỡng tần suất thấp hơn
        XCTAssertEqual(fix("Spellnig"), "Spelling")
        XCTAssertEqual(fix("teh"), "the")
        XCTAssertEqual(fix("becuase"), "because")
        XCTAssertEqual(fix("recieve"), "receive")
        XCTAssertEqual(fix("peopel"), "people")
        XCTAssertEqual(fix("goverment"), "government") // sót phím (từ ≥ 5 chữ)
        XCTAssertNil(fix("hte"))                       // the 255 vs he 245 (bỏ phím): quá sát
        XCTAssertNil(fix("kubectl"))                   // không gần từ nào
        XCTAssertEqual(fix("tpoi"), "tôi", "tiếng Việt vẫn đi trước")
    }

    /// "Lọc từ nhạy cảm" bật ⇒ bản sửa là từ tục thì bỏ lượt; tắt ⇒ như mọi từ.
    func testTypoFixRespectsSensitiveFilter() {
        func c(_ on: Bool) -> String? {
            TypoFixLogic.correction(raw: "shjt", compose: { $0 }, frequency: { _ in nil }, hasCompletion: { _ in false },
                                    isKnown: { _ in false }, englishFrequency: { $0 == "shit" ? 200 : nil },
                                    filterSensitive: on)
        }
        XCTAssertNil(c(true))
        XCTAssertEqual(c(false), "shit")
    }

    func testTypoLeavesKnownWordsAlone() {
        XCTAssertNil(fix("github"))                 // tiếng Anh
        XCTAssertNil(fix("hello"))
        XCTAssertNil(fix("toi"))                    // không dấu = dạng hợp lệ
        XCTAssertNil(fix("tooi"))                   // đúng
        XCTAssertTrue(TypoFixLogic.isKnown("the"))
        XCTAssertFalse(TypoFixLogic.isKnown("tpoi"))
    }

    /// Ứng viên thứ hai sát nút ⇒ không đủ chắc; loại sửa không đề xuất vẫn là đối thủ.
    func testTypoPickNeedsMarginIncludingRivals() {
        typealias C = TypoFixLogic.Cand
        let p = TypoFixLogic.Params(minLen: 3, minFreq: 150, margin: 80, edits: [.sub, .swap], rivals: [.del, .ins])
        XCTAssertEqual(TypoFixLogic.pick([C(word: "tôi", freq: 255, edit: .sub)], p: p)?.word, "tôi")
        XCTAssertNil(TypoFixLogic.pick([C(word: "tôi", freq: 140, edit: .sub)], p: p))           // không đủ phổ biến
        XCTAssertNil(TypoFixLogic.pick([C(word: "tôi", freq: 255, edit: .sub),
                                        C(word: "tới", freq: 200, edit: .sub)], p: p))           // sát nút
        XCTAssertNil(TypoFixLogic.pick([C(word: "tội", freq: 175, edit: .sub),
                                        C(word: "tôi", freq: 255, edit: .del)], p: p))           // đối thủ thắng
        XCTAssertEqual(TypoFixLogic.pick([C(word: "tôi", freq: 255, edit: .sub),
                                          C(word: "tối", freq: 150, edit: .ins)], p: p)?.word, "tôi")
    }

    /// Tab thay đúng từ + GIỮ ranh giới; từ phải đứng riêng; hoa đầu chỉ ở đầu câu.
    func testTypoSuggestionKeepsBoundaryAndCase() {
        let t = TypoFixLogic.suggestion(before: "anh tpoi,", word: "tpoi", boundary: ",", raw: "tpoi", fix: "tôi")
        XCTAssertEqual(t, CaretSuggestion(kind: .typo, display: "tôi", replace: "tpoi,", insert: "tôi,"))
        XCTAssertNil(TypoFixLogic.suggestion(before: "anh xtpoi ", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"))
        XCTAssertNil(TypoFixLogic.suggestion(before: "anh tpoi", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"))
        XCTAssertNotNil(TypoFixLogic.suggestion(before: "Xong. Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"))
        XCTAssertNotNil(TypoFixLogic.suggestion(before: "Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"))
        XCTAssertNil(TypoFixLogic.suggestion(before: "gặp Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"))
    }

    func testDeclineRemembersTypoWord() {
        let hint = CaretHint.shared
        hint.setPendingForTesting(CaretSuggestion(kind: .typo, display: "tôi", replace: "Tpoi ", insert: "Tôi "))
        XCTAssertFalse(hint.isTypoRejectedForTesting("tpoi"))
        hint.decline()
        XCTAssertFalse(hint.isShowing)
        XCTAssertTrue(hint.isTypoRejectedForTesting("tpoi"))
        XCTAssertTrue(hint.isTypoRejectedForTesting("TPOI"))
    }

    // MARK: 2. Thêm dấu cho cụm không dấu

    private func feed(_ t: inout ToneRunLogic.Tracker, _ text: String) -> [ToneRunLogic.Trigger?] {
        // Mô phỏng dòng phím: mỗi ranh giới báo cụm đã chốt ngay trước nó.
        var out: [ToneRunLogic.Trigger?] = []
        var chunk = ""
        for ch in text {
            if ch.isLetter || ch.isNumber { chunk.append(ch); continue }
            out.append(t.feed(chunk: chunk, boundary: String(ch)))
            chunk = ch.isWhitespace ? "" : chunk + String(ch)
        }
        return out
    }

    func testToneTrackerTriggers() {
        var t = ToneRunLogic.Tracker()
        XCTAssertEqual(feed(&t, "toi di hoc "), [nil, nil, .pause])
        XCTAssertEqual(feed(&t, "hom nay "), [.pause, .pause])
        t.reset()
        XCTAssertEqual(feed(&t, "toi di hoc."), [nil, nil, .sentenceEnd])
        XCTAssertEqual(feed(&t, " roi "), [nil, nil])                          // câu mới: đếm lại
        t.reset()
        XCTAssertEqual(feed(&t, "toi, di hoc "), [nil, nil, nil, .pause])       // "toi," vẫn là âm tiết
        t.reset()
        XCTAssertEqual(feed(&t, "tôi di hoc "), [nil, nil, nil])               // có dấu ⇒ đếm lại
        t.reset()
        XCTAssertEqual(feed(&t, "the cat is "), [nil, nil, nil])               // tiếng Anh
        t.reset()
        XCTAssertEqual(feed(&t, "toi di\nhoc "), [nil, nil, nil])              // xuống dòng
        t.reset()
        XCTAssertEqual(feed(&t, "a b "), [nil, nil])
    }

    /// Hồi quy (Phil 18/10/2026): "Ngay mai minh se den truong hop lop cap 3." không ra gợi ý —
    /// số "3" làm bộ đếm về 0. Số giữ nguyên trong cụm, không đếm, không ngắt.
    func testNumbersInsideUnaccentedRunDoNotBreakIt() {
        var t = ToneRunLogic.Tracker()
        let trig = feed(&t, "ngay mai minh se den truong hop lop cap 3.")
        XCTAssertEqual(trig.last, .sentenceEnd)
        XCTAssertEqual(ToneRunLogic.run(before: "Ngay mai minh se den truong hop lop cap 3."),
                       "Ngay mai minh se den truong hop lop cap 3.")
        XCTAssertEqual(ToneRunLogic.run(before: "hen gap luc 10:30 nhe "), "hen gap luc 10:30 nhe ")
        XCTAssertTrue(ToneRunLogic.isNeutralNumber("3."))
        XCTAssertTrue(ToneRunLogic.isNeutralNumber("16/10"))
        XCTAssertFalse(ToneRunLogic.isNeutralNumber("mp3"))
        XCTAssertFalse(ToneRunLogic.isNeutralNumber("..."))
        XCTAssertNil(ToneRunLogic.run(before: "toi 3 "))           // chỉ 1 âm tiết + số ⇒ chưa đủ
    }

    /// Hồi quy (Phil 18/10/2026): "Thu go tieng Viet khong dau xem sao." chỉ gợi ý nửa sau —
    /// vần không dấu của iê/uô/ươ (tieng, Viet, truong) bị coi là không hợp lệ.
    func testUnaccentedFormsOfHattedRhymesAreSyllables() {
        for w in ["tieng", "Viet", "truong", "khong", "nguoi", "yeu", "mua", "muon", "duoc", "hoc"] {
            XCTAssertTrue(ToneRunLogic.isUnaccentedSyllable(Substring(w)), w)
        }
        XCTAssertEqual(ToneRunLogic.run(before: "Thu go tieng Viet khong dau xem sao."),
                       "Thu go tieng Viet khong dau xem sao.")
        XCTAssertEqual(ToneRunLogic.run(before: "Minh dang go tieng Viet khong dau."),
                       "Minh dang go tieng Viet khong dau.")
        var t = ToneRunLogic.Tracker()
        XCTAssertEqual(feed(&t, "Minh dang go tieng Viet khong dau.").last, .sentenceEnd)
        XCTAssertFalse(ToneRunLogic.isUnaccentedSyllable("the"))   // đầu cụm: vẫn coi là tiếng Anh
    }

    func testToneRunFromScreen() {
        XCTAssertEqual(ToneRunLogic.run(before: "toi di hoc "), "toi di hoc ")
        XCTAssertEqual(ToneRunLogic.run(before: "Chiều nào toi di hoc hom nay "), "toi di hoc hom nay ")
        XCTAssertEqual(ToneRunLogic.run(before: "Xong. toi di hoc."), "toi di hoc.")
        XCTAssertEqual(ToneRunLogic.run(before: "xin chao ban. toi di hoc "), "toi di hoc ")   // không kéo câu trước
        XCTAssertEqual(ToneRunLogic.run(before: "dong 1\ntoi di hoc "), "toi di hoc ")
        XCTAssertNil(ToneRunLogic.run(before: "toi di "))
        XCTAssertNil(ToneRunLogic.run(before: "tôi đi học "))
        XCTAssertNil(ToneRunLogic.run(before: "open the file "))
    }

    func testToneSuggestionFromAddTones() {
        let run = "toi di hoc "
        let restored = TextActionTransform.addTonesInProcess(run)
        XCTAssertEqual(restored, "tôi đi học ")
        XCTAssertEqual(ToneRunLogic.suggestion(run: run, restored: restored),
                       CaretSuggestion(kind: .tones, display: "tôi đi học", replace: run, insert: "tôi đi học "))
        XCTAssertNil(ToneRunLogic.suggestion(run: run, restored: run))                 // không đổi
        XCTAssertNil(ToneRunLogic.suggestion(run: run, restored: "tôi"))               // lệch độ dài
    }

    func testDeclinedTonesRemembered() {
        let hint = CaretHint.shared
        hint.setPendingForTesting(CaretSuggestion(kind: .tones, display: "tôi đi học", replace: "toi di hoc ",
                                                  insert: "tôi đi học "))
        hint.decline()
        XCTAssertTrue(hint.isTonesDeclinedForTesting("toi di hoc hom nay "))
        XCTAssertFalse(hint.isTonesDeclinedForTesting("hom nay toi "))
    }

    /// Perf: cụm Thêm dấu không ra gợi ý thì lần dừng gõ kế tiếp KHÔNG spawn lại process
    /// con (2 lần đọc AX + chạy nguyên executable) — chỉ khi cụm dài thêm ≥2 âm tiết,
    /// sang cụm khác, hoặc cuối câu.
    func testFruitlessToneRunNotRetriedEveryPause() {
        var m = ToneRunLogic.FruitlessMemo()
        XCTAssertTrue(m.allows("toi di hoc ", trigger: .pause))                // chưa thử lần nào
        m.note(fruitless: "toi di hoc ")
        XCTAssertFalse(m.allows("toi di hoc ", trigger: .pause))               // cùng cụm
        XCTAssertFalse(m.allows("toi di hoc hom ", trigger: .pause))           // +1 âm tiết
        XCTAssertTrue(m.allows("toi di hoc hom nay ", trigger: .pause))        // +2 âm tiết
        XCTAssertTrue(m.allows("toi di hoc hom.", trigger: .sentenceEnd))      // cuối câu luôn thử
        XCTAssertTrue(m.allows("ban an com ", trigger: .pause))                // cụm khác
        m.clear()
        XCTAssertTrue(m.allows("toi di hoc ", trigger: .pause))
        XCTAssertEqual(ToneRunLogic.syllableCount("toi di  hoc "), 3)
        XCTAssertEqual(ToneRunLogic.syllableCount(""), 0)
    }

    // MARK: 3. Ngày giờ

    private let tz = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    /// 28/09/2026 21:35 giờ Việt Nam (thứ Hai).
    private var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 28; c.hour = 21; c.minute = 35
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: c)!
    }

    func testDateDetect() {
        let en: (String) -> Bool = TypoFixLogic.isEnglish
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "hôm", run: "nay", isEnglish: en), .today)
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "Hôm", run: "qua", isEnglish: en), .yesterday)
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "ngày", run: "mai", isEnglish: en), .tomorrow)
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "bây", run: "giờ", isEnglish: en), .now)
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "you", run: "tomorrow", isEnglish: en), .tomorrow)
        XCTAssertEqual(DateHintLogic.detect(boundary: " ", prevRun: "right", run: "now", isEnglish: en), .now)
        XCTAssertNil(DateHintLogic.detect(boundary: " ", prevRun: "", run: "now", isEnglish: en))        // không ngữ cảnh Anh
        XCTAssertNil(DateHintLogic.detect(boundary: " ", prevRun: "gặp", run: "today", isEnglish: en))
        XCTAssertNil(DateHintLogic.detect(boundary: ",", prevRun: "hôm", run: "nay", isEnglish: en))     // chỉ dấu cách
        XCTAssertNil(DateHintLogic.detect(boundary: " ", prevRun: "hom", run: "nay", isEnglish: en))     // không dấu
        XCTAssertNil(DateHintLogic.detect(boundary: " ", prevRun: "hôm", run: "sau", isEnglish: en))
    }

    func testDateFormat() {
        XCTAssertEqual(DateHintLogic.format(.today, now: now, timeZone: tz), "28/09/2026")
        XCTAssertEqual(DateHintLogic.format(.tomorrow, now: now, timeZone: tz), "29/09/2026")
        XCTAssertEqual(DateHintLogic.format(.yesterday, now: now, timeZone: tz), "27/09/2026")
        XCTAssertEqual(DateHintLogic.format(.now, now: now, timeZone: tz), "21:35")
    }

    /// Tab THAY cụm bằng ngày/giờ (ví dụ maintainer: "hôm nay" → "28/09/2026").
    func testDateSuggestionReplacesPhrase() {
        XCTAssertEqual(DateHintLogic.suggestion(before: "Hẹn hôm nay ", prevRun: "hôm", run: "nay", phrase: .today,
                                                now: now, timeZone: tz),
                       CaretSuggestion(kind: .date, display: "28/09/2026", replace: "hôm nay ", insert: "28/09/2026 "))
        XCTAssertEqual(DateHintLogic.suggestion(before: "bây giờ ", prevRun: "bây", run: "giờ", phrase: .now,
                                                now: now, timeZone: tz)?.insert, "21:35 ")
        XCTAssertEqual(DateHintLogic.suggestion(before: "see you tomorrow ", prevRun: "you", run: "tomorrow",
                                                phrase: .tomorrow, now: now, timeZone: tz)?.replace, "tomorrow ")
        XCTAssertNil(DateHintLogic.suggestion(before: "xhôm nay ", prevRun: "hôm", run: "nay", phrase: .today,
                                              now: now, timeZone: tz))                  // không đứng riêng
        XCTAssertNil(DateHintLogic.suggestion(before: "hôm nay", prevRun: "hôm", run: "nay", phrase: .today,
                                              now: now, timeZone: tz))                  // màn hình lệch
    }

    // MARK: Luật chung

    /// Ba loại mới chỉ nhận Tab — Enter sau câu/từ là gửi/xuống dòng, không được cướp.
    func testNewKindsAcceptOnlyTab() {
        typealias L = CaretHintLogic
        for k in [CaretSuggestion.Kind.typo, .tones, .date] {
            XCTAssertEqual(L.action(kind: k, keyCode: L.kTab, plain: true), .accept)
            XCTAssertEqual(L.action(kind: k, keyCode: L.kReturn, plain: true), .dismissPass)
            XCTAssertEqual(L.action(kind: k, keyCode: L.kEscape, plain: true), .dismissConsume)
            XCTAssertEqual(L.action(kind: k, keyCode: 49, plain: true), .dismissPass)
        }
    }

    /// Mỗi phím +1 thế hệ — việc nền kích hoạt trước đó biết là người dùng đã gõ tiếp.
    func testEveryKeyBumpsGeneration() {
        let g = CaretHint.shared.keyGeneration
        _ = CaretHint.shared.keyAction(keyCode: 0, plain: true)
        _ = CaretHint.shared.keyAction(keyCode: 1, plain: true, panelOnly: true)
        XCTAssertEqual(CaretHint.shared.keyGeneration, g &+ 2)
    }

    /// Tắt cả ba ⇒ controller không gọi gì (một lần đọc cờ `wordHintsEnabled`).
    func testOffMeansNoWork() {
        let s = AppState.shared
        let before = (s.typoHints, s.toneHints, s.dateHints)
        defer { s.typoHints = before.0; s.toneHints = before.1; s.dateHints = before.2 }
        s.typoHints = false; s.toneHints = false; s.dateHints = false
        XCTAssertFalse(CaretHint.shared.wordHintsEnabled)
        s.toneHints = true
        XCTAssertTrue(CaretHint.shared.wordHintsEnabled && CaretHint.shared.tonesEnabled)
        XCTAssertFalse(CaretHint.shared.typoEnabled || CaretHint.shared.dateEnabled)
    }

    /// Không thay được chữ đã chốt (app marked) ⇒ không làm gì, kể cả khi bật.
    func testNoReplaceNoWork() {
        let g = CaretHint.shared.keyGeneration
        CaretHint.shared.afterWord(.init(boundary: " ", run: "nay", prevRun: "hôm", raw: "nay", anchored: true, tones: nil),
                                   client: nil, controller: nil, canReplace: false)
        XCTAssertFalse(CaretHint.shared.isShowing)
        XCTAssertEqual(CaretHint.shared.keyGeneration, g)
    }

}
