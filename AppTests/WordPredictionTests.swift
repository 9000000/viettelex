// WordPredictionTests — gợi ý từ cạnh con trỏ (WordPrediction.swift): công tắc theo cài đặt
// hệ thống "Show inline predictive text", dựng ngữ cảnh từ văn bản trước con trỏ, xếp hạng
// (dùng chung thanh gợi ý iOS), thay đúng từ đang soạn, nhiều ứng viên trên CaretHint, đo đạc.
import XCTest
@testable import VietTelex

final class WordPredictionTests: XCTestCase {
    private typealias L = PredictionLogic

    override func tearDown() {
        CaretHint.shared.setPendingForTesting(nil)
        SystemInlinePrediction.setForTesting(nil)
    }

    // MARK: Công tắc

    func testSettingValueResolution() {
        XCTAssertTrue(SystemInlinePrediction.resolve(nil), "không có khoá ⇒ mặc định macOS (bật)")
        XCTAssertTrue(SystemInlinePrediction.resolve(NSNumber(value: 1)))
        XCTAssertFalse(SystemInlinePrediction.resolve(NSNumber(value: 0)))
        XCTAssertFalse(SystemInlinePrediction.resolve(false))
        XCTAssertTrue(SystemInlinePrediction.resolve(true))
        XCTAssertFalse(SystemInlinePrediction.resolve("0"))
        XCTAssertEqual(SystemInlinePrediction.key, "NSAutomaticInlinePredictionEnabled")
    }

    func testSettingOffSchedulesNothingAndCostsNothing() {
        var evaluated = false
        func canReplace() -> Bool { evaluated = true; return true }
        XCTAssertFalse(L.shouldSchedule(settingOn: false, canReplace: canReplace()))
        XCTAssertFalse(evaluated, "tắt ⇒ không tính gì thêm (không hỏi app)")
        XCTAssertTrue(L.shouldSchedule(settingOn: true, canReplace: canReplace()))
        XCTAssertTrue(evaluated)
        XCTAssertFalse(L.shouldSchedule(settingOn: true, canReplace: false))
        XCTAssertFalse(L.shouldSchedule(settingOn: true, canReplace: true, secure: true))
        XCTAssertFalse(L.shouldSchedule(settingOn: true, canReplace: true, otherHint: true))
    }

    func testForcedSettingWins() {
        SystemInlinePrediction.setForTesting(false)
        XCTAssertFalse(SystemInlinePrediction.isOn)
        SystemInlinePrediction.setForTesting(true)
        XCTAssertTrue(SystemInlinePrediction.isOn)
    }

    // MARK: Ngữ cảnh từ màn hình

    func testRequestWhileComposing() {
        let r = L.request(before: "xin chào bạn đư", typed: "đư", english: false)
        XCTAssertEqual(r, .init(typed: "đư", prev: "bạn", prev2: "chào", english: false))
        XCTAssertEqual(L.request(before: "đư", typed: "đư", english: false),
                       .init(typed: "đư", prev: nil, prev2: nil, english: false))
        XCTAssertNil(L.request(before: "abc.đư", typed: "đư", english: false), "không đứng riêng")
        XCTAssertNil(L.request(before: "chào đ", typed: "đ", english: false), "1 chữ: không gợi ý")
        XCTAssertNil(L.request(before: "chào đư", typed: "đươ", english: false), "màn hình lệch")
        XCTAssertNil(L.request(before: "a1", typed: "a1", english: false))
    }

    func testRequestNextWord() {
        XCTAssertEqual(L.request(before: "cảm ", typed: "", english: false),
                       .init(typed: "", prev: "cảm", prev2: nil, english: false))
        XCTAssertEqual(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev, "đang")
        XCTAssertEqual(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev2, "tôi")
        XCTAssertEqual(L.request(before: "xin chào, bạn ", typed: "", english: false),
                       .init(typed: "", prev: "bạn", prev2: nil, english: false), "dấu phẩy cắt ngữ cảnh")
        XCTAssertEqual(L.request(before: "dòng một\nđi ", typed: "", english: false)?.prev2, nil)
        XCTAssertNil(L.request(before: "hai  ", typed: "", english: false), "hai dấu cách")
        XCTAssertNil(L.request(before: "xong. ", typed: "", english: false), "sau dấu câu")
        XCTAssertNil(L.request(before: " ", typed: "", english: false))
        XCTAssertNil(L.request(before: "", typed: "", english: false))
        XCTAssertNil(L.request(before: "a.b ", typed: "", english: false), "không phải từ đứng riêng")
    }

    // MARK: Xếp hạng (dữ liệu thật, dùng chung iOS)

    private func candidates(_ before: String, typed: String = "", raw: String = "", english: Bool = false) -> [String] {
        guard let r = L.request(before: before, typed: typed, english: english) else { return [] }
        return PredictionModel.shared.candidates(r, raw: raw)
    }

    func testNextWordRanking() {
        XCTAssertEqual(candidates("cảm ").first, "ơn")
        XCTAssertTrue(candidates("xin ").contains("chào"), "\(candidates("xin "))")
        XCTAssertTrue(candidates("hôm ").contains("nay"), "\(candidates("hôm "))")
        XCTAssertLessThanOrEqual(candidates("đi ").count, L.maxCandidates)
        XCTAssertEqual(candidates("hello ", english: true), [], "tiếng Anh: không có dữ liệu từ kế tiếp")
        XCTAssertEqual(candidates("zzqx "), [], "từ lạ: không gợi ý")
    }

    func testNextWordDisplayCase() {
        let c = candidates("hồ ")
        XCTAssertFalse(c.contains("chí"), "\(c)")
        if c.contains(where: { $0.lowercased() == "chí" }) { XCTAssertTrue(c.contains("Chí")) }
    }

    func testCompletionRanking() {
        let c = candidates("tôi đư", typed: "đư", raw: "dduw")
        XCTAssertTrue(c.contains("được"), "\(c)")
        XCTAssertLessThanOrEqual(c.count, L.maxCandidates)
        for w in c { XCTAssertGreaterThan(w.count, 2, "chỉ hoàn thành thật: \(w)") }
        // chữ hoa theo chữ đã gõ
        let up = candidates("Đư", typed: "Đư", raw: "Dduw")
        XCTAssertTrue(up.allSatisfy { $0.first?.isUppercase == true }, "\(up)")
    }

    func testCompletionContextMatters() {
        // ngữ cảnh trigram/bigram tĩnh: "cảm ơ" → ơn đứng đầu
        XCTAssertEqual(candidates("cảm ơ", typed: "ơ", raw: "ow"), [], "1 chữ: không gợi ý")
        let c = candidates("xin ch", typed: "ch", raw: "ch")
        XCTAssertEqual(c.first, "chào", "\(c)")
    }

    func testEnglishCompletion() {
        let c = candidates("my keyb", typed: "keyb", raw: "keyb")
        XCTAssertTrue(c.contains("keyboard"), "không âm tiết Việt nào khớp ⇒ tiếng Anh: \(c)")
        let e = candidates("this is beca", typed: "beca", raw: "beca", english: true)
        XCTAssertTrue(e.contains("because"), "\(e)")
        // Telex đã đổi chữ trên màn hình ("thí"), phím thô vẫn là "this" ⇒ hoàn thành theo phím thô
        let t = candidates("thí", typed: "thí", raw: "this", english: true)
        XCTAssertTrue(t.allSatisfy { $0.hasPrefix("this") && $0.count > 4 }, "\(t)")
    }

    func testEnglishLiteCompletionsMatchSwipeEnglish() {
        for p in ["a", "th", "keyb", "Hel", "HEL", "zzz", "beca", "x"] {
            XCTAssertEqual(EnglishLite.completions(p, limit: 24), SwipeEnglish.completions(p, limit: 24), p)
        }
        XCTAssertEqual(EnglishLite.completions("đi"), [])
    }

    func testSensitiveWordsNeverSuggested() {
        for (before, typed) in [("đị", "đị"), ("đi", "đi"), ("fu", "fu"), ("sh", "sh"), ("vc", "vc")] {
            let c = candidates(before, typed: typed, raw: typed)
            XCTAssertTrue(c.allSatisfy { !SensitiveWords.set.contains($0.lowercased()) }, "\(c)")
        }
    }

    // MARK: Gợi ý trên CaretHint

    func testSuggestionReplacesComposingWord() {
        let s = L.suggestion(["được", "đường", "đưa", "đứng"], typed: "đư")!
        XCTAssertEqual(s.kind, .predict)
        XCTAssertEqual(s.replace, "đư", "thay đúng từ đang soạn (đã nằm trên màn hình — in-place)")
        XCTAssertEqual(s.insert, "được ")
        XCTAssertEqual(s.all.map(\.display), ["được", "đường", "đưa"], "tối đa 3")
        XCTAssertEqual(s.alternates[1].insert, "đưa ")
        // bước áp dụng kiểm lại màn hình: từ phải đứng riêng ngay trước con trỏ
        XCTAssertTrue(CaretHintLogic.standsAlone(before: "anh đư", token: s.replace))
        XCTAssertFalse(CaretHintLogic.standsAlone(before: "anhđư", token: s.replace))
        XCTAssertFalse(CaretHintLogic.standsAlone(before: "anh đươ", token: s.replace))
        let window = "chào đư"
        let n = (window as NSString).length
        XCTAssertEqual(ShortcutScreen.tokenRange(caret: 100 + n, token: s.replace, window: window, windowStart: 100),
                       NSRange(location: 105, length: 2))
        XCTAssertNil(L.suggestion([], typed: "x"))
        let next = L.suggestion(["ơn"], typed: "")!
        XCTAssertEqual(next.replace, "", "từ kế tiếp: chỉ chèn")
        XCTAssertEqual(next.insert, "ơn ")
    }

    func testMultipleCandidatesKeysAndClick() {
        let hint = CaretHint.shared
        let s = L.suggestion(["được", "đường", "đưa"], typed: "đư")!
        hint.setPendingForTesting(s)
        XCTAssertEqual(hint.candidateStrings, ["được", "đường", "đưa"])
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kTab, plain: true), .accept)
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kReturn, plain: true), .dismissPass,
                       "Enter không bao giờ chọn gợi ý từ")
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: 125 /* ↓ */, plain: true), .dismissPass)
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kEscape, plain: true), .dismissConsume)
        XCTAssertEqual(hint.take(choosing: "đường")?.insert, "đường ", "click ứng viên phụ")
        XCTAssertFalse(hint.isShowing)
        hint.setPendingForTesting(s)
        XCTAssertEqual(hint.take(choosing: nil)?.insert, "được ", "Tab = ứng viên chính")
        hint.setPendingForTesting(s)
        XCTAssertEqual(hint.take(choosing: "lạ")?.insert, "được ")
    }

    func testOtherHintsWinOverPrediction() {
        // Gợi ý khác đang hiện ⇒ không lên lịch gợi ý từ.
        XCTAssertFalse(L.shouldSchedule(settingOn: true, canReplace: true, otherHint: CaretHint.shared.isShowing || true))
        let typo = CaretSuggestion(kind: .typo, display: "the", replace: "teh ", insert: "the ")
        CaretHint.shared.setPendingForTesting(typo)
        XCTAssertTrue(CaretHint.shared.isShowing)
        XCTAssertEqual(CaretHint.shared.candidateStrings, ["the"], "một ứng viên như cũ")
    }

    func testEscMutesUntilNextWord() {
        XCTAssertTrue(L.muted(typed: "đươ", declined: "đư"))
        XCTAssertTrue(L.muted(typed: "Đư", declined: "đư"))
        XCTAssertFalse(L.muted(typed: "đa", declined: "đư"))
        XCTAssertFalse(L.muted(typed: "", declined: "đư"))
        XCTAssertFalse(L.muted(typed: "đư", declined: nil))
        let hint = CaretHint.shared
        hint.setPendingForTesting(L.suggestion(["được"], typed: "đư"))
        hint.decline()
        XCTAssertFalse(hint.isShowing)
    }

    // MARK: Đo đạc

    /// Thời gian tính một lượt (nền) — đã nạp. In "PREDICT" để đọc số.
    func testPerfPerBoundaryAndPerKey() {
        _ = candidates("cảm ")                       // nạp
        _ = candidates("tôi đư", typed: "đư", raw: "dduw")
        let next = ["cảm ", "xin ", "tôi đang ", "hôm ", "đi ", "không ", "anh ", "chúng ta ", "của ", "và "]
        let comp: [(String, String, String)] = [("tôi đư", "đư", "dduw"), ("xin ch", "ch", "ch"),
                                                ("ng", "ng", "ng"), ("anh th", "th", "th"),
                                                ("my keyb", "keyb", "keyb"), ("khô", "khô", "khoo")]
        let reqs = next.compactMap { L.request(before: $0, typed: "", english: false) }.map { ($0, "") }
            + comp.compactMap { c in L.request(before: c.0, typed: c.1, english: false).map { ($0, c.2) } }
        let rounds = 50
        var worst: UInt64 = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for (r, raw) in reqs {
                let a = DispatchTime.now().uptimeNanoseconds
                _ = PredictionModel.shared.candidates(r, raw: raw)
                worst = max(worst, DispatchTime.now().uptimeNanoseconds - a)
            }
        }
        let avgUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(rounds * reqs.count) / 1000
        print(String(format: "PREDICT per-request avg %.0f µs, worst %.0f µs (%d requests)",
                     avgUs, Double(worst) / 1000, rounds * reqs.count))
        XCTAssertLessThan(avgUs, 3000, "tính nền, nhưng phải nhỏ hơn nhiều so với idleDelay")
    }
}

/// RAM khi nạp gợi ý từ — CHẠY RIÊNG (-only-testing:VietTelexTests/WordPredictionMemoryTests)
/// để số đo là từ trạng thái lạnh. In "PREDICT MEM".
final class WordPredictionMemoryTests: XCTestCase {
    /// (footprint = phys_footprint "Memory" của Activity Monitor; resident = RSS gồm cả trang
    /// mmap sạch của vnlexicon/vnlm/enlexicon đã chạm).
    private func sample() -> (fp: Int64, rss: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (Int64(info.phys_footprint), Int64(info.resident_size)) : (0, 0)
    }

    func testAResidentDeltaOfLoadingModel() {   // "A": chạy trước test khác trong lớp (trạng thái lạnh)
        func mb(_ a: (fp: Int64, rss: Int64), _ b: (fp: Int64, rss: Int64)) -> String {
            String(format: "footprint %+.2f / resident %+.2f MB", Double(b.fp - a.fp) / 1_048_576,
                   Double(b.rss - a.rss) / 1_048_576)
        }
        let m0 = sample()
        _ = VNSuggest.matches("đư", poolLimit: 24)                        // vnlexicon (có thể đã nạp bởi sửa lỗi gõ)
        let m1 = sample()
        _ = SyllableLM.shared?.bigram(0)                                    // vnlm.bin mmap
        _ = EnglishLite.completions("keyb")                                 // enlexicon.bin mmap + bảng offset
        let m2 = sample()
        let r = PredictionLogic.request(before: "cảm ", typed: "", english: false)!
        _ = PredictionModel.shared.candidates(r, raw: "")                   // đếm seed
        let r2 = PredictionLogic.request(before: "tôi đư", typed: "đư", english: false)!
        _ = PredictionModel.shared.candidates(r2, raw: "dduw")
        let m3 = sample()
        for before in ["xin ", "tôi đang ", "hôm ", "anh ", "của ", "và ", "không "] {
            if let r = PredictionLogic.request(before: before, typed: "", english: false) {
                _ = PredictionModel.shared.candidates(r, raw: "")
            }
        }
        let m4 = sample()
        print("PREDICT MEM lexicon: \(mb(m0, m1)); vnlm+English: \(mb(m1, m2)); seed model + first queries: \(mb(m2, m3)); "
              + "7 more boundaries: \(mb(m3, m4)); TOTAL: \(mb(m0, m4))")
        XCTAssertLessThan(m4.fp - m0.fp, 8 << 20)
        PredictionModel.shared.unload()
        XCTAssertFalse(PredictionModel.shared.isLoaded)
    }

    /// In vài lượt mẫu (grep "PREDICT SAMPLE") — đọc bằng mắt, không assert.
    func testPrintSamples() {
        let cases: [(String, String, String, Bool)] = [
            ("cảm ", "", "", false), ("xin ", "", "", false), ("tôi đang ", "", "", false),
            ("hôm ", "", "", false), ("anh ", "", "", false), ("hồ ", "", "", false),
            ("tôi đư", "đư", "dduw", false), ("xin ch", "ch", "ch", false), ("khô", "khô", "khoo", false),
            ("my keyb", "keyb", "keyb", false), ("this is beca", "beca", "beca", true)]
        for c in cases {
            guard let r = PredictionLogic.request(before: c.0, typed: c.1, english: c.3) else { continue }
            print("PREDICT SAMPLE '\(c.0)' → \(PredictionModel.shared.candidates(r, raw: c.2))")
        }
    }
}
