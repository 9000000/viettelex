package com.viettelex.android.ime

import android.content.ComponentCallbacks2
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * RAM-AUDIT #3: UI_HIDDEN tới mỗi lần bàn phím ẩn — trước đây nhả FUTO ở đó ⇒ giải fp16 lại mỗi
 * lần hiện (~3.4 MB cấp phát/lần). Giờ chỉ nhả khi thiếu RAM thật; ẩn lâu do hẹn giờ lo.
 */
@Suppress("DEPRECATION")
class ImeTrimTest {
    @Test fun uiHiddenKeepsFuto() {
        assertFalse(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN))
        assertFalse(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE))
        assertFalse(ImeTrim.releaseIdle(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN, inputShown = false))
    }

    @Test fun realPressureReleases() {
        assertTrue(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW))
        assertTrue(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL))
        assertTrue(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_BACKGROUND))
        assertTrue(ImeTrim.releaseFuto(ComponentCallbacks2.TRIM_MEMORY_COMPLETE))
        assertTrue(ImeTrim.releaseIdle(ComponentCallbacks2.TRIM_MEMORY_BACKGROUND, inputShown = false))
        assertFalse("đang gõ: không nhả dữ liệu đang dùng", ImeTrim.releaseIdle(ComponentCallbacks2.TRIM_MEMORY_COMPLETE, inputShown = true))
    }

    /** Hẹn giờ ẩn 3 phút: 45 s cũ ⇒ parse lại enlexicon + FUTO gần như mỗi lần mở lại khi chat ngắt quãng. */
    @Test fun idleReleaseIsMinutesNotSeconds() {
        assertTrue(ImeTrim.IDLE_RELEASE_MS in 180_000L..300_000L)
        assertTrue(VietTelexIME.IDLE_RELEASE_MS == ImeTrim.IDLE_RELEASE_MS)
    }
}
