package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.text.Normalizer

/**
 * Cặp chọn tay (Scripts/curated-pairs.txt → [CuratedPairs]): Thêm dấu, bung dấu từ vuốt, sửa chung
 * hai từ vuốt, xếp gợi ý đang gõ. Song sinh iOS CuratedPairsTests.swift. Câu/cặp Phil báo 18/10/2026.
 */
class CuratedPairsTests {
    @Before fun setUp() { TestAssets.install() }

    private fun r(s: String, personal: AddTones.Personal? = null) = AddTones.restore(s, personal).text

    @Test fun addTonesPhilSentences() {
        assertEquals("Mình đang gõ tiếng Việt không dấu.", r("Minh dang go tieng Viet khong dau."))
        assertEquals("Thử gõ tiếng Việt không dấu xem sao.", r("Thu go tieng Viet khong dau xem sao."))
        assertEquals("tiếng Việt có dấu", r("tieng Viet co dau"))
        assertEquals("bóp vú", r("bop vu"))
        assertEquals("bóp dái", r("bop dai"))
        assertEquals("lều báo", r("leu bao"))
        assertEquals("gõ vuốt trên bàn phím", r("go vuot tren ban phim"))
    }

    /** "co dau": một mình = cô dâu, ngữ cảnh gõ/chữ = có dấu, chat "làm gì …" = có đâu. */
    @Test fun coDauThreeReadings() {
        // đứng một mình: vnlm.bin hội thoại (18/10/2026) nghiêng "có dấu" (trước: "cô dâu") — Phil quyết
        assertEquals("có dấu", r("co dau"))
        assertEquals("cô dâu chú rể", r("co dau chu re"))
        assertEquals("tiếng Việt có dấu", r("tieng Viet co dau"))
        assertEquals("làm gì có đâu", r("lam gi co dau"))
    }

    @Test fun noCollateralFlips() {
        assertEquals("xin số điện thoại", r("xin so dien thoai"))
        assertEquals("đi qua đỉnh núi", r("di qua dinh nui"))
        assertEquals("cơ hội việc làm", r("co hoi viec lam"))
        assertEquals("thêm đầu tư", r("them dau tu"))
        assertEquals("anh đi đâu đấy", r("anh di dau day"))
    }

    /** Người dùng thắng: đã gõ "không đâu" ≥ CURATED_YIELD lần ⇒ bảng tắt ở vị trí đó. */
    @Test fun userHabitBeatsCuratedPair() {
        val s = "tieng Viet khong dau"
        assertTrue(r(s).endsWith("không dấu"))
        val pers = AddTones.Personal({ 0 }, { a, b -> if (a == "không" && b == "đâu") 3 else 0 })
        assertTrue(r(s, pers), r(s, pers).endsWith("không đâu"))
        val few = AddTones.Personal({ 0 }, { a, b -> if (a == "không" && b == "đâu") 2 else 0 })
        assertTrue(r(s, few).endsWith("không dấu"))
    }

    @Test fun curatedOffIsOldBehaviour() {
        // vnlm.bin hội thoại (18/10/2026) tự ra "bóp vú" ⇒ khoá bằng cặp còn cần bảng
        assertEquals("bóp dài", AddTones.restore("bop dai", null, AddTones.Params(curated = false)).text)
    }

    @Test fun tableLookups() {
        assertTrue(CuratedPairs.has(null, "bóp", "vú"))
        assertFalse(CuratedPairs.has(null, "không", "dấu"))
        assertTrue(CuratedPairs.has("việt", "không", "dấu"))
        assertFalse(CuratedPairs.has(null, "cô", "dâu"))
        assertTrue(CuratedPairs.swipe(null, "cô", "dâu"))
        assertEquals(listOf("dấu"), CuratedPairs.next("có", "Việt"))
        assertEquals(listOf("đâu"), CuratedPairs.next("có", "gì"))
        assertEquals(emptyList<String>(), CuratedPairs.next("có", null))
        assertEquals(listOf("a", "dái", "vú"), CuratedPairs.withNext(listOf("a"), "bóp", null))
        assertEquals(listOf("a"), CuratedPairs.withNext(listOf("a"), null, null))
        for (k in CuratedPairs.pairs + CuratedPairs.triples + CuratedPairs.nextOnly)
            assertEquals(k, Normalizer.normalize(k.lowercase(), Normalizer.Form.NFC))
    }

    /** Không phải seed từ kế tiếp: sau "có" không gợi "dấu". */
    @Test fun notANextWordSeed() {
        val m = seeded()
        assertFalse(m.nextWords("có", null, 6).contains("dấu"))
        assertFalse(m.nextWords("bóp", null, 6).contains("vú"))
    }

    // ---- vuốt (phần thuần) ----

    private fun seeded() = UserLangModel().apply { isKnownWord = { VNSuggest.contains(it) }; seedIfEmpty() }
    private val model by lazy { seeded() }

    private fun ctx(prev: String?, prev2: String? = null, curated: Boolean = true): SwipeSuggest.Context {
        val next = if (prev != null) model.nextWords(prev, prev2, 24).map { it.lowercase() }.toSet() else emptySet()
        return SwipeSuggest.Context(next, next.mapTo(HashSet()) { SwipeSuggest.fold(it) }, { model.count(it) },
            prev, null, prev2, SyllableLM.shared, curated)
    }

    private fun swipe(folded: String, prev: String?, prev2: String? = null, curated: Boolean = true): String? {
        val c = ctx(prev, prev2, curated)
        return SwipeSuggest.choose(listOf(SwipeCandidate(folded, 0f)), c.word, lambdaFreq = c.lambdaFreq)?.word
    }

    @Test fun swipeExpansionInContext() {
        assertEquals("gõ \"cô\" rồi vuốt \"dau\"", "dâu", swipe("dau", "cô"))
        assertEquals("dấu", swipe("dau", "có", "việt"))
        assertEquals("dấu", swipe("dau", "không", "việt"))
        assertEquals("đâu", swipe("dau", "có", "gì"))
        assertEquals("vú", swipe("vu", "bóp"))
        assertEquals("dái", swipe("dai", "bóp"))
        assertEquals("cu", swipe("cu", "sờ"))
        assertEquals("cu", swipe("cu", "mò"))
        assertEquals("báo", swipe("bao", "lều"))
    }

    private fun joint(first: String, second: String, prev: String? = null): Pair<String, String?> {
        val c0 = ctx(prev)
        val scored = SwipeRevise.scored(listOf(SwipeCandidate(first, 0f)), c0.word, c0.lambdaFreq)
        val current = SwipeSuggest.choose(listOf(SwipeCandidate(first, 0f)), c0.word, lambdaFreq = c0.lambdaFreq)!!.word
        val c1 = ctx(current, prev)
        val next = SwipeRevise.nextPool(listOf(SwipeCandidate(second, 0f)), c1.word, c1.lambdaFreq)
        return current to SwipeRevise.revise(scored, current, prev, next)
    }

    /** Hai cú vuốt liền "co" "dau": từ trước được sửa chung theo cặp (có đâu → cô dâu). */
    @Test fun swipeJointRevise() {
        val (cur, rev) = joint("co", "dau")
        assertEquals("co dau (đang hiện $cur)", "cô", rev ?: cur)
    }

    @Test fun inlineRankingUsesCuratedContext() {
        val pool = VNSuggest.matches("vu", 24, "vu")
        val ctx = CuratedPairs.withNext(emptyList(), "bóp", null).toSet()
        val ranked = SuggestRank.rankInline(pool, SuggestRank.inlinePmi(pool, "bóp"), 2, { 0 }, ctx)
        assertEquals(ranked.take(4).toString(), "vú", ranked.first())
    }
}
