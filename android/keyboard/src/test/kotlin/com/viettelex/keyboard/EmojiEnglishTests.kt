package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Emoji từ khoá tiếng Anh (CLDR en → section SKEN) + cờ theo mã ISO in hoa (FLG2) —
 * song sinh iOS EmojiEnglishTests. Tiếng Việt không đổi: "Nhật Bản" vẫn → 🇯🇵 khi tìm, âm
 * tiết Việt không dấu không tự dưng có emoji.
 */
class EmojiEnglishTests {
    @Before fun setUp() = TestAssets.install()

    private fun t(word: String, prev: String? = null, raw: String = word) = EmojiSearch.typing(prev, word, raw)

    @Test fun englishWordsAndCountryNames() {
        assertEquals("🇯🇵", t("Japan").first())
        assertEquals("🇯🇵", t("japan").first())
        assertEquals("🍕", t("pizza").first())
        assertEquals("🐕", t("dog").first())
        assertTrue("❤️" in EmojiSearch.search("heart").take(3))
        assertEquals("🇺🇸", t("states", prev = "United").first())
        assertEquals("🌭", t("dog", prev = "hot").first())
        assertEquals("🇻🇳", t("Vietnam").first())
        assertTrue(t("zzqxj").isEmpty())
        // quá chung ("flag" = 270 cờ, "face") → không gợi ý khi gõ (ô tìm vẫn ra)
        assertTrue(t("flag").isEmpty())
        assertTrue(t("face").isEmpty())
        assertTrue(EmojiSearch.search("flag").size > 20)
    }

    @Test fun isoCodesOnlyUppercase() {
        assertEquals(listOf("🇯🇵"), t("JP"))
        assertEquals(listOf("🇺🇸"), t("US"))
        assertEquals(listOf("🇻🇳"), t("VN"))
        assertEquals(listOf("🇰🇷"), t("KR"))
        assertEquals(listOf("🇬🇧"), t("UK"))
        assertTrue(t("jp").isEmpty())
        assertTrue(t("Jp").isEmpty())
        assertTrue(t("XX").isEmpty())
        // Telex biến đổi (raw ≠ composed) → không coi là mã
        assertTrue(t("JP", raw = "JPP").isEmpty())
        // chữ thường trùng âm tiết Việt (la, ma, to, do, ca, co…) → không cờ
        for (w in listOf("la", "ma", "to", "do", "ca", "co", "an", "me", "bo", "vn", "us"))
            assertTrue(w, t(w).isEmpty())
    }

    @Test fun vietnameseSyllablesGainNoEmoji() {
        // âm tiết Việt gõ không dấu (và tiền tố của chúng) — không khớp khoá tiếng Anh nào
        for (w in listOf("an", "bo", "ca", "me", "ban", "can", "hat", "tan", "the", "con", "long",
                         "sang", "tim", "nam", "nguoi", "khong", "thanh", "ngu", "nghi"))
            assertTrue(w, t(w).isEmpty())
        // từ có dấu không bao giờ tra tiếng Anh
        assertTrue(t("bàn", raw = "banf").isEmpty())
        assertTrue(t("Nhật").isEmpty())
        // cụm gồm toàn âm tiết Việt
        assertTrue(t("ban", prev = "an").isEmpty())
    }

    @Test fun vietnameseSearchUnchanged() {
        assertTrue("🇯🇵" in EmojiSearch.search("Nhật Bản").take(3))
        assertTrue("🇯🇵" in EmojiSearch.search("nhat ban").take(3))
        assertTrue("🇯🇵" in EmojiSearch.search("japan").take(3))
        assertTrue("🍕" in EmojiSearch.search("pizza").take(3))
        // tìm có dấu không kéo khoá tiếng Anh: kết quả "cá" y như chỉ có SKEY
        val vn = EmojiSearch.search("cá", limit = 500)
        assertFalse("🐈" in vn.take(5))
        // hạng tiếng Anh sau tiếng Việt: "cho" → 🐶/🐕 vẫn đứng đầu
        assertTrue(EmojiSearch.search("cho").take(5).any { it == "🐶" || it == "🐕" })
        assertTrue(EmojiSearch.enKeyCount > 4000)
    }

    /** Qua KeyboardSession thật: thanh gợi ý khi gõ. */
    private fun bar(text: String): List<String> {
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(), FieldTraits())
        val p = MockProxy()
        for (c in text) s.handle(if (c == ' ') Key.Space else Key.Letter(c), p)
        return s.suggestionsNow(p)!!.emojis
    }

    @Test fun sessionTypingStrip() {
        assertEquals("🇯🇵", bar("Japan").first())
        assertEquals("🇯🇵", bar("japan").first())
        assertEquals("🍕", bar("pizza").first())
        assertEquals(listOf("🇯🇵"), bar("JP"))
        assertFalse("🇯🇵" in bar("jp"))
        assertFalse("🇯🇵" in bar("Jp"))
        // tiếng Việt: hành vi cũ giữ nguyên (bảng biên soạn thắng)
        assertEquals(EmojiSuggest.emojis("yêu"), bar("yeeu"))
        assertEquals(EmojiSuggest.emojis("an"), bar("an"))
        for (w in listOf("ban", "tan", "hat", "the", "nguoi", "la", "ma", "to"))
            assertEquals(w, EmojiSuggest.emojis(w), bar(w))
    }
}
