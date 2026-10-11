package com.viettelex.keyboard

import com.viettelex.keyboard.SuggestionCase.Shift
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Feedback 10/2026: bật Shift mà gợi ý không viết hoa như Gboard. SuggestionCase thuần (song
 * sinh iOS SuggestionCaseTests) + đường session: đổi Shift ⇒ bar tính lại, chọn gợi ý ⇒ chèn
 * đúng dạng đang hiện rồi nhả Shift một-lần, học dạng thường.
 */
class SuggestionCaseTests {
    @Before fun setUp() = TestAssets.install()

    private fun d(w: String, s: Shift, typed: String = "") = SuggestionCase.display(w, s, typed)

    @Test fun testShiftStatesWithEmptyComposing() {
        assertEquals("bên", d("bên", Shift.OFF))
        assertEquals("Bên", d("bên", Shift.ONCE))
        assertEquals("BÊN", d("bên", Shift.CAPS_LOCK))
        assertEquals("Đi", d("đi", Shift.ONCE))
        assertEquals("ĐƯỜNG", d("đường", Shift.CAPS_LOCK))
        assertEquals("Ước", d("ước", Shift.ONCE))
        assertEquals("Ăn", d("ăn", Shift.ONCE))
        // "i" tiếng Việt/Anh: không ra "İ" kiểu Thổ Nhĩ Kỳ
        assertEquals("ÍT", d("ít", Shift.CAPS_LOCK))
        assertEquals("I", d("i", Shift.ONCE))
    }

    @Test fun testTypedPrefixCasingWins() {
        assertEquals("Bên", d("bên", Shift.OFF, "Bê"))
        assertEquals("Bên", d("bên", Shift.OFF, "B"))
        assertEquals("BÊN", d("bên", Shift.OFF, "BÊ"))
        assertEquals("bên", d("bên", Shift.OFF, "bê"))
        assertEquals("bên", d("bên", Shift.ONCE, "bê"))       // shift bật giữa từ: cho phím kế
        assertEquals("BÊN", d("bên", Shift.CAPS_LOCK, "B"))
        assertEquals("Đường", d("đường", Shift.OFF, "Đư"))
        assertEquals("ĐƯỜNG", d("đường", Shift.OFF, "ĐƯ"))
        assertEquals("bên", d("bên", Shift.OFF, "bÊ"))
    }

    @Test fun testLeavesSpecialCandidatesAlone() {
        assertEquals("iPhone", d("iPhone", Shift.ONCE))
        assertEquals("SenPrints", d("SenPrints", Shift.ONCE))
        assertEquals("FPT", d("FPT", Shift.ONCE))
        assertEquals("IPHONE", d("iPhone", Shift.CAPS_LOCK))
        assertEquals("😀", d("😀", Shift.ONCE))
        assertEquals("😀", d("😀", Shift.CAPS_LOCK))
        assertEquals("100.000", d("100.000", Shift.CAPS_LOCK))
        assertEquals("@gmail.com", d("@gmail.com", Shift.CAPS_LOCK))
        assertEquals("", d("", Shift.ONCE))
    }

    @Test fun testAfterCommit() {
        assertEquals(Shift.OFF, SuggestionCase.afterCommit(Shift.ONCE))
        assertEquals(Shift.OFF, SuggestionCase.afterCommit(Shift.OFF))
        assertEquals(Shift.CAPS_LOCK, SuggestionCase.afterCommit(Shift.CAPS_LOCK))
    }

    // MARK: đường session (IME gán keyboardShift từ phím Shift thật)

    private val clip = object : ClipboardSource {
        override var changeCount = 0
        override fun hasText() = false
        override fun readText(): String? = null
    }

    private fun session(traits: FieldTraits = FieldTraits(capSentences = true), lm: UserLangModel = UserLangModel()) =
        KeyboardSession(lm, clip) { 1_000_000L }.also { it.startInput(KeyboardSettings(), traits) }

    private fun KeyboardSession.typeKeys(p: TextProxy, keys: String) {
        for (c in keys) handle(if (c == ' ') Key.Space else Key.Letter(c), p)
    }

    private fun capitalized(w: String) = w.isNotEmpty() && Character.isUpperCase(w.codePointAt(0))

    /** Bấm Shift giữa câu: bar cần tính lại ngay và ra Hoa đầu; Caps ⇒ HOA HẾT; tắt ⇒ như cũ. */
    @Test fun testShiftToggleRefreshesNextWords() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "toi di ")
        assertEquals(false, s.updateAutoShift(p))
        s.keyboardShift = Shift.OFF
        val before = s.suggestionsNow(p)!!.nextWords
        assertTrue(before.isNotEmpty())
        assertTrue(before.toString(), before.none(::capitalized))
        assertFalse("bar đã đúng ⇒ khỏi tính lại", s.shiftNeedsRefresh())

        s.keyboardShift = Shift.ONCE
        assertTrue(s.shiftNeedsRefresh())
        val once = s.suggestionsNow(p)!!.nextWords
        assertEquals(before.map { it.lowercase() }, once.map { it.lowercase() })
        assertTrue(once.toString(), once.all(::capitalized))
        assertFalse(s.shiftNeedsRefresh())

        s.keyboardShift = Shift.CAPS_LOCK
        assertTrue(s.shiftNeedsRefresh())
        val caps = s.suggestionsNow(p)!!.nextWords
        assertEquals(before.map { it.uppercase() }, caps)

        s.keyboardShift = Shift.OFF
        assertTrue(s.shiftNeedsRefresh())
        assertEquals(before, s.suggestionsNow(p)!!.nextWords)
    }

    /** Đầu câu mà user tự TẮT Shift: gợi ý thường (Gboard) — không theo autoShiftOn nữa. */
    @Test fun testManualUnshiftAtSentenceStart() {
        val s = session(); val p = MockProxy()
        assertEquals(true, s.updateAutoShift(p))
        s.keyboardShift = Shift.ONCE
        assertEquals(listOf("Em", "Anh", "Tôi"), s.suggestionsNow(p)!!.nextWords)
        s.keyboardShift = Shift.OFF
        assertTrue(s.shiftNeedsRefresh())
        assertEquals(listOf("em", "anh", "tôi"), s.suggestionsNow(p)!!.nextWords)
    }

    /** Đang gõ "Be": ứng viên Hoa đầu ("Bên"); đổi Shift lúc gõ dở (không Caps) không tính lại. */
    @Test fun testTypedCapitalCarriesToComposingCandidates() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "toi di ")
        s.keyboardShift = Shift.OFF
        s.handle(Key.Letter('B'), p); s.handle(Key.Letter('e'), p)
        val set = s.suggestionsNow(p)!!
        val ws = listOfNotNull(set.word, set.word2)
        assertTrue(ws.isNotEmpty())
        assertTrue(ws.toString(), ws.all(::capitalized))
        s.keyboardShift = Shift.ONCE
        assertFalse(s.shiftNeedsRefresh())
        s.keyboardShift = Shift.CAPS_LOCK
        assertTrue(s.shiftNeedsRefresh())
        val caps = listOfNotNull(s.suggestionsNow(p)!!.word)
        assertTrue(caps.toString(), caps.all { it == it.uppercase() })
    }

    /**
     * Chọn gợi ý khi Shift một-lần: chèn đúng dạng đang hiện, Shift nhả (keyboardShift OFF ⇒ IME
     * hạ phím Shift), bar sau đó về thường; học dưới khoá thường. Ô không tự viết hoa.
     */
    @Test fun testCommitInsertsShiftedFormReleasesShiftLearnsLowercase() {
        val lm = UserLangModel()
        val s = session(FieldTraits(), lm); val p = MockProxy()
        s.typeKeys(p, "toi di ")
        assertEquals(null, s.updateAutoShift(p))
        s.keyboardShift = Shift.ONCE
        val shown = s.suggestionsNow(p)!!.nextWords.first()
        assertTrue(shown, capitalized(shown))
        val base = shown.lowercase()
        val c0 = lm.count(base)
        s.acceptSuggestion(shown, p)
        assertTrue(p.text, p.text.endsWith(" $shown "))
        assertEquals(Shift.OFF, s.keyboardShift)
        assertTrue(lm.count(base) > c0)
        val after = s.suggestionsNow(p)!!.nextWords
        assertTrue(after.toString(), after.all { !capitalized(it) || DisplayCase.apply(it.lowercase()) == it })

        // Caps Lock giữ sau khi chọn
        s.keyboardShift = Shift.CAPS_LOCK
        val up = s.suggestionsNow(p)!!.nextWords.first()
        s.acceptSuggestion(up, p)
        assertTrue(p.text, p.text.endsWith(" $up "))
        assertEquals(Shift.CAPS_LOCK, s.keyboardShift)
    }
}
