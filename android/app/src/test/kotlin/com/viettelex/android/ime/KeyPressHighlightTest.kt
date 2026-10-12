package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Phím sẫm khi bấm": máy trạng thái theo ngón (chạm / nhấc / huỷ / vuốt / trôi). */
class KeyPressHighlightTest {
    private fun hl() = KeyPressHighlight(capacity = 4)

    @Test fun downThenUp() {
        val h = hl()
        assertTrue(h.down(0, 10f, 20f, 50f, 70f))
        assertTrue(h.isPressed(0)); assertEquals(1, h.count)
        assertEquals(10f, h.left(0)); assertEquals(70f, h.bottom(0))
        assertTrue(h.up(0))
        assertFalse(h.isPressed(0)); assertEquals(0, h.count)
        // khung giữ lại sau khi nhấc ⇒ invalidate được đúng vùng cũ
        assertEquals(50f, h.right(0))
        assertFalse("nhấc lần 2 không đổi gì", h.up(0))
    }

    /** Huỷ (ACTION_CANCEL) và bắt đầu vuốt đi cùng đường [up]. */
    @Test fun cancelAndSwipeStartClear() {
        val h = hl()
        h.down(1, 0f, 0f, 10f, 10f)
        assertTrue(h.up(1)); assertEquals(0, h.count)
    }

    @Test fun driftWithinSlopKeeps() {
        val h = hl()
        h.down(0, 100f, 100f, 140f, 160f)
        assertFalse(h.drift(0, 120f, 130f, 10f))
        assertFalse(h.drift(0, 95f, 165f, 10f))        // lệch mép nhưng trong slop
        assertTrue(h.isPressed(0))
    }

    @Test fun driftToAnotherKeyClearsOnce() {
        val h = hl()
        h.down(0, 100f, 100f, 140f, 160f)
        assertTrue(h.drift(0, 160f, 130f, 10f))        // sang phím bên phải
        assertFalse(h.isPressed(0)); assertEquals(0, h.count)
        assertFalse("đã bỏ sẫm: quay lại không bật lại", h.drift(0, 120f, 130f, 10f))
        assertFalse(h.isPressed(0))
        assertFalse("nhấc sau khi trôi: không invalidate thừa", h.up(0))
        assertFalse(h.drift(-1, 0f, 0f, 0f))
    }

    @Test fun driftVertical() {
        val h = hl()
        h.down(2, 0f, 100f, 40f, 150f)
        assertTrue(h.drift(2, 20f, 80f, 10f))           // lên hàng trên
    }

    /** Gõ chồng ngón: mỗi ngón một phím, nhấc ngón nào bỏ đúng phím đó. */
    @Test fun multiPointerIndependent() {
        val h = hl()
        h.down(0, 0f, 0f, 10f, 10f)
        h.down(1, 20f, 0f, 30f, 10f)
        assertEquals(2, h.count)
        h.up(0)
        assertFalse(h.isPressed(0)); assertTrue(h.isPressed(1)); assertEquals(1, h.count)
    }

    @Test fun redownSamePointerDoesNotDoubleCount() {
        val h = hl()
        h.down(0, 0f, 0f, 10f, 10f)
        h.down(0, 20f, 0f, 30f, 10f)
        assertEquals(1, h.count); assertEquals(20f, h.left(0))
    }

    @Test fun clearAll() {
        val h = hl()
        assertFalse(h.clearAll())
        h.down(0, 0f, 0f, 1f, 1f); h.down(3, 0f, 0f, 1f, 1f)
        assertTrue(h.clearAll())
        assertEquals(0, h.count); assertFalse(h.isPressed(3))
    }

    @Test fun outOfRangePointerIgnored() {
        val h = hl()
        assertFalse(h.down(4, 0f, 0f, 1f, 1f))
        assertFalse(h.down(-1, 0f, 0f, 1f, 1f))
        assertFalse(h.up(9)); assertFalse(h.isPressed(9))
        assertEquals(0, h.count)
    }

    /**
     * Micro-benchmark đường chạm (JVM): một lượt down + 3 move (trong phím) + up. Chỉ in ns/lượt;
     * ngưỡng rất rộng (bắt hồi quy kiểu cấp phát / vòng lặp lớn). Vẽ thật đo trên máy.
     */
    @Test fun touchPathIsCheap() {
        val h = KeyPressHighlight()
        fun round(n: Int): Long {
            val t0 = System.nanoTime()
            for (i in 0 until n) {
                val pid = i and 3
                h.down(pid, 10f, 20f, 50f, 70f)
                h.drift(pid, 30f, 40f, 10f); h.drift(pid, 31f, 41f, 10f); h.drift(pid, 32f, 42f, 10f)
                h.up(pid)
            }
            return System.nanoTime() - t0
        }
        round(200_000)                                   // JIT
        val n = 1_000_000
        val ns = minOf(round(n), round(n), round(n)).toDouble() / n
        println("KeyPressHighlight down+3×drift+up: %.1f ns/lượt".format(ns))
        assertTrue("$ns ns", ns < 2_000)
    }
}
