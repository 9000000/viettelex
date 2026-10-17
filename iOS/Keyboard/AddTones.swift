// AddTones.swift — THÊM DẤU CHO CÂU KHÔNG DẤU ("toi di hoc hom nay" → "tôi đi học hôm nay"),
// phần THUẦN. Song sinh android/keyboard/src/main/kotlin/com/viettelex/keyboard/AddTones.kt —
// sửa ở đây thì sửa y hệt bên kia (parity qua fixture chung KeyboardTests/Fixtures/add-tones.txt).
//
// Chỉ chạy khi người dùng BẤM chip "Thêm dấu" — không bao giờ tự thay chữ.
//
// Giải thuật: Viterbi trên lưới âm tiết. Mỗi token chữ ASCII là một dạng không dấu của
// vnlexicon (SwipeLexicon) → ứng viên = mọi âm tiết có dấu của dạng đó. Điểm (log, nat):
//   phát xạ = freqW·freq/255 (freq byte = 255·ln(count)/ln(max) ≈ log unigram)
//             + personalUni·ln(1+count cá nhân)
//   chuyển  = bigramW·max(floor, PMI(âm tiết trước → này)) + personalBi·ln(1+count cặp cá nhân);
//             PMI = bigram Kneser-Ney của vnlm.bin (SyllableLM.bigram — có điểm ÂM, thiếu mục ⇒
//             lùi γ2); âm tiết trước không có dòng bigram nào ⇒ 0.
//   TRIGRAM (18/10/2026, `viterbi3`, chuỗi ≥ 3 âm tiết): Viterbi bậc 2, trạng thái = (ứng viên
//             i−1, ứng viên i); có mục trigram TƯỜNG MINH (q, r, s) trong vnlm.bin thì PMI của
//             chuyển r → s = s3 + uniAdj (SyllableLM.forEachTrigram) thay cho PMI bigram, thiếu thì giữ
//             bigram (không cộng phạt lùi γ3 — đo trên tập dev: kém hơn). Heldout: âm tiết
//             0.9550 → 0.9645, câu đúng hết 0.767 → 0.811.
//   CẶP CHỌN TAY (18/10/2026, CuratedPairs — Scripts/curated-pairs.txt): chuyển (r → s) hoặc
//             (q, r → s) có trong bảng ⇒ số hạng cặp = max(cá nhân, curatedW) — mọi nền tảng (máy
//             tính không có mô hình cá nhân cũng nhận). NGƯỜI DÙNG THẮNG: ở vị trí mà người dùng đã
//             gõ một cặp KHÔNG trong bảng ≥ curatedYield lần (count cặp cá nhân, gồm seed), bảng tắt
//             cho vị trí đó ⇒ thói quen riêng (vd. hay gõ "có đâu") đè được cặp chọn tay.
// Chuỗi bị cắt ở dấu câu / token giữ nguyên. GIỮ NGUYÊN: token không phải dạng Việt (tiếng
// Anh, tên riêng lạ, số, URL, email, chữ lẫn số/ký hiệu, camelCase), token có dấu. Token vừa
// là dạng Việt vừa là từ Anh (the, can…) giữ nguyên khi kề một từ chắc chắn Anh. Giữ
// hoa/thường từng chữ, dấu câu, khoảng trắng: kết quả DÀI BẰNG bản gốc (tính theo Unicode
// scalar — mỗi chữ ASCII ↔ một chữ Việt dựng sẵn NFC).
import Foundation
import TelexCore

enum AddTones {
    /// Trọng số — GIỮ Y HỆT bản Kotlin. Chọn bằng lưới trên heldout (android
    /// AddTonesTests.tuneGrid / tunePersonal, 27/09/2026); 28/09/2026 (bigram vnlm.bin thay
    /// vnbigram.bin) lưới lại trên tập dev: giữ freqW/bigramW, sàn PMI −2.5 (thay "thiếu cặp = −0.5").
    struct Params {
        var freqW = 10.0
        var bigramW = 1.0
        var floor = -2.5
        var personalUni = 0.1
        var personalBi = 1.0
        /// Viterbi bậc 2 dùng trigram tường minh; false = chỉ bigram (mốc đo heldout).
        var trigram = true
        /// Cộng cặp chọn tay (CuratedPairs); false = mốc đo.
        var curated = true
        /// Số hạng cặp tối thiểu của chuyển có trong CuratedPairs (nat). Chọn 18/10/2026: 6 chưa lật
        /// được nửa số cặp lóng, 8 ≈ 10; heldout giữ nguyên 0.9645 / câu 0.811.
        var curatedW = 8.0
        /// Người dùng gõ một cặp khác (không trong bảng) ≥ chừng này lần ở cùng vị trí ⇒ bảng tắt.
        var curatedYield = 3
    }

    /// Trần count cá nhân.
    static let personalCap = 50
    /// Giới hạn độ dài xử lý (token chữ trong đoạn).
    static let maxSyllables = 200

    /// Dữ liệu cá nhân (UserLangModel) — nil ⇒ chỉ dữ liệu tĩnh.
    struct Personal {
        let count: (String) -> Int
        let pair: (String, String) -> Int
    }

    /// Số hạng cặp (a → b): cá nhân personalBi·ln(1 + min(count, trần)); `on` và (x, a → b) có
    /// trong CuratedPairs (`x` = âm tiết trước a, nil = không xét bộ ba) ⇒ max(…, curatedW).
    private static func pairTerm(_ personal: Personal?, _ p: Params, _ on: Bool, _ x: String?,
                                 _ a: String, _ b: String) -> Double {
        var t = 0.0
        if let personal {
            let c = min(personal.pair(a, b), personalCap)
            if c > 0 { t = p.personalBi * log(1.0 + Double(c)) }
        }
        if on && CuratedPairs.has(x, a, b) { t = max(t, p.curatedW) }
        return t
    }

    /// Bảng chọn tay có áp ở chuyển giữa hai cột ứng viên `a` → `b` không: tắt khi người dùng đã
    /// gõ một cặp (a[r], b[s]) KHÔNG trong bảng ≥ curatedYield lần.
    private static func curatedOn(_ personal: Personal?, _ p: Params, _ a: [String], _ b: [String]) -> Bool {
        guard p.curated else { return false }
        guard let personal else { return true }
        for x in a {
            for y in b where personal.pair(x, y) >= p.curatedYield && !CuratedPairs.anyContext(x, y) { return false }
        }
        return true
    }

    struct Result {
        let text: String
        let vnTokens: Int
        let enTokens: Int
        let changed: Int
    }

    /// Kế hoạch thay: xoá `original` (đuôi văn bản trước con trỏ) rồi chèn `replacement`.
    /// Hoàn tác = làm ngược lại.
    struct Plan: Equatable {
        let original: String
        let replacement: String
    }

    private static let punct: Set<Unicode.Scalar> = Set(".,;:!?\"'()[]{}…“”‘’-–—«»".unicodeScalars)
    private static func isWs(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{00A0}"
    }
    private static func isNl(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }
    private static func isAsciiLetter(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 97 && c.value <= 122) || (c.value >= 65 && c.value <= 90)
    }
    private static func isUpperAscii(_ c: Unicode.Scalar) -> Bool { c.value >= 65 && c.value <= 90 }
    /// = Java Character.isLetter (Lu Ll Lt Lm Lo).
    private static func isLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Đoạn cuối văn bản trước con trỏ để thêm dấu: các chunk (cách nhau khoảng trắng) liên
    /// tiếp tính từ cuối, dừng ở xuống dòng, ở chunk có chữ có dấu / ngoài ASCII, hoặc khi đủ
    /// `maxSyllables` token chữ. "" nếu không có gì.
    static func segment(_ before: String) -> String {
        let s = Array(before.unicodeScalars)
        var end = s.count, start = end, tokens = 0
        func out(_ from: Int) -> String {
            var a = from
            while a < s.count && isWs(s[a]) { a += 1 }
            var u = String.UnicodeScalarView(); u.append(contentsOf: s[a...])
            return String(u)
        }
        while end > 0 {
            var ws = end
            while ws > 0 && isWs(s[ws - 1]) {
                if isNl(s[ws - 1]) { return out(start) }
                ws -= 1
            }
            if ws == 0 { break }
            var cs = ws
            while cs > 0 && !isWs(s[cs - 1]) { cs -= 1 }
            let chunk = s[cs..<ws]
            if chunk.contains(where: { $0.value > 127 && isLetter($0) }) { break }
            if chunk.contains(where: isAsciiLetter) { tokens += 1 }
            if tokens > maxSyllables { break }
            start = cs
            end = cs
        }
        return out(start)
    }

    private final class Tok {
        let start: Int, end: Int
        let word: String
        let breakBefore: Bool, breakAfter: Bool
        var form = -1
        var english = false, ambiguous = false, keep = false
        init(_ start: Int, _ end: Int, _ word: String, _ bb: Bool, _ ba: Bool) {
            self.start = start; self.end = end; self.word = word; breakBefore = bb; breakAfter = ba
        }
    }

    /// Token chữ ứng viên (nil = chunk giữ nguyên, cắt chuỗi bigram).
    private static func tokenize(_ s: [Unicode.Scalar]) -> [Tok?] {
        var out: [Tok?] = []
        var i = 0
        let n = s.count
        while i < n {
            if isWs(s[i]) { i += 1; continue }
            var j = i
            while j < n && !isWs(s[j]) { j += 1 }
            var a = i, b = j
            while a < b && !isAsciiLetter(s[a]) { a += 1 }
            while b > a && !isAsciiLetter(s[b - 1]) { b -= 1 }
            let ok = a < b && s[i..<a].allSatisfy { punct.contains($0) }
                && s[b..<j].allSatisfy { punct.contains($0) } && s[a..<b].allSatisfy(isAsciiLetter)
            if !ok { out.append(nil); i = j; continue }
            let core = s[a..<b]
            let upperInside = core.dropFirst().contains(where: isUpperAscii)
            let allUpper = core.allSatisfy(isUpperAscii)
            if upperInside && !allUpper { out.append(nil); i = j; continue }
            var u = String.UnicodeScalarView(); u.append(contentsOf: core)
            out.append(Tok(a, b, String(u).lowercased(), a > i, b < j))
            i = j
        }
        return out
    }

    private static func classify(_ toks: [Tok?]) {
        for case let t? in toks {
            t.form = SwipeLexicon.index(of: t.word) ?? -1
            let en = SwipeEnglish.contains(t.word) || EnglishContextLookup.opensEnglishRun(t.word)
            if t.form < 0 {
                t.keep = true
                t.english = en && !EnglishContextLookup.isNeutralLoanword(t.word)
            } else if en { t.ambiguous = true }
        }
        var changed = true
        while changed {
            changed = false
            for k in toks.indices {
                guard let t = toks[k], t.ambiguous, !t.keep else { continue }
                let p = k > 0 && !t.breakBefore ? toks[k - 1].flatMap { $0.breakAfter ? nil : $0 } : nil
                let q = k + 1 < toks.count && !t.breakAfter ? toks[k + 1].flatMap { $0.breakBefore ? nil : $0 } : nil
                if p?.english == true || q?.english == true {
                    t.keep = true; t.english = true; changed = true
                }
            }
        }
    }

    /// Khôi phục dấu cho `text` (một đoạn — thường là `segment`). Độ dài (scalar) giữ nguyên.
    static func restore(_ text: String, personal: Personal? = nil, _ p: Params = Params(),
                        lm: SyllableLM? = SyllableLM.shared) -> Result {
        let s = Array(text.unicodeScalars)
        let toks = tokenize(s)
        classify(toks)
        let forms = SwipeLexicon.forms
        var chosen = [String?](repeating: nil, count: toks.count)
        var vn = 0, en = 0
        var k = 0
        while k < toks.count {
            guard let t = toks[k], !t.keep else {
                if toks[k]?.english == true { en += 1 }
                k += 1; continue
            }
            _ = t
            var e = k + 1
            while e < toks.count {
                guard let u = toks[e], !u.keep, !u.breakBefore, !toks[e - 1]!.breakAfter else { break }
                e += 1
            }
            vn += e - k
            viterbi(toks, k, e, forms, personal, p, lm, &chosen)
            k = e
        }
        var outS = s
        var changed = 0
        for (i, t) in toks.enumerated() {
            guard let t, let w = chosen[i], w != t.word else { continue }
            changed += 1
            let ws = Array(w.unicodeScalars)
            for c in 0..<(t.end - t.start) {
                let orig = s[t.start + c]
                outS[t.start + c] = isUpperAscii(orig)
                    ? (String(ws[c]).uppercased().unicodeScalars.first ?? ws[c]) : ws[c]
            }
        }
        var u = String.UnicodeScalarView(); u.append(contentsOf: outS)
        return Result(text: String(u), vnTokens: vn, enTokens: en, changed: changed)
    }

    private static func viterbi(_ toks: [Tok?], _ from: Int, _ to: Int, _ forms: SwipeLexicon.Forms,
                                _ personal: Personal?, _ p: Params, _ lm: SyllableLM?,
                                _ chosen: inout [String?]) {
        let n = to - from
        let ids: [[Int]] = (0..<n).map { i in
            let f = toks[from + i]!.form
            return Array(Int(forms.idStart[f])..<Int(forms.idStart[f + 1]))
        }
        let words: [[String]] = ids.map { $0.map { VNSuggest.display($0) } }
        if p.trigram, let lm, n >= 3 {
            viterbi3(ids, words, from, personal, p, lm, &chosen)
            return
        }
        var score = ids.map { [Double](repeating: 0, count: $0.count) }
        var back = ids.map { [Int](repeating: 0, count: $0.count) }
        for i in 0..<n {
            let rows = i > 0 ? lm.map { m in ids[i - 1].map { m.bigram($0) } } : nil
            let on = i > 0 && curatedOn(personal, p, words[i - 1], words[i])
            for s in ids[i].indices {
                var emit = p.freqW * Double(VNSuggest.freq(id: ids[i][s])) / 255.0
                if let personal {
                    let c = min(personal.count(words[i][s]), personalCap)
                    if c > 0 { emit += p.personalUni * log(1.0 + Double(c)) }
                }
                if i == 0 { score[i][s] = emit; back[i][s] = -1; continue }
                var best = -Double.infinity, arg = 0
                for r in ids[i - 1].indices {
                    var tr = 0.0
                    if let rows {
                        let row = rows[r]
                        if row.size > 0 { tr = p.bigramW * max(p.floor, Double(row.pmi(ids[i][s]))) }
                    }
                    tr += pairTerm(personal, p, on, nil, words[i - 1][r], words[i][s])
                    let v = score[i - 1][r] + tr
                    if v > best { best = v; arg = r }
                }
                score[i][s] = best + emit
                back[i][s] = arg
            }
        }
        var s = 0
        for x in 1..<max(1, score[n - 1].count) where score[n - 1][x] > score[n - 1][s] { s = x }
        for i in stride(from: n - 1, through: 0, by: -1) {
            chosen[from + i] = words[i][s]
            s = back[i][s]
        }
    }

    /// Viterbi bậc 2 (song sinh Kotlin `viterbi3` + C++ windows/engine/src/add_tones.cpp — giữ
    /// y hệt thứ tự phép tính để ra cùng kết quả). Trạng thái (r ở i−1, s ở i):
    ///   S1[r][s] = emit0[r] + tr(·, r, s) + emit1[s]
    ///   Si[r][s] = max_q S(i−1)[q][r] + tr(q, r, s) + emit_i[s]   (hoà → q nhỏ nhất)
    /// tr(q, r, s) = bigramW·max(floor, pmi) + cá nhân(r, s): pmi = trigram tường minh (q, r, s)
    /// nếu có, không thì PMI bigram r → s như bậc 1 (0 nếu r không có dòng bigram).
    /// Chi phí: K(i−2)·K(i−1) ngữ cảnh mỗi vị trí; dòng có trigram: một lowerBound + duyệt các
    /// mục rơi vào dải id ứng viên (không tra từng ứng viên).
    private static func viterbi3(_ ids: [[Int]], _ words: [[String]], _ from: Int, _ personal: Personal?,
                                 _ p: Params, _ lm: SyllableLM, _ chosen: inout [String?]) {
        let n = ids.count
        func emit(_ i: Int, _ s: Int) -> Double {
            var e = p.freqW * Double(VNSuggest.freq(id: ids[i][s])) / 255.0
            if let personal {
                let c = min(personal.count(words[i][s]), personalCap)
                if c > 0 { e += p.personalUni * log(1.0 + Double(c)) }
            }
            return e
        }
        /// Cặp (r ở i−1, s ở i), cá nhân + chọn tay không kèm bộ ba: pers[r·kc + s].
        func pairs(_ i: Int, _ on: Bool) -> [Double] {
            let kb = ids[i - 1].count, kc = ids[i].count
            var out = [Double](repeating: 0, count: kb * kc)
            for r in 0..<kb {
                for s in 0..<kc { out[r * kc + s] = pairTerm(personal, p, on, nil, words[i - 1][r], words[i][s]) }
            }
            return out
        }
        /// Chuyển bigram (i−1 → i): bi[r·kc + s] = bigramW·max(floor, PMI), 0 nếu r không có dòng.
        func bigrams(_ i: Int) -> [Double] {
            let b = ids[i - 1], c = ids[i]
            var out = [Double](repeating: 0, count: b.count * c.count)
            for r in b.indices {
                let row = lm.bigram(b[r])
                guard row.size > 0 else { continue }
                for s in c.indices { out[r * c.count + s] = p.bigramW * max(p.floor, Double(row.pmi(c[s]))) }
            }
            return out
        }
        let k1 = ids[1].count
        var prev = [Double](repeating: 0, count: ids[0].count * k1)
        do {
            let bi = bigrams(1), pers = pairs(1, curatedOn(personal, p, words[0], words[1]))
            for r in ids[0].indices {
                let e0 = emit(0, r)
                for s in 0..<k1 {
                    var tr = bi[r * k1 + s]
                    tr += pers[r * k1 + s]
                    prev[r * k1 + s] = e0 + tr + emit(1, s)
                }
            }
        }
        var back = [[Int]](repeating: [], count: n)
        var t3 = [Double]()
        for i in 2..<n {
            let a = ids[i - 2], b = ids[i - 1], c = ids[i]
            let ka = a.count, kb = b.count, kc = c.count
            let b0 = b[0], c0 = c[0]            // ứng viên một dạng = dải id liền nhau
            let on = curatedOn(personal, p, words[i - 1], words[i])
            let bi = bigrams(i), pers = pairs(i, on)
            let em = (0..<kc).map { emit(i, $0) }
            if t3.count != kb * kc { t3 = [Double](repeating: .nan, count: kb * kc) }
            var cur = [Double](repeating: -Double.infinity, count: kb * kc)
            var bk = [Int](repeating: 0, count: kb * kc)
            // q ngoài cùng, tăng dần, so sánh ngặt ⇒ hoà giữ q nhỏ nhất (như vòng max_q)
            for q in 0..<ka {
                var tri = false
                lm.forEachTrigram(prev2: a[q], prev1: b0, b0 + kb, next: c0, c0 + kc) { rb, sc, v in
                    t3[(rb - b0) * kc + sc - c0] = p.bigramW * max(p.floor, Double(v)); tri = true
                }
                let wq = words[i - 2][q]
                for r in 0..<kb {
                    let base = prev[q * kb + r]
                    // bộ ba chọn tay (q, r → s): số hạng cặp tính lại với ngữ cảnh q
                    let tq = on && CuratedPairs.hasTriple(wq, words[i - 1][r])
                    for s in 0..<kc {
                        let x = r * kc + s
                        var tr = tri && !t3[x].isNaN ? t3[x] : bi[x]
                        tr += tq ? pairTerm(personal, p, on, wq, words[i - 1][r], words[i][s]) : pers[x]
                        let v = base + tr
                        if v > cur[x] { cur[x] = v; bk[x] = q }
                    }
                }
                if tri { for x in 0..<(kb * kc) { t3[x] = .nan } }
            }
            for r in 0..<kb { for s in 0..<kc { cur[r * kc + s] += em[s] } }
            back[i] = bk
            prev = cur
        }
        let kc = ids[n - 1].count
        var top = 0
        for x in 1..<prev.count where prev[x] > prev[top] { top = x }
        var r = top / kc, s = top % kc
        var i = n - 1
        while i >= 1 {
            chosen[from + i] = words[i][s]
            if i == 1 { break }
            let q = back[i][r * ids[i].count + s]
            s = r; r = q
            i -= 1
        }
        chosen[from] = words[0][r]
    }

    /// Kế hoạch thêm dấu cho văn bản trước con trỏ; nil nếu không nên mời (< 2 token Việt,
    /// nghiêng tiếng Anh, hoặc không đổi gì). Chỉ gồm phần đuôi từ ký tự khác đầu tiên.
    static func plan(_ before: String, personal: Personal? = nil, _ p: Params = Params()) -> Plan? {
        let seg = segment(before)
        guard !seg.isEmpty else { return nil }
        let r = restore(seg, personal: personal, p)
        guard r.vnTokens >= 2, r.enTokens < r.vnTokens, r.changed > 0 else { return nil }
        let a = Array(seg.unicodeScalars), b = Array(r.text.unicodeScalars)
        var d = 0
        while d < a.count && a[d] == b[d] { d += 1 }
        var o = String.UnicodeScalarView(), rp = String.UnicodeScalarView()
        o.append(contentsOf: a[d...]); rp.append(contentsOf: b[d...])
        return Plan(original: String(o), replacement: String(rp))
    }
}

