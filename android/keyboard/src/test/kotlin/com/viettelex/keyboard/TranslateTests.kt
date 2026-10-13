package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dịch trên máy — phần thuần: chiều dịch, chọn đích, điều phối client (máy dịch giả). */
class TranslateTests {
    private fun plan(text: String, target: String?) = TranslateDirection.plan(text, target)
    private fun p(from: String, to: String) = TranslateDirection.Plan(from, to)

    @Test fun englishTargetDefault() {
        assertEquals(p("vi", "en"), plan("hôm nay trời đẹp", "en"))
        assertEquals(p("vi", "en"), plan("con mèo", "en"))               // è (Latin-1) đủ khi đích là English
        assertEquals(p("en", "vi"), plan("the weather is nice today", "en"))
        assertEquals(p("vi", "en"), plan("hôm nay", null))                // chưa chọn ⇒ English
        assertEquals(p("vi", "en"), plan("Đi", "vi"))                     // đích "vi" không hợp lệ ⇒ English
    }

    @Test fun japaneseTargetRoundTrip() {
        assertEquals(p("vi", "ja"), plan("xin chào bạn", "ja"))
        assertEquals(p("ja", "vi"), plan("こんにちは、元気ですか", "ja"))
        assertEquals(p("ja", "vi"), plan("東京", "ja"))                    // Hán thuần: coi là đích
        assertEquals(p("vi", "ja"), plan("hom nay troi dep", "ja"))       // Latin không dấu ⇒ coi là tiếng Việt
    }

    @Test fun otherScripts() {
        assertEquals(p("ko", "vi"), plan("안녕하세요", "ko"))
        assertEquals(p("vi", "ko"), plan("cảm ơn", "ko"))
        assertEquals(p("ru", "vi"), plan("Привет, как дела?", "ru"))
        assertEquals(p("zh", "vi"), plan("你好世界", "zh"))
        assertEquals(p("vi", "zh"), plan("ありがとう", "zh"))               // kana ≠ tiếng Trung
        assertEquals(p("th", "vi"), plan("สวัสดี", "th"))
    }

    @Test fun latinTargetWithAccentsNeedsVietnameseOnlyLetters() {
        assertEquals(p("fr", "vi"), plan("le café est très bon", "fr"))
        assertEquals(p("vi", "fr"), plan("cà phê rất ngon", "fr"))         // ấ chỉ tiếng Việt có
        assertEquals(p("vi", "es"), plan("đi đâu", "es"))
        assertEquals(p("es", "vi"), plan("¿dónde está?", "es"))
    }

    @Test fun nfdInputDetected() {
        val nfd = java.text.Normalizer.normalize("trời ơi", java.text.Normalizer.Form.NFD)
        assertEquals(p("vi", "de"), plan(nfd, "de"))
    }

    @Test fun nothingToTranslate() {
        assertNull(plan("123 !!", "en"))
        assertNull(plan("", "ja"))
    }

    @Test fun targets() {
        assertEquals(59, TranslateLangs.ALL.size)
        assertFalse(TranslateLangs.VI in TranslateLangs.TARGETS)
        assertEquals("en", TranslateLangs.normalizeTarget("xx"))
        assertEquals("ja", TranslateLangs.normalizeTarget("ja"))
        val order = TranslateLangs.pickerOrder("vi")
        assertEquals("en", order.first())
        assertEquals(TranslateLangs.TARGETS, order.toSet())
        assertEquals(order.size, order.toSet().size)
        for (code in TranslateLangs.TARGETS) assertTrue(code, TranslateLangs.displayName(code, "en").isNotBlank())
        assertEquals("Japanese", TranslateLangs.displayName("ja", "en"))
        for (code in TranslateLangs.ALL) assertTrue(code, TranslateLangs.scriptsOf(code).isNotEmpty())
    }

    @Test fun backupCarriesTarget() {
        val kind = BackupSettings.byKey.getValue(Keys.TRANSLATE_TARGET).kind as SettingKind.Choice
        assertEquals("en", kind.default)
        assertTrue("ja" in kind.allowed); assertFalse("vi" in kind.allowed)
    }

    @Test fun plusFeature() {
        assertTrue(PlusFeature.TRANSLATE.howTo.isNotBlank())
        PlusGate.paywallEnabled = false
        try { assertTrue(PlusGate.isUnlocked(PlusFeature.TRANSLATE)) } finally { PlusGate.paywallEnabled = PlusConfig.PAYWALL_ENABLED }
    }

    // --- controller ---

    private class FakeEngine(val plan: TranslateDirection.Plan) : TranslateEngine {
        var pending: ((TranslateResult) -> Unit)? = null
        var closed = false
        override fun translate(text: String, onDone: (TranslateResult) -> Unit) { pending = onDone }
        override fun close() { closed = true }
    }

    private class FakeFactory : TranslateEngineFactory {
        val made = ArrayList<FakeEngine>()
        override fun create(plan: TranslateDirection.Plan) = FakeEngine(plan).also { made += it }
    }

    private fun job(text: String, target: String = "en") =
        TranslateJob(TextTools.Source(text, false), TranslateDirection.plan(text, target)!!)

    @Test fun controllerLazyAndClosesAfterUse() {
        val f = FakeFactory()
        val c = TranslateController(f)
        assertTrue(f.made.isEmpty())                                // không client nào tới khi chạm
        val got = ArrayList<TranslateResult>()
        c.start(job("xin chào")) { _, r -> got += r }
        assertEquals(1, f.made.size); assertEquals(p("vi", "en"), f.made[0].plan)
        assertTrue(c.busy)
        f.made[0].pending!!(TranslateResult.Ok("hello"))
        assertEquals(listOf<TranslateResult>(TranslateResult.Ok("hello")), got)
        assertTrue(f.made[0].closed); assertFalse(c.busy)
    }

    @Test fun cancelDropsStaleResult() {
        val f = FakeFactory()
        val c = TranslateController(f)
        val got = ArrayList<TranslateResult>()
        c.start(job("xin chào")) { _, r -> got += r }
        c.cancel()
        assertTrue(f.made[0].closed)
        f.made[0].pending!!(TranslateResult.Ok("hello"))           // về muộn ⇒ bỏ
        assertTrue(got.isEmpty())
        // Chạm lại khi lượt cũ chưa xong: lượt cũ bị đóng, chỉ lượt mới ghi.
        c.start(job("một")) { _, r -> got += r }
        c.start(job("hai")) { _, r -> got += r }
        assertTrue(f.made[1].closed)
        f.made[1].pending!!(TranslateResult.Ok("one"))
        f.made[2].pending!!(TranslateResult.Ok("two"))
        assertEquals(listOf<TranslateResult>(TranslateResult.Ok("two")), got)
    }
}
