// Predict.swift — GỢI Ý TỪ cho Linux (port macOS App/Sources/WordPrediction.swift, 16/10/2026):
//   a) hoàn thành từ đang gõ ("đư" → được / đường / đưa; tiếng Anh khi ngữ cảnh tiếng Anh, khi
//      không âm tiết Việt nào khớp: "keyb" → keyboard, hoặc khi phím thô là tiền tố tiếng Anh rõ
//      ràng hơn mọi cách đọc tiếng Việt — prefersEnglish: "pers" (hiện "pé") → person);
//   b) từ kế tiếp ngay sau dấu cách: dòng trigram vnlm.bin cho 2 từ ngữ cảnh ("cảm ơn ␣" → bạn),
//      hoặc cặp SEED curated của iOS với một từ ngữ cảnh ("cảm ␣" → ơn — SeedNextData, symlink
//      App/Sources/SeedNextData.swift); không lùi bigram thống kê ("Tên ␣" → không gì).
// MỘT gợi ý (hạng 1) — không danh sách, không số thứ tự; Tab / click nhận, Esc bỏ.
// Logic THUẦN (PredictionLogic.request / completions / wantsEnglish) + xếp hạng
// (PredictionModel.candidates) chép 1:1 từ WordPrediction.swift — file đó kéo CFPreferences /
// CaretHint (AppKit) nên không symlink được. Phần dùng chung thật là SYMLINK tới iOS/Keyboard
// (VNSuggest, SuggestionSupport = SuggestRank, SyllableLM vnlm.bin, SeedData, DisplayCase,
// SensitiveWords, SwipeEnglish) + App/Sources/SeedNextData.swift — đúng bộ file project.yml
// biên dịch cho macOS. Khác macOS:
//  • tiếng Anh: SwipeEnglish.completions / contains / frequency (macOS: EnglishLite trên mmap —
//    test macOS testEnglishLiteCompletionsMatchSwipeEnglish chứng minh cùng kết quả);
//  • "Lọc từ nhạy cảm": [general] filter_sensitive (mặc định bật), gửi theo từng yêu cầu;
//  • chạy trong `viettelex-text-tool --serve` (lệnh "predict", Serve.swift): process IME chỉ lo
//    cổng rẻ + hẹn giờ 0,3 s (linux/common auto_text.h, Session), dữ liệu không vào process IME;
//  • công tắc: [general] word_prediction trong config.toml (mặc định TẮT) — Linux không có cài
//    đặt hệ thống tương đương "Show inline predictive text".
// Học từ bạn gõ (16/10/2026): LearnStore.swift (process con này) + LearnedModel.swift (chung macOS).
import Foundation
import TelexCore

enum PredictionLogic {
    /// Độ sâu danh sách xếp hạng (= WordPrediction.swift rankDepth); bộ gõ chỉ nhận hạng 1.
    static let rankDepth = 3
    /// Hoàn thành từ chỉ khi đã gõ ít nhất bấy nhiêu chữ (1 chữ: quá nhiễu).
    static let minTyped = 2

    struct Request: Equatable {
        /// Từ đang gõ (đang soạn) — "" = gợi ý từ kế tiếp.
        var typed: String
        /// 1–2 từ trước trong CÙNG câu (chữ thường); nil = không có / bị dấu câu cắt.
        var prev: String?
        var prev2: String?
        /// Ngữ cảnh tiếng Anh (engine: từ trước là tiếng Anh).
        var english: Bool
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter }

    /// = WordPrediction.swift PredictionLogic.request (xem chú thích ở đó).
    static func request(before: String, typed: String, english: Bool) -> Request? {
        let b = before.precomposedStringWithCanonicalMapping
        let t = typed.precomposedStringWithCanonicalMapping
        var head: Substring
        if !t.isEmpty {
            guard t.count >= minTyped, t.allSatisfy(isWordChar), b.hasSuffix(t) else { return nil }
            head = b.dropLast(t.count)
            if let l = head.last, !(l == " " || l == "\t" || l == "\u{00A0}" || l.isNewline) { return nil }
        } else {
            guard b.hasSuffix(" ") else { return nil }
            head = b.dropLast()
            guard let l = head.last, isWordChar(l) else { return nil }   // hai dấu cách / sau dấu câu
        }
        var words: [String] = []
        var rest = head
        while words.count < 2 {
            if words.isEmpty, !t.isEmpty {
                guard rest.last == " " else { break }
                rest = rest.dropLast()
            } else if !words.isEmpty {
                guard rest.last == " " else { break }
                rest = rest.dropLast()
            }
            var w = Substring()
            var i = rest.endIndex
            while i > rest.startIndex {
                let j = rest.index(before: i)
                guard isWordChar(rest[j]) else { break }
                i = j
            }
            w = rest[i...]
            guard !w.isEmpty, w.count <= 24 else { break }
            if i > rest.startIndex {
                let c = rest[rest.index(before: i)]
                guard c == " " || c == "\t" || c == "\u{00A0}" || c.isNewline else {
                    break
                }
            }
            words.append(String(w).lowercased())
            rest = rest[..<i]
            if let c = rest.last, c.isNewline { break }
        }
        if t.isEmpty, words.isEmpty { return nil }
        return Request(typed: t, prev: words.first, prev2: words.count > 1 ? words[1] : nil, english: english)
    }

    /// Từ kế tiếp từ LM TĨNH chỉ khi có đủ HAI từ ngữ cảnh (dòng trigram mới có nghĩa) và không
    /// phải ngữ cảnh tiếng Anh. Mô hình còn đòi dòng trigram thật (`SuggestRank.topNext(...).trigram`).
    static func wantsNextWord(_ r: Request) -> Bool {
        r.typed.isEmpty && !r.english && r.prev != nil && r.prev2 != nil
    }

    /// Từ kế tiếp từ SEED (cặp curated của iOS — "cảm" → ơn, "xin" → lỗi/chào) chỉ cần MỘT từ
    /// ngữ cảnh: seed là dữ liệu chọn tay, không phải đoán bigram thống kê ("Tên ␣" vẫn không gì
    /// — "tên" không có seed). Ngữ cảnh tiếng Anh: chỉ giữ từ tiếng Anh (như iOS chế độ tiếng Anh).
    static func wantsSeedNext(_ r: Request) -> Bool { r.typed.isEmpty && r.prev != nil }

    /// Hoàn thành tiếng Anh khi: ngữ cảnh tiếng Anh, hoặc không âm tiết Việt nào khớp.
    static func wantsEnglish(_ r: Request, vietnameseHits: Int) -> Bool {
        r.english || vietnameseHits == 0
    }

    // Tiếng Anh giữa câu Việt (Phil 16/10/2026): phím thô là tiền tố tiếng Anh rõ ràng hơn mọi
    // cách đọc tiếng Việt ("ther" hiện "thẻ" → there? KHÔNG: "thẻ"/"thể" là âm tiết trọn vẹn).
    // Dò trên câu heldout (WordPredictionTests.testEnglishOverrideNeverFiresOnVietnamese): mọi
    // tiền tố ≥ 4 phím của âm tiết Việt gõ Telex + gõ không dấu — 0 lần bật nhầm.
    /// Phím thô tối thiểu (3 phím: "toi", "cam", "duoc"… quá nhập nhằng).
    static let englishMinRaw = 4
    /// Tần suất enlexicon tối thiểu của từ tiếng Anh đứng đầu (thang 0–255 chung với vnlexicon).
    static let englishMinFreq = 150
    /// Từ tiếng Anh phải hơn âm tiết Việt khớp phổ biến nhất bấy nhiêu.
    static let englishMargin = 80
    /// Chữ trên màn hình (bỏ qua dấu chưa gõ) đã là âm tiết Việt có tần suất ≥ chừng này ⇒ là
    /// tiếng Việt đang gõ ("thin" ~ thìn/thịn, "chan" ~ chán) — không bao giờ đổi sang tiếng Anh.
    static let englishMaxExact = 60

    /// Có gợi ý tiếng Anh dù ngữ cảnh Việt và vẫn có âm tiết Việt khớp không. `raw` = phím thô,
    /// `typed` = chữ trên màn hình, `pool` = VNSuggest.matches(typed) (đã bỏ chính typed),
    /// `typedFreq` = tần suất của chính typed nếu là âm tiết, `englishTop` = tần suất từ tiếng
    /// Anh hoàn thành đầu tiên của `raw` (nil = không có).
    static func prefersEnglish(raw: String, typed: String, pool: [(word: String, freq: Int)],
                               typedFreq: Int?, englishTop: Int?) -> Bool {
        guard raw.count >= englishMinRaw, raw.unicodeScalars.allSatisfy({ ($0.value | 0x20) >= 97 && ($0.value | 0x20) <= 122 }),
              let en = englishTop, en >= englishMinFreq else { return false }
        let n = typed.count
        var exact = typedFreq ?? -1, best = typedFreq ?? -1
        for m in pool {
            best = max(best, m.freq)
            if m.word.count == n { exact = max(exact, m.freq) }
        }
        return exact < englishMaxExact && en - best >= englishMargin
    }

    static func completions(_ ranked: [String], typed: String) -> [String] {
        let n = typed.count
        var seen = Set<String>(), out: [String] = []
        for w in ranked where w.count > n {
            if seen.insert(w.lowercased()).inserted { out.append(w) }
            if out.count >= rankDepth { break }
        }
        return out
    }

    static func muted(typed: String, declined: String?) -> Bool {
        guard let d = declined, !d.isEmpty, !typed.isEmpty else { return false }
        return typed.lowercased().hasPrefix(d.lowercased())
    }

    /// Dòng trả lời giao thức --serve: thay đúng từ đang gõ (`typed`, "" = chỉ chèn) bằng ứng viên
    /// HẠNG 1 + dấu cách — một gợi ý duy nhất.
    static func answer(_ words: [String], typed: String) -> String {
        guard let first = words.first, !first.isEmpty else { return "-" }
        return ["predict", first, typed, first + " "].map(HintProtocol.escape).joined(separator: "\t")
    }
}

/// = WordPrediction.swift PredictionModel (xếp hạng thanh gợi ý iOS: SuggestRank inline / nextFill,
/// đếm seed unigram, DisplayCase, lọc nhạy cảm). Chỉ dùng trên thread của --serve.
final class PredictionModel {
    static let shared = PredictionModel()

    private var seedStorage: [String: Int]?
    private var seed: [String: Int] {
        if let s = seedStorage { return s }
        let s = SeedData.unigrams
        seedStorage = s
        return s
    }

    /// Từ kế tiếp seed (SeedNextData — bảng sinh từ UserLangModel iOS chỉ có seed), nạp lười.
    private var seedNextStorage: [String: [String]]?
    private var seedNextTable: [String: [String]] {
        if let s = seedNextStorage { return s }
        let s = SeedNextData.table()
        seedNextStorage = s
        return s
    }

    var isLoaded: Bool { seedStorage != nil || seedNextStorage != nil }

    /// Cài đặt hệ thống tắt ⇒ bỏ bảng seed (lexicon/LM là mmap — trang sạch, hệ thống tự thu).
    func unload() { seedStorage = nil; seedNextStorage = nil }

    private func count(_ w: String) -> Int { seed[w] ?? seed[w.lowercased()] ?? 0 }

    /// = UserLangModel.nextWords(after: prev, limit: 24) của người dùng iOS mới (chưa lọc).
    func seedNext(_ prev: String) -> [String] { seedNextTable[prev.lowercased()] ?? [] }

    /// Ứng viên (đã chỉnh hoa/thường) cho lượt `r`; `raw` = phím thô của từ đang gõ;
    /// `filterSensitive` = "Lọc từ nhạy cảm" ([general] filter_sensitive — như công tắc iOS, mặc
    /// định BẬT: SensitiveWords.filter ở đúng các chỗ thanh gợi ý iOS lọc).
    /// `learned` = "Học từ bạn gõ" (LearnedModel.swift; nil = tắt / chưa nạp ⇒ đúng kết quả
    /// seed như trước). Cùng hợp đồng iOS: count = seed + đếm học, ngữ cảnh +4 = nextWords
    /// cá nhân, từ kế tiếp = SuggestRank.nextFill(personal:triCount:) không lùi bigram tĩnh.
    func candidates(_ r: PredictionLogic.Request, raw: String, filterSensitive filterOn: Bool = true,
                    learned: LearnedModel? = nil) -> [String] {
        if r.typed.isEmpty {
            // = SuggestRank.nextFill với người dùng iOS mới (`personal` = nextWords seed ≤ 6, đã
            // lọc): có dòng trigram (prev2, prev) ⇒ trigram tĩnh trước rồi seed; không ⇒ chỉ seed
            // — KHÔNG lùi bigram tĩnh ("Tên ␣" → không gì). Hạng 1 vì thế đúng hạng 1 của iOS.
            guard PredictionLogic.wantsSeedNext(r), let prev = r.prev else { return [] }
            // personal = nextWords cá nhân (dữ liệu học ⊕ seed, ≤ 6) — cặp học chỉ vào khi đã gõ
            // ≥ LearnedModel.learnedPairMin lần (luật không đoán bigram sau một từ).
            let seeds = seedNext(prev)
            let mine = learned.map { $0.nextWords(after: prev, prev2: r.prev2, seeds: seeds, limit: 6) }
                ?? Array(seeds.prefix(6))
            var personal = SensitiveWords.filter(mine, enabled: filterOn)
            if r.english { personal = personal.filter { SwipeEnglish.contains($0) } }
            var tri: [String] = [], lead: [String] = []
            if PredictionLogic.wantsNextWord(r), let prev2 = r.prev2, VNSuggest.lexiconId(of: prev) != nil,
               let top = SuggestRank.topNext(prev, prev2: prev2, limit: 6), top.trigram {
                tri = SensitiveWords.filter(top.words, enabled: filterOn)
                // iOS nextFill: có dòng trigram tĩnh ⇒ bộ ba người dùng đã gõ ≥ learnedTriMin lần
                // dẫn đầu (≤ 2), rồi trigram tĩnh, rồi personal.
                if let l = learned {
                    lead = Array(personal.filter { l.trigramCount(prev2, prev, $0) >= SuggestRank.learnedTriMin }.prefix(2))
                }
            }
            let next = SuggestionFill.pad(lead, with: tri + personal, need: PredictionLogic.rankDepth)
            return next.map { DisplayCase.apply($0, after: prev) }
        }
        let typed = r.typed
        let pool = r.english ? [] : VNSuggest.matches(typed, poolLimit: 24, excluding: typed.lowercased())
        var english = PredictionLogic.wantsEnglish(r, vietnameseHits: pool.count)
        if !english, !raw.isEmpty {
            english = PredictionLogic.prefersEnglish(
                raw: raw, typed: typed, pool: pool.map { ($0.word, $0.freq) },
                typedFreq: VNSuggest.frequency(of: typed),
                englishTop: SwipeEnglish.completions(raw, limit: 1).first?.freq)
        }
        if !english {
            let pmi = SuggestRank.inlinePmi(pool, prev: r.prev, prev2: r.prev2)
            // ctx = nextWords seed của từ trước (iOS: Set(nextWords(after: prev, limit: 24))) ⇒
            // +4 cho ứng viên seed, LM nhân bigramDamp — cùng hợp đồng tầng 2/7.
            // Học từ bạn gõ: ngữ cảnh = nextWords cá nhân (không chặn cặp, limit 24 như iOS),
            // count = seed + đếm học (iOS: store mồi seed rồi cộng dồn).
            let ctx: Set<String> = r.prev.map { p in
                let seeds = seedNext(p)
                return Set(learned.map { $0.nextWords(after: p, prev2: r.prev2, seeds: seeds, limit: 24, pairMin: 0) } ?? seeds)
            } ?? []
            let personalCount: (String) -> Int = learned.map { l in { self.count($0) + l.count($0) } } ?? count
            let ranked = SensitiveWords.filter(
                SuggestRank.rankInline(pool, pmi: pmi, typedLen: typed.count, count: personalCount, ctx: ctx),
                enabled: filterOn)
            return PredictionLogic.completions(ranked, typed: typed).map {
                SuggestionCase.display(DisplayCase.apply($0, after: r.prev), shift: .off, typed: typed)
            }
        }
        // Tiếng Anh: phím thô (a–z) — "this" có thể đang hiện "thí" sau Telex.
        let key = raw.isEmpty ? typed : raw
        let src = key.count >= PredictionLogic.minTyped ? key : typed
        let en = SensitiveWords.filter(SwipeEnglish.completions(src, limit: 24).map(\.word), enabled: filterOn)
        return PredictionLogic.completions(en, typed: typed.count >= src.count ? typed : src)
    }
}

/// Lệnh "predict" của --serve: `predict <before> <typed> <raw> <english 0|1> [<filter 0|1>] [<learn 0|1>]`.
/// `learned` = "Học từ bạn gõ" (LearnStore); tắt ⇒ không nạp (đang nạp thì lưu nốt + bỏ khỏi RAM).
func predictAnswer(before: String, typed: String, raw: String, english: Bool, filterSensitive: Bool = true,
                   learned: Bool = false) -> String {
    if !learned, LearnStore.shared.isLoaded { LearnStore.shared.unload() }
    guard VTDataFile.url("vnlexicon.bin") != nil,
          let r = PredictionLogic.request(before: before, typed: typed, english: english) else { return "-" }
    let m = learned ? LearnStore.shared.current() : nil
    return PredictionLogic.answer(PredictionModel.shared.candidates(r, raw: raw, filterSensitive: filterSensitive,
                                                                    learned: m),
                                  typed: r.typed)
}
