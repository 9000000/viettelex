// Predict.swift — GỢI Ý TỪ cho Linux (port macOS App/Sources/WordPrediction.swift, 16/10/2026):
//   a) hoàn thành từ đang gõ ("đư" → được / đường / đưa; tiếng Anh khi ngữ cảnh tiếng Anh hoặc
//      không âm tiết Việt nào khớp: "keyb" → keyboard);
//   b) từ kế tiếp ngay sau dấu cách ("cảm ␣" → ơn).
// Logic THUẦN (PredictionLogic.request / completions / wantsEnglish) + xếp hạng
// (PredictionModel.candidates) chép 1:1 từ WordPrediction.swift — file đó kéo CFPreferences /
// CaretHint (AppKit) nên không symlink được. Phần dùng chung thật là SYMLINK tới iOS/Keyboard
// (VNSuggest, SuggestionSupport = SuggestRank, SyllableLM vnlm.bin, SeedData, DisplayCase,
// SensitiveWords, SwipeEnglish) — đúng bộ file project.yml biên dịch cho macOS. Khác macOS:
//  • tiếng Anh: SwipeEnglish.completions (macOS: EnglishLite.completions trên mmap — test macOS
//    testEnglishLiteCompletionsMatchSwipeEnglish chứng minh cùng kết quả);
//  • chạy trong `viettelex-text-tool --serve` (lệnh "predict", Serve.swift): process IME chỉ lo
//    cổng rẻ + hẹn giờ 0,3 s (linux/common auto_text.h, Session), dữ liệu không vào process IME;
//  • công tắc: [general] word_prediction trong config.toml (mặc định TẮT) — Linux không có cài
//    đặt hệ thống tương đương "Show inline predictive text".
// Không học từ người dùng (như macOS).
import Foundation
import TelexCore

enum PredictionLogic {
    static let maxCandidates = 3
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

    static func wantsEnglish(_ r: Request, vietnameseHits: Int) -> Bool {
        r.english || vietnameseHits == 0
    }

    static func completions(_ ranked: [String], typed: String) -> [String] {
        let n = typed.count
        var seen = Set<String>(), out: [String] = []
        for w in ranked where w.count > n {
            if seen.insert(w.lowercased()).inserted { out.append(w) }
            if out.count >= maxCandidates { break }
        }
        return out
    }

    static func muted(typed: String, declined: String?) -> Bool {
        guard let d = declined, !d.isEmpty, !typed.isEmpty else { return false }
        return typed.lowercased().hasPrefix(d.lowercased())
    }

    /// Dòng trả lời giao thức --serve: thay đúng từ đang gõ (`typed`, "" = chỉ chèn) bằng ứng viên
    /// đầu + dấu cách; ứng viên 2–3 đi kèm (chỉ chữ hiện — bộ gõ tự thêm dấu cách).
    static func answer(_ words: [String], typed: String) -> String {
        let w = Array(words.prefix(maxCandidates))
        guard let first = w.first else { return "-" }
        return (["predict", first, typed, first + " "] + w.dropFirst()).map(HintProtocol.escape).joined(separator: "\t")
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

    private func count(_ w: String) -> Int { seed[w] ?? seed[w.lowercased()] ?? 0 }

    func candidates(_ r: PredictionLogic.Request, raw: String) -> [String] {
        let filterOn = true
        if r.typed.isEmpty {
            guard !r.english, let prev = r.prev, VNSuggest.lexiconId(of: prev) != nil else { return [] }
            let next = SuggestRank.nextFill(prev, prev2: r.prev2, personal: [], triCount: { _ in 0 },
                                            filter: { SensitiveWords.filter($0, enabled: filterOn) })
            return Array(next.prefix(PredictionLogic.maxCandidates)).map { DisplayCase.apply($0, after: prev) }
        }
        let typed = r.typed
        let pool = r.english ? [] : VNSuggest.matches(typed, poolLimit: 24, excluding: typed.lowercased())
        if !PredictionLogic.wantsEnglish(r, vietnameseHits: pool.count) {
            let pmi = SuggestRank.inlinePmi(pool, prev: r.prev, prev2: r.prev2)
            let ranked = SensitiveWords.filter(
                SuggestRank.rankInline(pool, pmi: pmi, typedLen: typed.count, count: count, ctx: []),
                enabled: filterOn)
            return PredictionLogic.completions(ranked, typed: typed).map {
                SuggestionCase.display(DisplayCase.apply($0, after: r.prev), shift: .off, typed: typed)
            }
        }
        let key = raw.isEmpty ? typed : raw
        let src = key.count >= PredictionLogic.minTyped ? key : typed
        let en = SensitiveWords.filter(SwipeEnglish.completions(src, limit: 24).map(\.word), enabled: filterOn)
        return PredictionLogic.completions(en, typed: typed.count >= src.count ? typed : src)
    }
}

/// Lệnh "predict" của --serve: `predict <before> <typed> <raw> <english 0|1>`.
func predictAnswer(before: String, typed: String, raw: String, english: Bool) -> String {
    guard VTDataFile.url("vnlexicon.bin") != nil,
          let r = PredictionLogic.request(before: before, typed: typed, english: english) else { return "-" }
    return PredictionLogic.answer(PredictionModel.shared.candidates(r, raw: raw), typed: r.typed)
}
