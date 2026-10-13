package com.viettelex.keyboard

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PlusGateTests {
    private val store = mutableMapOf<String, Any?>()

    @Before fun setUp() {
        store.clear()
        PlusGate.install({ store[it] }, debugBuild = false)
        PlusGate.paywallEnabled = true
    }

    @After fun tearDown() {
        PlusGate.install({ null }, debugBuild = false)
        PlusGate.paywallEnabled = PlusConfig.PAYWALL_ENABLED
    }

    @Test fun lockedWhenNotPurchased() {
        PlusFeature.entries.forEach { assertFalse(it.name, PlusGate.isUnlocked(it)) }
        assertEquals(PlusConfig.FREE_PINNED_CLIP_LIMIT, PlusGate.pinnedClipLimit)
    }

    @Test fun purchasedFlagUnlocksAll() {
        store[Keys.PLUS_UNLOCKED] = true
        PlusFeature.entries.forEach { assertTrue(it.name, PlusGate.isUnlocked(it)) }
        assertNull(PlusGate.pinnedClipLimit)
    }

    @Test fun wrongTypeIsIgnored() {
        store[Keys.PLUS_UNLOCKED] = "true"
        assertFalse(PlusGate.isPlus)
    }

    @Test fun paywallOffOpensAllButBadge() {
        PlusGate.paywallEnabled = false
        assertTrue(PlusGate.isUnlocked(PlusFeature.TEXT_TOOLS))
        assertTrue(PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES))
        assertFalse(PlusGate.isUnlocked(PlusFeature.THANKS_BADGE))
    }

    @Test fun debugOverrideOnlyInDebugBuild() {
        store[Keys.PLUS_DEBUG_OVERRIDE] = true
        assertFalse(PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS))
        PlusGate.install({ store[it] }, debugBuild = true)
        assertTrue(PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS))
        assertFalse(PlusGate.purchased)
    }

    @Test fun notInstalledMeansLocked() {
        PlusGate.install({ null }, debugBuild = true)
        assertFalse(PlusGate.isPlus)
    }

    @Test fun configDefaults() {
        assertTrue("bản 1.2 bán Plus (27/09)", PlusConfig.PAYWALL_ENABLED)
        assertEquals("plus", PlusConfig.PLUS_PRODUCT_ID)
        assertEquals(4, PlusConfig.ALL_PRODUCT_IDS.toSet().size)
    }

    /** Màn Plus: mọi quyền lợi có dòng "Cách dùng"; Thêm dấu cả câu có công tắc đúng key IME đọc. */
    @Test fun everyFeatureHasHowToLine() {
        for (f in PlusFeature.entries) assertTrue("$f thiếu cách dùng", f.howTo.isNotBlank())
        assertTrue(PlusFeature.SENTENCE_DIACRITICS.howTo.contains("Thêm dấu"))
        assertTrue(PlusFeature.TEXT_TOOLS.howTo.contains("☰"))
        assertEquals(Keys.ADD_TONES_CHIP, PlusFeature.SENTENCE_DIACRITICS.settingKey)
        assertNull(PlusFeature.CLOUD_SYNC.settingKey)
    }

    /** Công tắc "Công cụ văn bản": mặc định BẬT; hiện thật = Plus mở && công tắc bật && ô không mật khẩu. */
    @Test fun textToolsSwitch() {
        assertEquals(Keys.TEXT_TOOLS_ENABLED, PlusFeature.TEXT_TOOLS.settingKey)
        assertEquals("textToolsEnabled", Keys.TEXT_TOOLS_ENABLED)        // cùng key iOS
        assertTrue(PlusFeature.TEXT_TOOLS.settingDefault)
        assertFalse(PlusFeature.SENTENCE_DIACRITICS.settingDefault)
        assertTrue(KeyboardSettings().textToolsEnabled)
        assertTrue(KeyboardSettings.load { null }.textToolsEnabled)
        assertFalse(KeyboardSettings.load { if (it == Keys.TEXT_TOOLS_ENABLED) false else null }.textToolsEnabled)
        val on = KeyboardSettings()
        assertTrue(on.textToolsActive(unlocked = true, secureField = false))
        assertFalse(on.textToolsActive(unlocked = false, secureField = false))
        assertFalse(on.textToolsActive(unlocked = true, secureField = true))
        val off = KeyboardSettings(textToolsEnabled = false)
        assertFalse(off.textToolsActive(unlocked = true, secureField = false))
        assertFalse(off.textToolsActive(unlocked = false, secureField = false))
    }
}
