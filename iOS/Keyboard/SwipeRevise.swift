// SwipeRevise.swift — SỬA LẠI TỪ VUỐT TRƯỚC khi đã biết từ kế (ngữ cảnh HAI PHÍA). Song
// sinh android/keyboard/src/main/kotlin/com/viettelex/keyboard/SwipeRevise.kt — sửa hằng
// số/hành vi ở đây thì sửa y hệt bên kia.
//
// Vuốt w1 chỉ biết ngữ cảnh trái (w0). Khi cú vuốt kế ra w2, chấm lại các ứng viên c của w1
// bằng điểm cũ (hình học + tần suất + ngữ cảnh trái, `scored`) + trigram phải s(w2 | w0, c)
// (vnlm.bin) ·rightWeight kẹp [rightFloor, rightCap]; ứng viên khác thắng từ đang hiện
// ≥ margin ⇒ thay. Chỉ từ Việt, chỉ từ vuốt liền trước, một lần. Caller lo fail-safe màn
// hình (đuôi phải khớp đúng từ cũ). Từ kế cũng có thể GÕ BẰNG PHÍM (Typed/reviseTyped): chấm
// lại lúc từ gõ được chốt (dấu cách/dấu câu), ngữ cảnh phải = từ đã chốt (chắc chắn), trọng
// số/lề riêng. Từ kế là cú vuốt (chưa chắc) ⇒ sửa CHUNG cặp: ứng viên c của w1 chọn cùng
// ứng viên tốt nhất của w2 theo c (`revise` với `nextPool`, jointWeight) — "vì dù" → "ví dụ".
// Chi phí: ≤ maxCandidates·nextMaxCandidates lần tra LM, chỉ sau một cú vuốt hoặc ở ranh giới
// từ NGAY SAU từ vuốt — không ở đường phím chữ.
import Foundation

enum SwipeRevise {
    /// Chỉnh trên tập dev (SwipeReviseTests.kt sweep) — docs/DATA-SOURCES.md "Sửa lại từ vuốt trước".
    static let rightWeight: Float = 0.1
    static let rightCap: Float = 1.0
    static let rightFloor: Float = -1.0
    static let margin: Float = 0.1
    /// Từ kế GÕ BẰNG PHÍM (chắc chắn, không phải từ vuốt đoán) ⇒ tin ngữ cảnh phải hơn, lề cao
    /// hơn để giữ sửa sai thấp. Chỉnh riêng trên dev (SwipeReviseTests.kt sweepTyped).
    static let typedRightWeight: Float = 0.15
    static let typedMargin: Float = 0.3
    static let poolForms = 3
    static let poolWords = 8
    static let maxCandidates = 12
    /// Sửa CHUNG hai từ (`revise` với danh sách từ kế): ứng viên của cú vuốt kế (rộng hơn — âm
    /// tiết kém theo ngữ cảnh cũ có thể thắng theo ngữ cảnh mới: "dụ" sau "ví"), trọng số trigram
    /// = trọng số LM trái của decoder (SwipeTyping.lmWeight) — chỉnh trên dev (SwipeTuneTests.kt).
    static let nextPoolWords = 8
    static let nextMaxCandidates = 16
    static let jointWeight: Float = SwipeTyping.lmWeight

    /// Ứng viên tiếng Việt (chữ thường) của một cú vuốt + điểm tổng cùng thước decoder:
    /// điểm dạng − điểm bung tốt nhất của dạng (= phần hình học) + điểm bung của âm tiết.
    /// Rỗng khi top-1 là tiếng Anh.
    static func scored(_ cands: [SwipeCandidate], context: ((String) -> Float)?,
                       lambdaFreq: Float, poolWords: Int = poolWords,
                       maxCandidates: Int = maxCandidates) -> [SwipeWord] {
        guard let first = cands.first, first.lang == .vi else { return [] }
        var out: [(SwipeWord, Int)] = []
        for c in cands.prefix(poolForms) where c.lang == .vi {
            let ex = SwipeDecoder.expand(c.folded, limit: poolWords, lambdaFreq: lambdaFreq, context: context)
            guard let top = ex.first else { continue }
            let geom = c.score - top.score
            for w in ex { out.append((SwipeWord(word: w.word, score: geom + w.score), out.count)) }
        }
        out.sort { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
        return out.prefix(maxCandidates).map { $0.0 }
    }

    /// Ứng viên có dấu (rộng) của cú vuốt kế cho `revise` chung hai từ.
    static func nextPool(_ cands: [SwipeCandidate], context: ((String) -> Float)?,
                         lambdaFreq: Float) -> [SwipeWord] {
        scored(cands, context: context, lambdaFreq: lambdaFreq, poolWords: nextPoolWords,
               maxCandidates: nextMaxCandidates)
    }

    /// Từ trước vừa được sửa ⇒ ngữ cảnh trái của cú vuốt này đổi: chấm lại ứng viên Việt =
    /// hình học (điểm cũ − bung tốt nhất theo ngữ cảnh cũ) + bung tốt nhất theo ngữ cảnh mới,
    /// xếp lại (ổn định). Ứng viên tiếng Anh giữ điểm.
    static func rerank(_ cands: [SwipeCandidate], old: ((String) -> Float)?, oldLambda: Float,
                       new: ((String) -> Float)?, newLambda: Float) -> [SwipeCandidate] {
        let re = cands.map { c -> SwipeCandidate in
            guard c.lang == .vi,
                  let o = SwipeDecoder.expand(c.folded, limit: 1, lambdaFreq: oldLambda, context: old).first,
                  let n = SwipeDecoder.expand(c.folded, limit: 1, lambdaFreq: newLambda, context: new).first
            else { return c }
            return SwipeCandidate(folded: c.folded, score: c.score - o.score + n.score)
        }
        return re.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }.map(\.element)
    }

    /// Thưởng cặp chọn tay (CuratedPairs.swipe) cho (c → n), `x` = từ trước c — = thưởng
    /// SwipeTyping.curatedBonus mà Context.word cộng cho từ kế của từ đang hiện.
    static func curatedBonus(_ x: String?, _ c: String, _ n: String) -> Float {
        CuratedPairs.swipe(x, c, n) ? SwipeTyping.curatedBonus : 0
    }

    /// Điểm phải: trigram s(next | prev, c) có trọng số, kẹp. 0 nếu thiếu dữ liệu.
    static func rightScore(_ lm: SyllableLM, prev: Int, cand: Int, next: Int,
                           weight: Float = rightWeight) -> Float {
        guard let ctx = lm.context(prev2: prev, prev1: cand) else { return 0 }
        return clampRight(weight * ctx.score(next))
    }

    private static func clampRight(_ v: Float) -> Float { max(rightFloor, min(rightCap, v)) }

    /// Sửa CHUNG hai từ (cặp tốt nhất): từ kế chưa chắc — `next` = ứng viên có dấu của cú vuốt
    /// kế (`nextPool`, chấm với ngữ cảnh trái = `current`). Mỗi ứng viên c của từ trước được
    /// điểm cũ + max theo c2 ∈ next của (điểm c2 + phải(c, c2) − phải(current, c2)) — c2 được
    /// chọn lại theo c ("vì dù" → "ví dụ"). `next` một phần tử + weight rightWeight ⇒ y hệt
    /// `revise` theo chuỗi.
    static func revise(_ scored: [SwipeWord], current: String, prev: String?, next: [SwipeWord],
                       lm: SyllableLM? = SyllableLM.shared, margin: Float = margin,
                       weight: Float = jointWeight) -> String? {
        guard let lm, scored.count >= 2, !next.isEmpty else { return nil }
        let prevId = prev.flatMap { SyllableLM.id(of: $0) } ?? -1
        let curCtx = SyllableLM.id(of: current).flatMap { lm.context(prev2: prevId, prev1: $0) }
        let nextIds = next.map { SyllableLM.id(of: $0.word) }
        // điểm từ kế bỏ phần trigram theo từ đang hiện (cộng lại theo từng ứng viên c)
        var base = [Float](repeating: 0, count: next.count)
        for k in next.indices {
            var v = next[k].score
            if let curCtx, let id = nextIds[k] { v -= clampRight(weight * curCtx.score(id)) }
            base[k] = v
        }
        var cur: Float?
        var best: String?
        var bestScore = -Float.infinity
        for w in scored {
            guard let id = SyllableLM.id(of: w.word) else { continue }
            let ctx = lm.context(prev2: prevId, prev1: id)
            var nb = -Float.infinity
            for k in next.indices {
                var v = base[k]
                if let ctx, let nid = nextIds[k] { v += clampRight(weight * ctx.score(nid)) }
                // từ đang hiện: thưởng chọn tay (nếu có) đã nằm trong next[k].score
                if w.word != current { v += curatedBonus(prev, w.word, next[k].word) }
                if v > nb { nb = v }
            }
            let s = w.score + nb
            if w.word == current { cur = s }
            if s > bestScore { bestScore = s; best = w.word }
        }
        guard let cur, let best, best != current, bestScore - cur >= margin else { return nil }
        return best
    }

    /// Từ thay cho `current` (chữ thường, có dấu) khi biết từ kế `next`; nil = giữ nguyên.
    /// `prev` = từ trước `current` (ngữ cảnh trái của trigram phải).
    static func revise(_ scored: [SwipeWord], current: String, prev: String?, next: String,
                       lm: SyllableLM? = SyllableLM.shared, margin: Float = margin,
                       weight: Float = rightWeight) -> String? {
        guard let lm, scored.count >= 2, let nextId = SyllableLM.id(of: next) else { return nil }
        let prevId = prev.flatMap { SyllableLM.id(of: $0) } ?? -1
        var cur: Float?
        var best: String?
        var bestScore = -Float.infinity
        for w in scored {
            guard let id = SyllableLM.id(of: w.word) else { continue }
            let s = w.score + rightScore(lm, prev: prevId, cand: id, next: nextId, weight: weight)
                + curatedBonus(prev, w.word, next)
            if w.word == current { cur = s }
            if s > bestScore { bestScore = s; best = w.word }
        }
        guard let cur, let best, best != current, bestScore - cur >= margin else { return nil }
        return best
    }

    /// Từ vuốt Việt còn nguyên vừa được phím chữ (dấu cách treo) / dấu cách chốt, chờ từ gõ kế
    /// tiếp. `prev` = từ trước nó (ngữ cảnh trái của trigram phải).
    struct Typed: Equatable {
        let word: String
        let scored: [SwipeWord]
        let sc: SwipeCase
        let prev: String?
    }

    /// Kết quả reviseTyped: đuôi `tail` (đang trên màn hình) → `replacement`.
    struct TypedEdit: Equatable {
        let old: String
        let new: String
        let typed: String
        let boundary: String
        var tail: String { old + " " + typed + boundary }
        var replacement: String { new + " " + typed + boundary }
    }

    /// Từ gõ `typed` (dạng cuối đã chốt) vừa được ranh giới `boundary` chốt ngay sau từ vuốt
    /// `p`: chấm lại từ vuốt. Chỉ khi chữ trước con trỏ `before` kết thúc ĐÚNG bằng
    /// "từ vuốt + ␠ + từ gõ + ranh giới" và trước đó không dính chữ/số — lệch/không đọc được ⇒ nil.
    static func reviseTyped(_ p: Typed, typed: String, boundary: String, before: String?,
                            lm: SyllableLM? = SyllableLM.shared, margin: Float = typedMargin,
                            weight: Float = typedRightWeight) -> TypedEdit? {
        guard !typed.isEmpty, let b0 = boundary.first, !b0.isLetter, !b0.isNumber, let before else { return nil }
        let e0 = TypedEdit(old: p.word, new: p.word, typed: typed, boundary: boundary)
        guard before.hasSuffix(e0.tail) else { return nil }
        if let c = before.dropLast(e0.tail.count).last, c.isLetter || c.isNumber { return nil }
        guard let new = revise(p.scored, current: p.word.lowercased(), prev: p.prev, next: typed.lowercased(),
                               lm: lm, margin: margin, weight: weight) else { return nil }
        let cased = p.sc.apply(new)
        return cased == p.word ? nil : TypedEdit(old: p.word, new: cased, typed: typed, boundary: boundary)
    }

    /// Áp `e` lên màn hình: đọc lại đuôi, lệch ⇒ không đụng (false).
    static func apply(_ e: TypedEdit, undo: Bool = false, proxy: TextProxyLike) -> Bool {
        let (from, to) = undo ? (e.replacement, e.tail) : (e.tail, e.replacement)
        guard proxy.contextBeforeInput?.hasSuffix(from) == true else { return false }
        for _ in 0..<from.count { proxy.deleteBackward() }
        proxy.insertText(to)
        return true
    }
}
