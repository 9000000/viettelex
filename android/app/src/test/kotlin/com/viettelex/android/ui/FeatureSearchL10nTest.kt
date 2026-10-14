package com.viettelex.android.ui

import com.viettelex.keyboard.L10n
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ô tìm cài đặt khớp CẢ tiếng Việt lẫn English, bất kể đang chọn ngôn ngữ nào. */
class FeatureSearchL10nTest {
    @After fun reset() { L10n.lang = L10n.DEFAULT }

    private fun pages(q: String) = FeatureSearchEntry.search(q).map { it.page }.toSet()

    @Test fun matchesBothLanguages() {
        for (lang in listOf("vi", "en")) {
            L10n.lang = lang
            assertTrue(lang, FeaturePage.GiaoDien in pages("trong suot"))
            assertTrue(lang, FeaturePage.GiaoDien in pages("label transparency"))
            assertTrue(lang, FeaturePage.GoVuot in pages("swipe practice"))
            assertTrue(lang, FeaturePage.Phim in pages("một tay"))
            assertTrue(lang, FeaturePage.Phim in pages("one-handed"))
            assertTrue(lang, FeaturePage.SaoLuu in pages("backup"))
        }
    }

    @Test fun titlesAndGuideFollowLanguage() {
        assertEquals("Tính Năng", AppTab.TinhNang.title)
        assertTrue(FeaturePage.GoVuot.guideUrl.endsWith("/hdsd/?os=android#go-vuot"))
        L10n.lang = "en"
        assertEquals("Features", AppTab.TinhNang.title)
        assertEquals("Swipe typing", FeaturePage.GoVuot.title)
        assertEquals("https://viettelex.com/en/guide/?os=android#swipe", FeaturePage.GoVuot.guideUrl)
        assertEquals("https://viettelex.com/en/guide/?os=android#backup", FeaturePage.SaoLuu.guideUrl)
    }

    /**
     * Kết quả tìm phải trỏ tới đúng chữ trên trang: tên mục tìm = tên dòng cài đặt (lỗi cũ: tìm
     * "Giữ phím ra ký tự đặc biệt" nhưng trang ghi "Giữ phím hàng 2, 3 để ra ký tự đặc biệt").
     */
    @Test fun searchTitlesMatchRows() {
        val dir = listOf(java.io.File("src/main/kotlin"), java.io.File("app/src/main/kotlin")).first { it.isDirectory }
        val src = dir.walkTopDown().filter { it.extension == "kt" }
            .flatMap { it.readLines().asSequence() }.filter { "FeatureSearchEntry(" !in it }.joinToString("\n")
        val combined = setOf("Xuất / nhập file sao lưu")   // một mục cho hai dòng Xuất…/Nhập…
        for (e in FeatureSearchEntry.all) {
            if (e.isPage || e.viTitle in combined) continue
            assertTrue("không có dòng nào tên «${e.viTitle}»", "\"${e.viTitle}\"" in src || "\"${e.viTitle}:" in src)
        }
    }

    /** Màn Plus chạm quyền lợi ⇒ mở trang có cài đặt của nó (Plus không giữ công tắc trùng). */
    @Test fun plusBenefitsLinkToPages() {
        for (f in com.viettelex.keyboard.PlusFeature.entries) {
            if (f == com.viettelex.keyboard.PlusFeature.THANKS_BADGE) continue
            assertTrue(f.name, plusFeaturePage(f) != null)
        }
        assertEquals(FeaturePage.GoTat, plusFeaturePage(com.viettelex.keyboard.PlusFeature.TRANSLATE))
        assertEquals(FeaturePage.GoiY, plusFeaturePage(com.viettelex.keyboard.PlusFeature.SENTENCE_DIACRITICS))
        // Tìm "dịch" / "translate" tới trang có cài đặt Dịch.
        assertTrue(FeaturePage.GoTat in pages("dich tren may"))
        assertTrue(FeaturePage.GoTat in pages("on-device translation"))
    }
}
