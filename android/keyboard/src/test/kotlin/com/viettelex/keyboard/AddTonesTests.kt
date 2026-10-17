package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.Locale

/**
 * Thêm dấu cho câu không dấu. Song sinh iOS AddTonesTests.swift. Đo độ chính xác trên câu
 * Tatoeba GIỮ LẠI (bigram-heldout.txt — không nằm trong dữ liệu dựng vnlm.bin): bỏ dấu
 * → khôi phục → tỉ lệ âm tiết đúng.
 */
class AddTonesTests {
    private var savedPaywall = PlusGate.paywallEnabled
    @Before fun setUp() { TestAssets.install(); savedPaywall = PlusGate.paywallEnabled; PlusGate.paywallEnabled = false }
    @After fun tearDown() { PlusGate.paywallEnabled = savedPaywall }

    private fun fixture(name: String): File =
        listOf("../../iOS", "../iOS", "iOS").map { File(it, "KeyboardTests/Fixtures/$name") }
            .firstOrNull { it.exists() } ?: error("không thấy $name")

    private fun heldout(): List<List<String>> = fixture("bigram-heldout.txt").readLines()
        .filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split(' ') }

    private fun r(s: String) = AddTones.restore(s).text

    @Test fun basicSentences() {
        assertEquals("tôi đi học hôm nay", r("toi di hoc hom nay"))
        assertEquals("không có gì", r("khong co gi"))
        assertTrue(r("cam on ban rat nhieu") in setOf("cảm ơn bạn rất nhiều", "cám ơn bạn rất nhiều"))
    }

    @Test fun keepsCasePunctuationAndSpacing() {
        assertEquals("Tôi đi học, hôm nay trời đẹp!", r("Toi di hoc, hom nay troi dep!"))
        assertEquals("TÔI ĐI HỌC", r("TOI DI HOC"))
        assertEquals("  (tôi)  đi\thọc...", r("  (toi)  di\thoc..."))
        val s = "toi di hoc hom nay"
        assertEquals(s.length, r(s).length)
    }

    @Test fun keepsNonVietnameseTokens() {
        // số, URL, email, chữ lẫn số, camelCase, từ Anh không phải dạng Việt
        assertEquals("tôi mua iPhone 15 ở shopee.vn", r("toi mua iPhone 15 o shopee.vn"))
        assertEquals("gửi mail cho abc@gmail.com nhé", r("gui mail cho abc@gmail.com nhe"))
        assertEquals("h2o 123 tôi", r("h2o 123 toi"))
        assertEquals("xem movie trên netflix", r("xem movie tren netflix"))
        assertEquals("tôi 😀 đi", r("toi 😀 di"))
    }

    @Test fun ambiguousNextToEnglishKept() {
        // "the" là dạng Việt (thế…) nhưng kề "weekend" (chắc Anh) ⇒ giữ nguyên
        val out = r("toi thich the weekend")
        assertTrue(out, out.endsWith("the weekend"))
    }

    @Test fun segmentStopsAtDiacriticsAndNewline() {
        assertEquals("hoc hom nay ", AddTones.segment("Tôi đi hoc hom nay "))
        assertEquals("hom nay", AddTones.segment("dong 1\nhom nay"))
        assertEquals("", AddTones.segment("toi di\n"))
        assertEquals("", AddTones.segment(""))
        assertEquals("toi di", AddTones.segment("  toi di"))
    }

    @Test fun planIsMinimalTail() {
        val p = AddTones.plan("Tôi viết: toi di hoc ")
        assertEquals(AddTones.Plan("oi di hoc ", "ôi đi học "), p)
        assertNull("1 âm tiết không mời", AddTones.plan("toi "))
        assertNull("đã đúng không mời", AddTones.plan("anh em "))
        assertNull("câu tiếng Anh không mời", AddTones.plan("the quick brown fox jumps over "))
        assertNull(AddTones.plan("Tôi đi học "))
    }

    @Test fun maxSyllablesCap() {
        val long = List(300) { "toi" }.joinToString(" ")
        val seg = AddTones.segment(long)
        assertEquals(AddTones.MAX_SYLLABLES, seg.split(' ').size)
    }

    @Test fun personalModelWins() {
        // người dùng hay gõ "ma" (không phải "mà") sau "con" ⇒ theo cá nhân
        val base = AddTones.restore("con ma nay").text
        val pers = AddTones.Personal(count = { 0 }, pair = { a, b -> if (a == "con" && b == "ma") 40 else 0 })
        val out = AddTones.restore("con ma nay", pers).text
        assertTrue("$base → $out", out.startsWith("con ma "))
    }

    // ---- đo độ chính xác ----

    data class Acc(val n: Int, val ok: Int, val sent: Int, val sentOk: Int) {
        val r get() = ok.toDouble() / n
        val rs get() = sentOk.toDouble() / sent
        fun fmt() = String.format(Locale.ROOT, "âm tiết %.4f (n=%d) | câu %.3f (n=%d)", r, n, rs, sent)
    }

    private fun measure(p: AddTones.Params, chains: List<List<String>> = heldout(),
                        lm: SyllableLM? = SyllableLM.shared,
                        personal: AddTones.Personal? = null): Acc {
        var n = 0; var ok = 0; var sOk = 0
        for (c in chains) {
            val folded = c.joinToString(" ") { SwipeSuggest.fold(it) }
            val out = AddTones.restore(folded, personal, p, lm).text.split(' ')
            var all = true
            for (i in c.indices) { n++; if (out[i] == c[i]) ok++ else all = false }
            if (all) sOk++
        }
        return Acc(n, ok, chains.size, sOk)
    }

    @Test fun heldoutAccuracy() {
        val uni = measure(AddTones.Params(), lm = null)
        val bi = measure(AddTones.Params(trigram = false))
        val full = measure(AddTones.Params())
        val m = UserLangModel().apply { isKnownWord = { VNSuggest.contains(it) }; seedIfEmpty() }
        val seeded = measure(AddTones.Params(), personal = AddTones.Personal(m::count, m::bigramCount))
        println("ADDTONES heldout Kotlin + seed UserLangModel: ${seeded.fmt()}")
        assertTrue(seeded.fmt(), seeded.r >= full.r - 0.002)
        println("ADDTONES heldout Kotlin: chỉ unigram ${uni.fmt()} | + bigram ${bi.fmt()} | + trigram ${full.fmt()}")
        // đo 27/09/2026: 0.7635 → 0.9463 (câu 0.209 → 0.732); 18/10/2026 trigram: bigram 0.9550
        // (câu 0.767) → trigram 0.9645 (câu 0.811). Cùng ngưỡng với Swift.
        assertTrue(full.fmt(), full.r >= 0.96)
        assertTrue(full.r - uni.r >= 0.15)
        assertTrue("trigram phải hơn bigram", full.r - bi.r >= 0.005 && full.rs > bi.rs)
    }

    /**
     * Ba câu Phil thử 18/10/2026. "không dấu" / "Thử gõ" CHƯA đúng: vnlm.bin không có mục
     * (không, dấu) nào — cả bigram lẫn trigram — nên "không đâu" (phổ biến hơn trong dữ liệu)
     * thắng; cần dữ liệu, trigram không đủ. Chỉ khoá phần còn lại + chip vẫn mời cả câu.
     */
    @Test fun philSentences() {
        val a = r("Minh dang go tieng Viet khong dau.")
        assertTrue(a, a.startsWith("Mình đang gõ tiếng Việt không "))
        val b = r("Thu go tieng Viet khong dau xem sao.")
        assertTrue(b, b.contains(" gõ tiếng Việt không ") && b.endsWith(" xem sao."))
        val c = r("Ngay mai minh se den truong hop lop cap 3.")     // họp/hợp: mơ hồ thật, không khoá
        assertTrue(c, c.startsWith("Ngày mai mình sẽ đến trường ") && c.endsWith(" lớp cấp 3."))
        for (x in listOf("Minh dang go tieng Viet khong dau.", "Thu go tieng Viet khong dau xem sao.",
                         "Ngay mai minh se den truong hop lop cap 3.")) assertNotNull(x, AddTones.plan(x))
    }

    /**
     * Lưới chọn trọng số (in ra, không assert) — chạy tay khi đổi dữ liệu. Chọn trên tập DEV
     * (ADDTONES_CHAINS = chuỗi dev sinh bởi Scripts/gen-syllable-lm.py chains --input dev.txt),
     * không phải heldout.
     */
    @Test fun tuneGrid() {
        if (System.getenv("ADDTONES_TUNE") == null) return
        val chains = System.getenv("ADDTONES_CHAINS")?.let { f -> File(f).readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split(' ') } } ?: heldout()
        for (fw in listOf(6.0, 8.0, 10.0, 12.0))
            for (bw in listOf(0.5, 0.75, 1.0, 1.25))
                for (fl in listOf(-100.0, -3.0, -2.5, -2.0, -1.5, -0.5)) {
                    val a = measure(AddTones.Params(freqW = fw, bigramW = bw, floor = fl), chains)
                    println(String.format(Locale.ROOT, "TUNE fw=%.1f bw=%.2f floor=%.1f → %s", fw, bw, fl, a.fmt()))
                }
    }

    /** Lưới trọng số cá nhân với UserLangModel chỉ có seed (người dùng mới). */
    @Test fun tunePersonal() {
        if (System.getenv("ADDTONES_TUNE_P") == null) return
        val chains = heldout()
        val m = UserLangModel().apply { isKnownWord = { VNSuggest.contains(it) }; seedIfEmpty() }
        val pers = AddTones.Personal(m::count, m::bigramCount)
        for (pu in listOf(0.0, 0.1, 0.25, 0.5))
            for (pb in listOf(0.0, 0.25, 0.5, 1.0, 1.5)) {
                val a = measure(AddTones.Params(personalUni = pu, personalBi = pb), chains, personal = pers)
                println(String.format(Locale.ROOT, "TUNEP pu=%.2f pb=%.2f → %s", pu, pb, a.fmt()))
            }
    }

    @Test fun speed30Syllables() {
        val s = heldout().flatten().take(30).joinToString(" ") { SwipeSuggest.fold(it) }
        repeat(20) { AddTones.restore(s) }
        val t0 = System.nanoTime()
        repeat(100) { AddTones.restore(s) }
        val ms = (System.nanoTime() - t0) / 1e6 / 100
        println(String.format(Locale.ROOT, "ADDTONES 30 âm tiết Kotlin: %.3f ms", ms))
        assertTrue("$ms ms", ms < 10)
    }

    /** Parity với Swift: fixture chung (đầu vào ⇥ kết quả). Sinh lại: ADDTONES_GEN=1. */
    @Test fun sharedFixture() {
        val f = fixture("add-tones.txt")
        val lines = f.readLines()
        if (System.getenv("ADDTONES_GEN") != null) {
            val out = lines.map { l ->
                if (l.isBlank() || l.startsWith("#")) l else {
                    val input = l.substringBefore('\t')
                    input + "\t" + AddTones.restore(input).text
                }
            }
            f.writeText(out.joinToString("\n") + "\n")
            return
        }
        var n = 0
        for (l in lines) {
            if (l.isBlank() || l.startsWith("#")) continue
            val (input, expected) = l.split('\t')
            assertEquals("đầu vào: $input", expected, AddTones.restore(input).text)
            n++
        }
        assertTrue(n >= 40)
    }

    // ---- tích hợp KeyboardSession: chip Thêm dấu / Hoàn tác ----

    private fun session(): KeyboardSession =
        KeyboardSession(UserLangModel()).also { it.startInput(KeyboardSettings(addTonesChip = true), FieldTraits()) }

    /** Mặc định chip TẮT: không mời, và dấu cách không đọc context thêm lần nào so với tắt thanh chip số. */
    @Test fun chipOffByDefaultAndCostsNothing() {
        assertFalse(KeyboardSettings().addTonesChip)
        assertFalse(KeyboardSettings.load { null }.addTonesChip)
        val s = KeyboardSession(UserLangModel()).also { it.startInput(KeyboardSettings(), FieldTraits()) }
        val p = MockProxy()
        p.insertText("khong co gi ")
        p.contextReads = 0
        val set = s.suggestionsNow(p)!!
        assertNull(set.action)
        // Lượt gợi ý sau dấu cách: chỉ nút Dán (clipboard null ⇒ 0) — AddTones không đọc gì.
        assertEquals(0, p.contextReads)
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)     // token lạc (không có chip) ⇒ không đổi
        assertEquals("khong co gi ", p.text)
    }

    @Test fun chipSwitchLoadsFromPrefs() {
        assertTrue(KeyboardSettings.load { if (it == Keys.ADD_TONES_CHIP) true else null }.addTonesChip)
    }

    @Test fun sessionOfferApplyAndUndoChip() {
        val s = session(); val p = MockProxy()
        p.insertText("Tôi viết: toi di hoc hom nay ")        // như vừa dán
        val set = s.suggestionsNow(p)!!
        assertEquals(SuggestionSet.ADD_TONES_TOKEN, set.action)
        assertEquals(KeyboardSession.ADD_TONES_LABEL, set.actionLabel)
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        assertEquals("Tôi viết: tôi đi học hôm nay ", p.text)
        assertEquals(SuggestionSet.UNDO_TONES_TOKEN, s.suggestionsNow(p)!!.action)
        s.acceptSuggestion(SuggestionSet.UNDO_TONES_TOKEN, p)
        assertEquals("Tôi viết: toi di hoc hom nay ", p.text)
        assertNull("vừa hoàn tác ⇒ không mời lại đúng đoạn đó", s.suggestionsNow(p)!!.action)
    }

    @Test fun sessionBackspaceRightAfterUndoes() {
        val s = session(); val p = MockProxy()
        p.insertText("khong co gi")
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        assertEquals("không có gì", p.text)
        s.handle(Key.Backspace, p)
        assertEquals("khong co gi", p.text)
        s.handle(Key.Backspace, p)                              // ⌫ thứ hai: xoá thường
        assertEquals("khong co g", p.text)
    }

    @Test fun sessionOtherKeyEndsUndo() {
        val s = session(); val p = MockProxy()
        p.insertText("khong co gi ")
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        s.handle(Key.Letter('a'), p)
        s.handle(Key.Backspace, p)
        assertEquals("không có gì ", p.text)
        assertNull(s.suggestionsNow(p)!!.action)
    }

    @Test fun sessionFailSafeWhenTextChanged() {
        val s = session(); val p = MockProxy()
        p.insertText("khong co gi")
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        p.sb.append("!")                                         // ô đổi mà không báo
        s.acceptSuggestion(SuggestionSet.UNDO_TONES_TOKEN, p)
        assertEquals("không có gì!", p.text)
    }

    @Test fun sessionNoOfferWhenCannotReEditOrComposing() {
        val s = session(); val p = MockProxy()
        p.insertText("khong co gi ")
        p.reEdit = false
        assertNull(s.suggestionsNow(p)!!.action)
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        assertEquals("khong co gi ", p.text)
        p.reEdit = true
        s.handle(Key.Letter('t'), p)                             // đang gõ dở ⇒ không chip
        assertNull(s.suggestionsNow(p)!!.action)
    }

    @Test fun sessionGatedByPlus() {
        val s = session(); val p = MockProxy()
        p.insertText("khong co gi ")
        PlusGate.paywallEnabled = true                          // bật thanh toán, chưa mua
        assertNull(s.suggestionsNow(p)!!.action)
        s.acceptSuggestion(SuggestionSet.ADD_TONES_TOKEN, p)
        assertEquals("khong co gi ", p.text)
    }
}
