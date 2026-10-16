// WordPredictionTests — gợi ý từ cạnh con trỏ (WordPrediction.swift): công tắc theo cài đặt
// hệ thống "Show inline predictive text", dựng ngữ cảnh từ văn bản trước con trỏ, xếp hạng
// (dùng chung thanh gợi ý iOS), từ kế tiếp chỉ theo trigram 2 từ, thay đúng từ đang soạn, MỘT
// ứng viên trên CaretHint, đo đạc; seed từ kế tiếp (một từ ngữ cảnh), tiếng Anh giữa câu Việt,
// công tắc "Lọc từ nhạy cảm".
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
        XCTAssertFalse(candidates("cảm ơn ").isEmpty, "hai từ ngữ cảnh có dòng trigram ⇒ có gợi ý")
        XCTAssertFalse(candidates("xin chào ").isEmpty, "\(candidates("xin chào "))")
        XCTAssertEqual(candidates("hôm nay ").count <= L.rankDepth, true)
        XCTAssertEqual(candidates("hello world ", english: true), [], "tiếng Anh: không có dữ liệu từ kế tiếp")
        XCTAssertEqual(candidates("zzqx zzqy "), [], "từ lạ: không gợi ý")
    }

    /// Hồi quy (Phil 16/10/2026): "Tên ␣" → "gọi" là đoán mò từ bigram một từ. Từ kế tiếp từ LM
    /// tĩnh chỉ khi có đủ HAI từ ngữ cảnh VÀ vnlm.bin có dòng trigram — không lùi bigram. Một từ
    /// ngữ cảnh chỉ ra gợi ý khi có cặp SEED curated của iOS ("cảm" → ơn, "xin" → lỗi).
    func testNextWordNeedsTwoWordTrigramOrSeed() {
        XCTAssertEqual(candidates("Tên "), [], "một từ ngữ cảnh, không seed: không gợi ý")
        XCTAssertEqual(candidates("xong, tên "), [], "dấu phẩy cắt ngữ cảnh ⇒ chỉ một từ")
        XCTAssertEqual(candidates("zzqx tên "), [], "bigram tĩnh có nhưng không trigram, không seed")
        XCTAssertFalse(L.wantsNextWord(.init(typed: "", prev: "tên", prev2: nil, english: false)))
        XCTAssertTrue(L.wantsNextWord(.init(typed: "", prev: "ơn", prev2: "cảm", english: false)))
        XCTAssertFalse(L.wantsNextWord(.init(typed: "", prev: "ơn", prev2: "cảm", english: true)))
        XCTAssertTrue(L.wantsSeedNext(.init(typed: "", prev: "cảm", prev2: nil, english: false)))
        XCTAssertFalse(L.wantsSeedNext(.init(typed: "c", prev: "cảm", prev2: nil, english: false)))
        // Hai từ có dòng trigram ⇒ hạng 1 = hàng đầu dòng trigram (iOS nextFill: trigram trước seed).
        let top = SuggestRank.topNext("ơn", prev2: "cảm", limit: 6)
        XCTAssertEqual(top?.trigram, true)
        XCTAssertEqual(candidates("cảm ơn ").first?.lowercased(),
                       SensitiveWords.filter(top?.words ?? [], enabled: true).first?.lowercased())
    }

    /// Seed iOS (SeedNextData = UserLangModel.nextWords của người dùng mới): một từ ngữ cảnh.
    func testSeedNextWord() {
        XCTAssertEqual(candidates("cảm ").first, "ơn")
        XCTAssertEqual(candidates("Cảm ").first, "ơn")
        XCTAssertEqual(candidates("xin ").first, "lỗi", "\(candidates("xin "))")
        XCTAssertTrue(candidates("xin ").contains("chào"))
        XCTAssertEqual(candidates("hôm ").first, "nay")
        XCTAssertEqual(candidates("zzqx cảm ").first, "ơn", "không trigram ⇒ seed")
        XCTAssertEqual(candidates("nguyễn ").first, "Văn", "chuỗi tên: DisplayCase")
        XCTAssertEqual(candidates("good ", english: true).first, "morning", "tiếng Anh: chỉ từ tiếng Anh")
        XCTAssertEqual(candidates("anh ", english: true), [], "ngữ cảnh Anh: từ kế tiếp Việt bị bỏ")
        // Bảng: dòng hợp lệ, NFC, chữ thường; cảm → ơn đứng đầu (seed iOS).
        let t = SeedNextData.table()
        XCTAssertGreaterThan(t.count, 200)
        XCTAssertEqual(t["cảm"]?.first, "ơn")
        for (k, v) in t {
            XCTAssertFalse(v.isEmpty, k)
            XCTAssertEqual(k, k.lowercased().precomposedStringWithCanonicalMapping)
            XCTAssertLessThanOrEqual(v.count, 24)
        }
    }

    /// Công tắc "Lọc từ nhạy cảm": bật (mặc định) ⇒ không bao giờ đưa từ tục; tắt ⇒ như iOS,
    /// seed/LM được hiện nguyên ("ngon ␣" → vl là cặp seed iOS).
    func testSensitiveFilterToggle() {
        func c(_ before: String, _ typed: String = "", _ raw: String = "", on: Bool) -> [String] {
            guard let r = L.request(before: before, typed: typed, english: false) else { return [] }
            return PredictionModel.shared.candidates(r, raw: raw, filterSensitive: on)
        }
        XCTAssertEqual(c("vãi ", on: true).first, "cả")
        XCTAssertEqual(c("vãi ", on: false).first, "lồn")
        XCTAssertEqual(c("ngon ", on: true), [], "seed chỉ có từ nhạy cảm ⇒ bật lọc: không gì")
        XCTAssertEqual(c("ngon ", on: false).first, "vl")
        XCTAssertFalse(c("đị", "đị", "ddij", on: true).contains("địt"))
        XCTAssertEqual(AppState.shared.defaults.object(forKey: "filterSensitive") as? Bool ?? true,
                       AppState.shared.filterSensitive)
        XCTAssertTrue(MacSyncStore.settings.contains { $0.canonical == "filterSensitive" }, "đồng bộ như iOS")
    }

    /// Tiếng Anh giữa câu Việt: chỉ khi phím thô là tiền tố tiếng Anh rõ ràng hơn mọi cách đọc
    /// tiếng Việt (prefersEnglish) — "pers" hiện "pé" → person; KHÔNG BAO GIỜ khi chữ đang gõ là
    /// âm tiết Việt trọn vẹn phổ biến (toi, duoc, cam, thẻ, thin, chan).
    func testEnglishInVietnameseContext() {
        XCTAssertEqual(candidates("tôi gặp pé", typed: "pé", raw: "pers").first, "person")
        XCTAssertEqual(candidates("ưởn", typed: "ưởn", raw: "wron").first, "wrong")
        XCTAssertEqual(candidates("bạn tech", typed: "tech", raw: "tech").first, "technology")
        for (typed, raw) in [("toi", "toi"), ("duoc", "duoc"), ("cam", "cam"), ("thẻ", "ther"),
                             ("thin", "thin"), ("chan", "chan"), ("thanh", "thanh"), ("khô", "khoo")] {
            let c = candidates("anh " + typed, typed: typed, raw: raw)
            XCTAssertFalse(c.contains { EnglishLite.contains($0.lowercased()) && !VNSuggest.contains($0) },
                           "\(raw) → \(c)")
        }
    }

    /// Bảo thủ: mọi tiền tố ≥ 4 phím (Telex, hai kiểu đặt dấu) và dạng không dấu của âm tiết
    /// trong câu heldout ⇒ prefersEnglish KHÔNG BAO GIỜ bật (đo 16/10/2026: 0 / ~36k).
    func testEnglishOverrideNeverFiresOnVietnamese() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/KeyboardTests/Fixtures/bigram-heldout.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let syllables = Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }
            .flatMap { $0.split(separator: " ").map(String.init) })
        let compose = TypoFixLogic.composer(AppState.EngineFlags())
        var checked = 0, fired: [String] = []
        for s in syllables {
            var raws = TelexKeys.variants(s).filter { $0.count >= 4 }.flatMap { v in (4...v.count).map { String(v.prefix($0)) } }
            let t = TelexKeys.toneless(s)
            if t.count >= 4 { raws.append(t) }
            for raw in raws {
                let typed = compose(raw)
                let pool = VNSuggest.matches(typed, poolLimit: 24, excluding: typed.lowercased())
                guard !pool.isEmpty else { continue }   // không khớp gì: đường tiếng Anh cũ
                checked += 1
                if L.prefersEnglish(raw: raw, typed: typed, pool: pool.map { ($0.word, $0.freq) },
                                    typedFreq: VNSuggest.frequency(of: typed),
                                    englishTop: EnglishLite.completions(raw, limit: 1).first?.freq) {
                    fired.append("\(raw)/\(typed)")
                }
            }
        }
        print("PREDICT EN-OVERRIDE vietnamese prefixes checked \(checked), fired \(fired.count): \(fired.prefix(10))")
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertEqual(fired, [])
    }

    func testNextWordDisplayCase() {
        let c = candidates("thành phố hồ ")
        XCTAssertFalse(c.contains("chí"), "\(c)")
        XCTAssertEqual(c.first, "Chí", "\(c)")
        if c.contains(where: { $0.lowercased() == "chí" }) { XCTAssertTrue(c.contains("Chí")) }
    }

    func testCompletionRanking() {
        let c = candidates("tôi đư", typed: "đư", raw: "dduw")
        XCTAssertTrue(c.contains("được"), "\(c)")
        XCTAssertLessThanOrEqual(c.count, L.rankDepth)
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
        XCTAssertEqual(s, CaretSuggestion(kind: .predict, display: "được", replace: "đư", insert: "được "),
                       "chỉ hạng 1 — không danh sách")
        XCTAssertEqual(L.maxCandidates, 1)
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

    func testSingleCandidateKeysAndClick() {
        let hint = CaretHint.shared
        let s = L.suggestion(["được", "đường", "đưa"], typed: "đư")!
        hint.setPendingForTesting(s)
        XCTAssertEqual(hint.candidateStrings, ["được"], "một ứng viên")
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kTab, plain: true), .accept)
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kReturn, plain: true), .dismissPass,
                       "Enter không bao giờ chọn gợi ý từ")
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: 125 /* ↓ */, plain: true), .dismissPass)
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: CaretHintLogic.kEscape, plain: true), .dismissConsume)
        // phím số không chọn (không có số thứ tự)
        XCTAssertEqual(CaretHintLogic.action(kind: .predict, keyCode: 18 /* "1" */, plain: true), .dismissPass)
        XCTAssertEqual(hint.take()?.insert, "được ", "Tab / click = ứng viên duy nhất")
        XCTAssertFalse(hint.isShowing)
    }

    func testOtherHintsWinOverPrediction() {
        // Gợi ý khác đang hiện ⇒ không lên lịch gợi ý từ.
        XCTAssertFalse(L.shouldSchedule(settingOn: true, canReplace: true, otherHint: CaretHint.shared.isShowing || true))
        let typo = CaretSuggestion(kind: .typo, display: "the", replace: "teh ", insert: "the ")
        CaretHint.shared.setPendingForTesting(typo)
        XCTAssertTrue(CaretHint.shared.isShowing)
        XCTAssertEqual(CaretHint.shared.candidateStrings, ["the"])
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
        _ = candidates("cảm ơn ")                    // nạp
        _ = candidates("tôi đư", typed: "đư", raw: "dduw")
        let next = ["cảm ơn ", "xin chào ", "tôi đang ", "hôm nay ", "đi học ", "không có ", "anh ấy ",
                    "chúng ta ", "nhà của ", "tôi và "]
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
        let r = PredictionLogic.request(before: "cảm ơn ", typed: "", english: false)!
        _ = PredictionModel.shared.candidates(r, raw: "")                   // đếm seed
        let r2 = PredictionLogic.request(before: "tôi đư", typed: "đư", english: false)!
        _ = PredictionModel.shared.candidates(r2, raw: "dduw")
        let m3 = sample()
        for before in ["xin chào ", "tôi đang ", "hôm nay ", "anh ấy ", "nhà của ", "tôi và ", "không có "] {
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
            ("cảm ơn ", "", "", false), ("xin chào ", "", "", false), ("tôi đang ", "", "", false),
            ("hôm nay ", "", "", false), ("Tên ", "", "", false), ("thành phố hồ ", "", "", false),
            ("tôi đư", "đư", "dduw", false), ("xin ch", "ch", "ch", false), ("khô", "khô", "khoo", false),
            ("my keyb", "keyb", "keyb", false), ("this is beca", "beca", "beca", true)]
        for c in cases {
            guard let r = PredictionLogic.request(before: c.0, typed: c.1, english: c.3) else { continue }
            print("PREDICT SAMPLE '\(c.0)' → \(PredictionModel.shared.candidates(r, raw: c.2))")
        }
    }
}

/// Chuỗi phím Telex của một âm tiết (dấu thanh cuối / trước phụ âm cuối) + dạng không dấu —
/// cho các bài đo bảo thủ (bản rút gọn TypoFixEvalTests.variants).
enum TelexKeys {
    static func variants(_ syllable: String) -> [String] {
        var chars: [String] = []
        var tone: Character?
        for u in syllable.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.value {
            case 0x302: guard let k = chars.last else { return [] }; chars[chars.count - 1] = k + k
            case 0x306, 0x31B: guard let k = chars.last else { return [] }; chars[chars.count - 1] = k + "w"
            case 0x301: tone = "s"
            case 0x300: tone = "f"
            case 0x309: tone = "r"
            case 0x303: tone = "x"
            case 0x323: tone = "j"
            case 0x111: chars.append("dd")
            case 0x61...0x7A: chars.append(String(Character(u)))
            default: return []
            }
        }
        guard !chars.isEmpty else { return [] }
        let all = chars.joined()
        guard let t = tone else { return [all] }
        var lastVowel = -1
        for (i, c) in chars.enumerated() where "aeiouy".contains(c.first!) { lastVowel = i }
        guard lastVowel >= 0, lastVowel < chars.count - 1 else { return [all + String(t)] }
        return [all + String(t), chars[0...lastVowel].joined() + String(t) + chars[(lastVowel + 1)...].joined()]
    }

    static func toneless(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().replacingOccurrences(of: "đ", with: "d")
            .decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.value < 0x300 || $0.value > 0x36F }))
    }
}
