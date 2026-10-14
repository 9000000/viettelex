// SwipeEnglish.swift — GÕ VUỐT giai đoạn 3: vuốt ra TỪ TIẾNG ANH xen trong câu tiếng
// Việt (code-switching). Phần THUẦN, bản Kotlin song sinh:
// android/keyboard/src/main/kotlin/com/viettelex/keyboard/SwipeEnglish.kt — sửa ở đây
// thì sửa y hệt bên kia (parity top-1 qua fixture chung).
//
//   • `SwipeEnglish.lexicon`: ~20k từ tiếng Anh + tần suất 1 byte CÙNG THANG với
//     vnlexicon (Resources/enlexicon.bin, sinh bởi Scripts/gen-enlexicon.py; nguồn +
//     giấy phép: docs/DATA-SOURCES.md). Nạp lười ở lần decode tiếng Anh đầu tiên.
//     Không giữ template: decoder dựng template NGAY LÚC CHẤM cho các từ lọt bộ lọc
//     phím đầu/cuối (xếp sẵn theo cặp phím đầu–cuối) — vài trăm từ mỗi cú vuốt thay
//     vì 20k × 192 B = 3,8 MB template thường trực.
//   • `SwipeLangContext`: P(ngôn ngữ | ≤ 3 từ trước) → độ lệch điểm cho ứng viên tiếng
//     Anh + biên độ phải thắng. MẶC ĐỊNH NGHIÊNG TIẾNG VIỆT: 182+ từ tiếng Anh trùng hẳn
//     chuỗi với âm tiết Việt (the/thế, to/tô, can/cần…) — nét vuốt y hệt, phân xử sai
//     tệ hơn gõ chạm, nên chỉ chọn tiếng Anh top-1 khi hình học thắng rõ hoặc đang
//     trong mạch tiếng Anh; phương án ngôn ngữ kia luôn nằm trên thanh gợi ý.
import Foundation
import TelexCore

enum SwipeLang: UInt8, Equatable { case vi, en }

enum SwipeEnglish {
    struct Lexicon {
        /// Từ chữ thường a–z, sort tăng dần (binary search).
        let words: [String]
        /// Tần suất 0-255, thang của vnlexicon.
        let freq: [UInt8]
        /// Phím đã gộp chữ lặp (hello → helo), từ i: keys[keyStart[i] ..< keyStart[i+1]].
        let keys: [UInt8]
        let keyStart: [Int32]
        /// Chỉ số từ xếp theo cặp (phím đầu, phím cuối) b = đầu·26 + cuối, trong mỗi
        /// cặp giữ thứ tự chữ cái: order[bucketStart[b] ..< bucketStart[b+1]].
        let order: [Int32]
        let bucketStart: [Int32]
        var count: Int { words.count }

        static let empty = Lexicon(words: [], freq: [], keys: [], keyStart: [0], order: [],
                                   bucketStart: [Int32](repeating: 0, count: 677))
    }

    static let lexicon: Lexicon = {
        #if VIETTELEX_CLI   // công cụ văn bản Linux (linux/engine-capi: viettelex-text-tool)
        let url = VTDataFile.url("enlexicon.bin")
        #else
        final class BundleToken {}
        let url = VTBundleResource.url("enlexicon", "bin", anchor: BundleToken.self)
        #endif
        guard let url, let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return .empty }
        return parse(d) ?? .empty
    }()

    /// Giải mã enlexicon.bin ("VTE1" | count u32 | [len][freq][ASCII]…). nil = hỏng.
    static func parse(_ d: Data) -> Lexicon? {
        let b = [UInt8](d)
        guard b.count >= 8, b[0] == 0x56, b[1] == 0x54, b[2] == 0x45, b[3] == 0x31 else { return nil }
        let n = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        var words: [String] = [], freq: [UInt8] = [], keys: [UInt8] = [], keyStart: [Int32] = [0]
        words.reserveCapacity(n); freq.reserveCapacity(n); keyStart.reserveCapacity(n + 1)
        var first = [Int](repeating: 0, count: n), last = first
        var p = 8
        for i in 0..<n {
            guard p + 2 <= b.count else { return nil }
            let len = Int(b[p]), f = b[p + 1]
            guard len > 0, p + 2 + len <= b.count else { return nil }
            var prev: UInt8 = 255
            for j in 0..<len {
                let k = b[p + 2 + j] &- 97
                guard k < 26 else { return nil }
                if k != prev { keys.append(k); prev = k }
            }
            first[i] = Int(keys[Int(keyStart[i])]); last[i] = Int(keys[keys.count - 1])
            keyStart.append(Int32(keys.count))
            words.append(String(decoding: b[(p + 2)..<(p + 2 + len)], as: UTF8.self))
            freq.append(f)
            p += 2 + len
        }
        // counting sort ổn định theo cặp phím đầu–cuối
        var bucketStart = [Int32](repeating: 0, count: 677)
        for i in 0..<n { bucketStart[first[i] * 26 + last[i] + 1] += 1 }
        for bk in 0..<676 { bucketStart[bk + 1] += bucketStart[bk] }
        var fill = Array(bucketStart[0..<676])
        var order = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let bk = first[i] * 26 + last[i]
            order[Int(fill[bk])] = Int32(i); fill[bk] += 1
        }
        return Lexicon(words: words, freq: freq, keys: keys, keyStart: keyStart,
                       order: order, bucketStart: bucketStart)
    }

    static func index(of word: String) -> Int? {
        let a = lexicon.words
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < word { lo = mid + 1 } else { hi = mid }
        }
        return lo < a.count && a[lo] == word ? lo : nil
    }

    static func contains(_ word: String) -> Bool { index(of: word) != nil }

    /// Chế độ Tiếng Anh (vuốt phím cách): từ bắt đầu bằng `typed` (a–z, không phân biệt
    /// hoa thường), tần suất giảm dần, tối đa `limit`, bỏ chính từ đang gõ. Chữ hoa theo
    /// chữ đang gõ ("Hel" → "Hello", "HEL" → "HELLO"). Chữ ngoài a–z ⇒ [].
    static func completions(_ typed: String, limit: Int = 24, in lex: Lexicon = lexicon) -> [VNSuggest.Match] {
        let low = typed.lowercased()
        guard !low.isEmpty, limit > 0,
              low.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) else { return [] }
        let a = lex.words
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < low { lo = mid + 1 } else { hi = mid }
        }
        var hits: [(f: UInt8, i: Int)] = []
        var i = lo
        while i < a.count, a[i].hasPrefix(low) {
            if a[i] != low { hits.append((lex.freq[i], i)) }
            i += 1
        }
        hits.sort { $0.f != $1.f ? $0.f > $1.f : $0.i < $1.i }
        return hits.prefix(limit).map { VNSuggest.Match(word: matchCase(a[$0.i], typed), freq: Int($0.f)) }
    }

    /// Từ phổ biến nhất (đệm thanh gợi ý ở chế độ Tiếng Anh khi chưa gõ gì).
    static func topWords(limit: Int, in lex: Lexicon = lexicon) -> [String] {
        guard limit > 0 else { return [] }
        return lex.freq.indices.sorted { lex.freq[$0] != lex.freq[$1] ? lex.freq[$0] > lex.freq[$1] : $0 < $1 }
            .prefix(limit).map { lex.words[$0] }
    }
    static let top: [String] = topWords(limit: 12)

    static func matchCase(_ w: String, _ typed: String) -> String {
        guard let f = typed.first, f.isUppercase else { return w }
        if typed.count > 1, typed.allSatisfy({ $0.isUppercase }) { return w.uppercased() }
        return w.prefix(1).uppercased() + w.dropFirst()
    }
}

/// Tham số tiếng Anh cho một lần decode (xem SwipeLangContext.prior).
struct SwipeEnglishPrior: Equatable {
    /// Cộng vào điểm mọi ứng viên tiếng Anh (log-domain; âm = nghiêng Việt).
    var bias: Float
    /// Tiếng Anh chỉ giữ top-1 khi hơn ứng viên Việt tốt nhất ≥ margin; không thì
    /// ứng viên Việt đó lên đầu (tiếng Anh vẫn nằm trong danh sách → thanh gợi ý).
    var margin: Float
}

/// Ngữ cảnh ngôn ngữ từ ≤ 3 từ trước con trỏ.
enum SwipeLangContext {
    enum Kind: Equatable { case vi, en, neutral }

    // Hằng số — GIỮ Y HỆT bản Kotlin. Chọn bằng quét (SwipeEnglishTests.kt sweepPriors,
    // đường vuốt giả σ0.25): ngưỡng hiệu dụng bias−margin ≈ −1.2 là mức nhỏ nhất đưa MỌI
    // cặp trùng chuỗi trong top-1000 Anh (58 cặp: the/thế, can/cần…) về tiếng Việt khi
    // ngữ cảnh Việt, mà top-1 Việt không đổi (0.900) và từ Anh riêng hình vẫn thắng.
    // Mạch Anh: bias 0.2 cân hai ngôn ngữ (từ Việt sau một từ Anh vẫn hay gặp: "app chưa").
    static let defaultPrior = SwipeEnglishPrior(bias: -0.9, margin: 0.3)
    static let englishPrior = SwipeEnglishPrior(bias: 0.2, margin: 0)
    /// Chế độ Tiếng Anh: đẩy hẳn tiếng Anh lên (ứng viên Việt bị lọc bỏ sau decode).
    static let onlyEnglishPrior = SwipeEnglishPrior(bias: 4, margin: 0)

    /// Phân loại một từ đã có trên màn hình. `swipedEnglish` = từ đó vừa được vuốt ra
    /// như từ tiếng Anh (nhãn decoder) — chắc chắn nhất.
    static func classify(_ word: String?, swipedEnglish: Bool = false) -> Kind {
        guard let raw = word, !raw.isEmpty else { return .neutral }
        if swipedEnglish { return .en }
        let w = raw.lowercased()
        guard w.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) else {
            // có dấu / đ ⇒ tiếng Việt; số, ký hiệu ⇒ không rõ
            return w.unicodeScalars.contains { $0.value > 127 } ? .vi : .neutral
        }
        // cùng bảng với engine.contextualEnglish: từ mượn giữ nguyên mạch, từ tiếng Anh
        // của bảng ngữ cảnh tính là .en. Đây là tiền nghiệm MỀM cho decoder (một từ Anh
        // chỉ cân hai ngôn ngữ, bias 0.2) — khác engine (từ 11/10/2026 chỉ MỞ mạch khôi
        // phục bằng từ chức năng hoặc hai từ Anh liền nhau), nên giữ nguyên ở đây.
        if EnglishContextLookup.isNeutralLoanword(w) { return .neutral }
        if EnglishContextLookup.opensEnglishRun(w) { return .en }
        let vnForm = SwipeLexicon.index(of: w) != nil
        if SwipeEnglish.contains(w) { return vnForm ? .neutral : .en }
        return vnForm ? .vi : .neutral
    }

    /// Độ lệch theo 2 từ trước (prev1 = liền trước) — = `prior(kinds)`.
    static func prior(prev1: Kind, prev2: Kind) -> SwipeEnglishPrior { prior([prev1, prev2]) }

    /// Tiền nghiệm LIÊN TỤC NGÔN NGỮ (28/09/2026): đang gõ tiếng Anh thì từ kế hay là tiếng
    /// Anh, đang gõ tiếng Việt thì tiếng Việt. GIỮ Y HỆT bản Kotlin (SwipeLangContext.Continuity).
    /// Chỉnh trên dev (SwipeLangTuneTests.kt, vuốt tuần tự câu Việt / Anh / trộn): mạch Việt
    /// KHÔNG cần thêm gì — DEFAULT đã nghiêng Việt; nới thêm (viBias/viMargin > 0) chỉ +0,1 điểm
    /// câu Việt mà −1,5…−3 điểm từ Anh chen sau từ Việt ⇒ để 0.
    struct Continuity: Equatable {
        /// Trọng số từ lùi i vị trí = decay^i (từ trung tính vẫn tính khoảng cách).
        var decay: Float = 0.6
        /// Mạch Anh s ≥ 1 (một từ Anh liền trước): bias = enBias + enGain·(min(s, enCap) − 1),
        /// margin 0; 0 < s < 1: nội suy tuyến tính từ DEFAULT.
        var enBias: Float = 0.2
        var enGain: Float = 0.5
        var enCap: Float = 2
        /// Mạch Việt: bias −= viBias·v, margin += viMargin·v, v = min(s Việt, viCap).
        var viBias: Float = 0
        var viMargin: Float = 0
        var viCap: Float = 2
    }

    static let continuity = Continuity()
    /// Số từ trước con trỏ được xét.
    static let window = 3

    /// `kinds` = ngôn ngữ ≤ 3 từ trước con trỏ, gần nhất trước. Mạch Anh s = Σ decay^i trên các
    /// từ Anh, đi từ gần ra xa, DỪNG ở từ Việt đầu tiên (một từ Việt cắt mạch Anh — "check mail
    /// cho" → mạch Việt); mạch Việt đối xứng (dừng ở từ Anh). Không có từ nào rõ ngôn ngữ ⇒
    /// đúng `defaultPrior` (từ rời không đổi). Có trần — hình học + LM mạnh vẫn thắng, từ Anh
    /// chen giữa câu Việt vẫn ra.
    static func prior(_ kinds: [Kind], _ c: Continuity = continuity) -> SwipeEnglishPrior {
        let en = run(kinds, .en, stop: .vi, c.decay)
        if en >= 1 { return SwipeEnglishPrior(bias: c.enBias + c.enGain * (min(en, c.enCap) - 1), margin: 0) }
        if en > 0 {
            return SwipeEnglishPrior(bias: defaultPrior.bias + (c.enBias - defaultPrior.bias) * en,
                                     margin: defaultPrior.margin * (1 - en))
        }
        let vi = min(run(kinds, .vi, stop: .en, c.decay), c.viCap)
        if vi <= 0 { return defaultPrior }
        return SwipeEnglishPrior(bias: defaultPrior.bias - c.viBias * vi, margin: defaultPrior.margin + c.viMargin * vi)
    }

    private static func run(_ kinds: [Kind], _ same: Kind, stop: Kind, _ decay: Float) -> Float {
        var s: Float = 0, w: Float = 1
        for k in kinds.prefix(3) {
            if k == stop { break }
            if k == same { s += w }
            w *= decay
        }
        return s
    }

    /// Ngôn ngữ ≤ `window` từ trước con trỏ, gần nhất trước: `composing` ⇒ từ đang soạn
    /// `pending` (sẽ chốt trước từ vuốt; nil = không học được ⇒ trung tính) đứng đầu; `recent` =
    /// từ đã chốt, CŨ → MỚI; `english(w)` = w vừa được vuốt ra như tiếng Anh.
    static func kinds(composing: Bool, pending: String?, pendingEnglish: Bool, recent: [String],
                      english: (String?) -> Bool) -> [Kind] {
        var out: [Kind] = []
        out.reserveCapacity(window)
        if composing { out.append(classify(pending, swipedEnglish: pendingEnglish)) }
        for w in recent.reversed() where out.count < window {
            out.append(classify(w, swipedEnglish: english(w)))
        }
        return out
    }
}
