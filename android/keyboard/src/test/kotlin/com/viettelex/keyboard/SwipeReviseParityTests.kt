package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * Fixture chung iOS ↔ Android cho sửa lại từ vuốt trước (SwipeRevise):
 * iOS/KeyboardTests/Fixtures/swipe-revise.tsv. Sinh ở đây (`VT_WRITE_FIXTURE=1`), iOS
 * SwipeReviseParityTests khớp từng quyết định. Ba loại dòng (cột cách nhau bằng TAB):
 *
 * - `J prev current scored next expected` — sửa CHUNG cặp ([SwipeRevise.revise] với nextPool của
 *   cú vuốt kế), hằng số mặc định. Đầu vào = ứng viên thật của decoder trên câu giữ lại
 *   (bigram-heldout.txt, đường nhiễu σ0.25) nên cả ca sửa lẫn ca giữ.
 * - `T prev current scored typed expected` — từ kế GÕ PHÍM ([SwipeRevise.reviseTyped], TYPED_*).
 * - `P case words expected` — cả câu vuốt bằng đường sạch (SwipeSim seed 7, phím 36×54), như
 *   KeyboardSession.resolveSwipe (không LM cá nhân, tắt vuốt tiếng Anh): chữ cuối trên màn hình.
 *
 * `scored`/`next` = `từ:điểm` cách dấu phẩy; điểm in bằng Float.toString (đọc lại đúng bit).
 * `prev`/`expected` rỗng = `-`.
 */
class SwipeReviseParityTests {
    @Before fun setUp() = TestAssets.install()

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)
    private val decoder = SwipeDecoder().also { it.setLayout(layout) }

    private fun fixtureDir(): File = listOf("../../iOS", "../iOS", "iOS").map { File(it, "KeyboardTests/Fixtures") }
        .firstOrNull { it.exists() } ?: error("không thấy KeyboardTests/Fixtures")

    private fun enc(ws: List<SwipeWord>) = ws.joinToString(",") { "${it.word}:${it.score}" }
    private fun dec(s: String) = s.split(',').map { val (w, v) = it.split(':'); SwipeWord(w, v.toFloat()) }
    private fun opt(s: String?) = s ?: "-"

    /** Câu kiểm tay — Này→Ngày mai (đầu câu viết hoa), cố gắng, ví dụ…, và câu đúng sẵn không được hỏng. */
    private val phrases = listOf(
        "F" to "ngày mai", "F" to "ngày nay", "F" to "ngày xưa", "L" to "ngày mai tôi đi học",
        "L" to "này mai", "F" to "cố gắng", "L" to "cố gắng lên", "L" to "ví dụ như thế này",
        "L" to "hôm nay tôi đi học", "L" to "tôi không biết", "L" to "cô giáo của tôi",
        "F" to "chúc mừng năm mới", "L" to "cảm ơn bạn nhiều", "L" to "bây giờ là mấy giờ",
    )

    private fun case(s: String) = if (s == "F") SwipeSuggest.Case.FIRST else SwipeSuggest.Case.LOWER

    /** Như KeyboardSession.resolveSwipe + commitSwipe, tắt LM cá nhân/tiếng Anh. Từ đầu theo [first]. */
    fun phrase(words: List<String>, first: SwipeSuggest.Case): String {
        val out = ArrayList<String>()
        var rec: Pair<List<SwipeWord>, SwipeSuggest.Case>? = null
        for ((i, word) in words.withIndex()) {
            val sc = if (i == 0) first else SwipeSuggest.Case.LOWER
            val path = SwipeSim(7).path(SwipeSuggest.fold(word), layout, sigma = 0.0, jitter = 0.0)
            val p1 = out.getOrNull(i - 1); val p2 = out.getOrNull(i - 2)
            val ctx = SwipeSuggest.context(null, p1, p2)
            val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded)
            val c0 = SwipeSuggest.choose(cands, ctx.word, sc, ctx.lambdaFreq)
            if (c0 == null) { out.add(""); rec = null; continue }
            var c: SwipeChoice = c0
            var scored = SwipeRevise.scored(cands, ctx.word, ctx.lambdaFreq)
            val r = rec
            val new = if (r == null || p1 == null) null
                else SwipeRevise.revise(r.first, p1.lowercase(), p2, SwipeRevise.nextPool(cands, ctx.word, ctx.lambdaFreq))
            if (new != null) {
                out[i - 1] = SwipeSuggest.applyCase(new, r!!.second)
                val nctx = SwipeSuggest.context(null, out[i - 1], p2)
                val re = SwipeRevise.rerank(cands, ctx.word, ctx.lambdaFreq, nctx.word, nctx.lambdaFreq)
                SwipeSuggest.choose(re, nctx.word, sc, nctx.lambdaFreq)?.let { c = it; scored = SwipeRevise.scored(re, nctx.word, nctx.lambdaFreq) }
            }
            out.add(c.word)
            rec = if (scored.isEmpty()) null else scored to sc
        }
        return out.joinToString(" ")
    }

    private fun heldout(): List<List<String>> =
        File(fixtureDir(), "bigram-heldout.txt").readLines().filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split(' ') }

    private fun generate(): List<String> {
        val lines = ArrayList<String>()
        lines += "# swipe-revise v1 — quyết định SwipeRevise (J sửa chung cặp, T từ kế gõ phím, P cả câu đường sạch). " +
            "Sinh bởi android SwipeReviseParityTests (VT_WRITE_FIXTURE=1); iOS SwipeReviseParityTests khớp từng dòng. Cột cách TAB."
        for ((cs, s) in phrases) lines += listOf("P", cs, s, phrase(s.split(' '), case(cs))).joinToString("\t")
        // J/T: ứng viên thật trên câu giữ lại (tập đo: offset % 3 == 0), đường nhiễu, tuần tự như SwipeReviseTests.simulate
        val sim = SwipeSim(2027)
        var nJ = 0; var nT = 0; var revJ = 0; var revT = 0
        for ((ci, chain) in heldout().withIndex()) {
            if (ci % 3 != 0 || ci > 600) continue
            val out = ArrayList<String>()
            var pending: List<SwipeWord> = emptyList()
            for ((i, word) in chain.withIndex()) {
                val p = sim.path(SwipeSuggest.fold(word), layout, sigma = 0.25)
                val p1 = out.getOrNull(i - 1); val p2 = out.getOrNull(i - 2)
                val ctx = SwipeSuggest.context(null, p1, p2)
                val cands = decoder.decode(p, SwipeSuggest.TOP_K, ctx.folded)
                val c = SwipeSuggest.choose(cands, ctx.word, lambdaFreq = ctx.lambdaFreq)
                var got = c?.word ?: ""
                var sc = if (c == null) emptyList() else SwipeRevise.scored(cands, ctx.word, ctx.lambdaFreq)
                if (p1 != null && pending.size >= 2 && got.isNotEmpty()) {
                    // từ kế gõ phím = đáp án
                    val t = SwipeRevise.revise(pending, p1, p2, word, margin = SwipeRevise.TYPED_MARGIN,
                        weight = SwipeRevise.TYPED_RIGHT_WEIGHT)
                    if (nT < 150 || t != null && revT < 60) {
                        lines += listOf("T", opt(p2), p1, enc(pending), word, opt(t)).joinToString("\t")
                        nT++; if (t != null) revT++
                    }
                    val pool = SwipeRevise.nextPool(cands, ctx.word, ctx.lambdaFreq)
                    val new = SwipeRevise.revise(pending, p1, p2, pool)
                    if (pool.isNotEmpty() && (nJ < 200 || new != null && revJ < 80)) {
                        lines += listOf("J", opt(p2), p1, enc(pending), enc(pool), opt(new)).joinToString("\t")
                        nJ++; if (new != null) revJ++
                    }
                    if (new != null) {
                        out[i - 1] = new
                        val nctx = SwipeSuggest.context(null, new, p2)
                        val re = SwipeRevise.rerank(cands, ctx.word, ctx.lambdaFreq, nctx.word, nctx.lambdaFreq)
                        SwipeSuggest.choose(re, nctx.word, lambdaFreq = nctx.lambdaFreq)?.let { r ->
                            got = r.word; sc = SwipeRevise.scored(re, nctx.word, nctx.lambdaFreq)
                        }
                    }
                }
                pending = sc
                out.add(got)
            }
        }
        return lines
    }

    @Test fun parityFixture() {
        val out = File(fixtureDir(), "swipe-revise.tsv")
        val lines = generate()
        if (System.getenv("VT_WRITE_FIXTURE") != null) out.writeText(lines.joinToString("\n") + "\n")
        assertEquals("chạy VT_WRITE_FIXTURE=1 để sinh lại", out.readLines(), lines)
    }

    /** Đọc lại fixture, tính lại từng quyết định từ đầu vào đã ghi (không cần decoder). */
    @Test fun fixtureDecisionsReplay() {
        var n = 0
        for (line in File(fixtureDir(), "swipe-revise.tsv").readLines()) {
            if (line.isBlank() || line.startsWith("#")) continue
            val f = line.split('\t')
            val prev = f[1].takeIf { it != "-" }
            when (f[0]) {
                "J" -> assertEquals(line, f[5].takeIf { it != "-" }, SwipeRevise.revise(dec(f[3]), f[2], prev, dec(f[4])))
                "T" -> {
                    val t = SwipeRevise.Typed(f[2], dec(f[3]), SwipeSuggest.Case.LOWER, prev)
                    val before = (prev?.let { "$it " } ?: "") + f[2] + " " + f[4] + " "
                    assertEquals(line, f[5].takeIf { it != "-" }, SwipeRevise.reviseTyped(t, f[4], " ", before)?.new)
                }
                "P" -> assertEquals(line, f[3], phrase(f[2].split(' '), case(f[1])))
                else -> error(line)
            }
            n++
        }
        org.junit.Assert.assertTrue("fixture quá ít dòng: $n", n > 300)
    }

    /** Ca Phil 18/10/2026: vuốt "ngay" đầu câu ra "Này" (n-a-y ≈ n-g-a-y); vuốt "mai" ⇒ "Ngày mai". */
    @Test fun nayToNgayMaiAtSentenceStart() {
        assertEquals("Ngày mai", phrase(listOf("ngay", "mai"), SwipeSuggest.Case.FIRST))
        // một mình: "Này" (đường gần như trùng) — chỉ ngữ cảnh phải mới phân biệt được
        assertEquals("Này", phrase(listOf("ngay"), SwipeSuggest.Case.FIRST))
    }
}
