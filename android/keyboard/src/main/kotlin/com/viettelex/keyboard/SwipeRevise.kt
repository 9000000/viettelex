package com.viettelex.keyboard

/**
 * SỬA LẠI TỪ VUỐT TRƯỚC khi đã biết từ kế (ngữ cảnh HAI PHÍA). Song sinh iOS
 * Keyboard/SwipeRevise.swift — sửa hằng số/hành vi ở đây thì sửa y hệt bên kia.
 *
 * Vuốt w1 chỉ biết ngữ cảnh trái (w0). Khi cú vuốt kế ra w2, chấm lại các ứng viên c của
 * w1 bằng điểm cũ (hình học + tần suất + ngữ cảnh trái, [scored]) + trigram phải
 * s(w2 | w0, c) (vnlm.bin) ·[RIGHT_WEIGHT] kẹp [[RIGHT_FLOOR], [RIGHT_CAP]]; ứng viên khác
 * thắng từ đang hiện ≥ [MARGIN] ⇒ thay. Chỉ từ Việt (LM là của âm tiết Việt), chỉ từ vuốt
 * liền trước, một lần. Caller lo fail-safe màn hình (đuôi phải khớp đúng từ cũ).
 *
 * Từ kế là cú vuốt (chưa chắc) ⇒ sửa CHUNG cặp: ứng viên c của w1 được chọn cùng ứng viên
 * tốt nhất của w2 theo c ([revise] với danh sách [nextPool], trọng số [JOINT_WEIGHT]) — "vì dù"
 * → "ví dụ" dù "dụ" không đứng đầu sau "vì".
 *
 * Từ kế cũng có thể GÕ BẰNG PHÍM ([Typed]/[reviseTyped]): chấm lại lúc từ gõ được chốt
 * (dấu cách/dấu câu), ngữ cảnh phải = từ đã chốt (chắc chắn) với trọng số/lề riêng.
 *
 * Chi phí: ≤ [MAX_CANDIDATES]·[NEXT_MAX_CANDIDATES] lần tra LM O(log n), chỉ sau một cú vuốt hoặc ở ranh giới từ
 * NGAY SAU từ vuốt — không ở đường phím chữ.
 */
object SwipeRevise {
    /** Chỉnh trên tập dev (SwipeReviseTests.sweep) — docs/DATA-SOURCES.md "Sửa lại từ vuốt trước". */
    const val RIGHT_WEIGHT = 0.1f
    const val RIGHT_CAP = 1.0f
    const val RIGHT_FLOOR = -1.0f
    const val MARGIN = 0.1f
    /**
     * Từ kế GÕ BẰNG PHÍM (chắc chắn, không phải từ vuốt đoán) ⇒ tin ngữ cảnh phải hơn, lề cao
     * hơn để giữ sửa sai thấp. Chỉnh riêng trên dev (SwipeReviseTests.sweepTyped).
     */
    const val TYPED_RIGHT_WEIGHT = 0.15f
    const val TYPED_MARGIN = 0.3f
    const val POOL_FORMS = 3
    const val POOL_WORDS = 8
    const val MAX_CANDIDATES = 12
    /**
     * Sửa CHUNG hai từ ([revise] với danh sách từ kế): ứng viên của cú vuốt kế (rộng hơn — âm
     * tiết kém theo ngữ cảnh cũ có thể thắng theo ngữ cảnh mới: "dụ" sau "ví"), trọng số trigram
     * = trọng số LM trái của decoder ([SwipeSuggest.LM_WEIGHT]) — chỉnh trên dev (SwipeTuneTests).
     */
    const val NEXT_POOL_WORDS = 8
    const val NEXT_MAX_CANDIDATES = 16
    const val JOINT_WEIGHT = SwipeSuggest.LM_WEIGHT

    /**
     * Ứng viên tiếng Việt (chữ thường) của một cú vuốt + điểm tổng cùng thước decoder:
     * điểm dạng − điểm bung tốt nhất của dạng (= phần hình học) + điểm bung của âm tiết.
     * Rỗng khi top-1 là tiếng Anh. [wordCtx]/[lambdaFreq] = đúng cái đã dùng để chọn từ.
     */
    fun scored(cands: List<SwipeCandidate>, wordCtx: ((String) -> Float)?, lambdaFreq: Float,
               poolWords: Int = POOL_WORDS, maxCandidates: Int = MAX_CANDIDATES): List<SwipeWord> {
        if (cands.isEmpty() || cands[0].lang != SwipeLang.VI) return emptyList()
        val out = ArrayList<SwipeWord>()
        for (c in cands.take(POOL_FORMS)) {
            if (c.lang != SwipeLang.VI) continue
            val ex = SwipeDecoder.expand(c.folded, poolWords, lambdaFreq, wordCtx)
            if (ex.isEmpty()) continue
            val geom = c.score - ex[0].score
            for (w in ex) out.add(SwipeWord(w.word, geom + w.score))
        }
        // ổn định: bằng điểm giữ thứ tự decoder
        return out.sortedByDescending { it.score }.take(maxCandidates)
    }

    /** Ứng viên có dấu (rộng) của cú vuốt kế cho [revise] chung hai từ. */
    fun nextPool(cands: List<SwipeCandidate>, wordCtx: ((String) -> Float)?, lambdaFreq: Float): List<SwipeWord> =
        scored(cands, wordCtx, lambdaFreq, NEXT_POOL_WORDS, NEXT_MAX_CANDIDATES)

    /**
     * Từ trước vừa được sửa ⇒ ngữ cảnh trái của cú vuốt này đổi: chấm lại ứng viên Việt =
     * hình học (điểm cũ − bung tốt nhất theo ngữ cảnh cũ) + bung tốt nhất theo ngữ cảnh mới,
     * xếp lại (ổn định). Ứng viên tiếng Anh giữ điểm (ngữ cảnh Anh không theo âm tiết trước).
     */
    fun rerank(cands: List<SwipeCandidate>, oldCtx: ((String) -> Float)?, oldLambda: Float,
               newCtx: ((String) -> Float)?, newLambda: Float): List<SwipeCandidate> =
        cands.map { c ->
            if (c.lang != SwipeLang.VI) c else {
                val old = SwipeDecoder.expand(c.folded, 1, oldLambda, oldCtx).firstOrNull()
                val new = SwipeDecoder.expand(c.folded, 1, newLambda, newCtx).firstOrNull()
                if (old == null || new == null) c else SwipeCandidate(c.folded, c.score - old.score + new.score)
            }
        }.sortedByDescending { it.score }

    /**
     * Thưởng cặp chọn tay ([CuratedPairs.swipe]) cho ([c] → [n]), [x] = từ trước c — = thưởng
     * [SwipeSuggest.CURATED_BONUS] mà Context.word cộng cho từ kế của từ đang hiện.
     */
    fun curatedBonus(x: String?, c: String, n: String): Float =
        if (CuratedPairs.swipe(x, c, n)) SwipeSuggest.CURATED_BONUS else 0f

    /** Điểm phải: trigram s([next] | [prev], c) có trọng số, kẹp. 0 nếu thiếu dữ liệu. */
    fun rightScore(lm: SyllableLM, prevId: Int, candId: Int, nextId: Int, weight: Float = RIGHT_WEIGHT): Float {
        val s = lm.context(prevId, candId)?.score(nextId) ?: return 0f
        return clampRight(weight * s)
    }

    private fun clampRight(v: Float): Float = maxOf(RIGHT_FLOOR, minOf(RIGHT_CAP, v))

    /**
     * Sửa CHUNG hai từ (cặp tốt nhất): từ kế chưa chắc — [next] = ứng viên có dấu của cú vuốt
     * kế ([scored] của nó, chấm với ngữ cảnh trái = [current]). Mỗi ứng viên c của từ trước được
     * điểm cũ + max theo c2 ∈ [next] của (điểm c2 + phải(c, c2) − phải([current], c2)) — c2 được
     * chọn lại theo c ("vì dù" → "ví dụ"). [next] một phần tử + weight [RIGHT_WEIGHT] ⇒ y hệt
     * [revise] theo chuỗi. [next] thường = [nextPool] của cú vuốt kế.
     */
    fun revise(scored: List<SwipeWord>, current: String, prev: String?, next: List<SwipeWord>,
               lm: SyllableLM? = SyllableLM.shared, margin: Float = MARGIN,
               weight: Float = JOINT_WEIGHT): String? {
        if (lm == null || scored.size < 2 || next.isEmpty()) return null
        val prevId = if (prev == null) -1 else SyllableLM.idOf(prev)
        val curId = SyllableLM.idOf(current)
        val nextIds = IntArray(next.size) { SyllableLM.idOf(next[it].word) }
        val curCtx = if (curId < 0) null else lm.context(prevId, curId)
        // điểm từ kế bỏ phần trigram theo từ đang hiện (cộng lại theo từng ứng viên c)
        val base = FloatArray(next.size) {
            next[it].score - (if (curCtx == null || nextIds[it] < 0) 0f else clampRight(weight * curCtx.score(nextIds[it])))
        }
        var cur = Float.NaN
        var best: String? = null
        var bestScore = Float.NEGATIVE_INFINITY
        for (w in scored) {
            val id = SyllableLM.idOf(w.word)
            if (id < 0) continue
            val ctx = lm.context(prevId, id)
            var nb = Float.NEGATIVE_INFINITY
            for (k in next.indices) {
                var v = base[k] + if (ctx == null || nextIds[k] < 0) 0f else clampRight(weight * ctx.score(nextIds[k]))
                // từ đang hiện: thưởng chọn tay (nếu có) đã nằm trong next[k].score
                if (w.word != current) v += curatedBonus(prev, w.word, next[k].word)
                if (v > nb) nb = v
            }
            val s = w.score + nb
            if (w.word == current) cur = s
            if (s > bestScore) { bestScore = s; best = w.word }
        }
        if (cur.isNaN() || best == null || best == current) return null
        return if (bestScore - cur >= margin) best else null
    }

    /**
     * Từ thay cho [current] (chữ thường, có dấu) khi biết từ kế [next]; null = giữ nguyên.
     * [prev] = từ trước [current] (ngữ cảnh trái của trigram phải).
     */
    fun revise(scored: List<SwipeWord>, current: String, prev: String?, next: String,
               lm: SyllableLM? = SyllableLM.shared, margin: Float = MARGIN,
               weight: Float = RIGHT_WEIGHT): String? {
        if (lm == null || scored.size < 2) return null
        val nextId = SyllableLM.idOf(next)
        if (nextId < 0) return null
        val prevId = if (prev == null) -1 else SyllableLM.idOf(prev)
        var cur = Float.NaN
        var best: String? = null
        var bestScore = Float.NEGATIVE_INFINITY
        for (w in scored) {
            val id = SyllableLM.idOf(w.word)
            if (id < 0) continue
            val s = w.score + rightScore(lm, prevId, id, nextId, weight) + curatedBonus(prev, w.word, next)
            if (w.word == current) cur = s
            if (s > bestScore) { bestScore = s; best = w.word }
        }
        if (cur.isNaN() || best == null || best == current) return null
        return if (bestScore - cur >= margin) best else null
    }

    /**
     * Từ vuốt Việt vừa được chốt bằng dấu cách (Android) / phím chữ hay dấu cách (iOS), chờ từ
     * gõ kế tiếp. [prev] = từ trước nó (ngữ cảnh trái của trigram phải).
     */
    class Typed(val word: String, val scored: List<SwipeWord>, val case: SwipeSuggest.Case, val prev: String?)

    /** Kết quả [reviseTyped]: thay đuôi [tail] (đang trên màn hình) bằng [replacement]. */
    class TypedEdit(val old: String, val new: String, val typed: String, val boundary: String) {
        /** Đuôi đang trên màn hình trước khi sửa. */
        val tail: String get() = "$old $typed$boundary"
        /** Đuôi sau khi sửa. */
        val replacement: String get() = "$new $typed$boundary"
    }

    /**
     * Từ gõ [typed] (dạng cuối đã chốt) vừa được ranh giới [boundary] chốt ngay sau từ vuốt
     * [p]: chấm lại từ vuốt. Chỉ khi chữ trước con trỏ [before] kết thúc ĐÚNG bằng
     * "từ vuốt + ␠ + từ gõ + ranh giới" và trước đó không dính chữ/số — lệch/không đọc được ⇒ null.
     */
    fun reviseTyped(p: Typed, typed: String, boundary: String, before: String?,
                    lm: SyllableLM? = SyllableLM.shared, margin: Float = TYPED_MARGIN,
                    weight: Float = TYPED_RIGHT_WEIGHT,
                    learnedCase: ((String) -> String?)? = null, properNouns: Boolean = true): TypedEdit? {
        if (typed.isEmpty() || boundary.isEmpty() || before == null) return null
        if (Character.isLetterOrDigit(boundary.codePointAt(0))) return null
        val tail = p.word + " " + typed + boundary
        if (!before.endsWith(tail)) return null
        val head = before.length - tail.length
        if (head > 0 && Character.isLetterOrDigit(before.codePointBefore(head))) return null
        val new = revise(p.scored, p.word.lowercase(), p.prev, typed.lowercase(), lm, margin, weight) ?: return null
        val cased = SwipeSuggest.applyCase(new, p.case) {
            if (properNouns) DisplayCase.resolve(it, p.prev, learnedCase) else it
        }
        return if (cased == p.word) null else TypedEdit(p.word, cased, typed, boundary)
    }
}
