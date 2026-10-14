package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** Translator ML Kit giữ ~30 s theo cặp ngôn ngữ (trước: tạo + đóng mỗi lượt dịch). */
class KeepAliveTests {
    private val main = ImmediateMainThread()
    private var created = 0
    private val closed = ArrayList<String>()
    private val cache = KeepAlive<String, String>(30_000, main, { created++; "$it#$created" }, { closed += it })

    @Test fun reusesWithinTtlThenCloses() {
        val a = cache.acquire("vi-en")
        cache.release("vi-en", a)
        assertEquals(1, main.pendingCount)
        val b = cache.acquire("vi-en")              // dịch câu kế trước khi hết hạn ⇒ cùng client
        assertSame(a, b)
        assertEquals(1, created)
        assertEquals(0, main.pendingCount)          // hẹn giờ đóng bị huỷ
        cache.release("vi-en", b)
        main.runPending()                           // hết hạn ⇒ đóng
        assertEquals(listOf("vi-en#1"), closed)
        assertEquals(0, cache.size)
        cache.acquire("vi-en")
        assertEquals(2, created)                    // sau khi đóng ⇒ tạo mới
    }

    @Test fun inUseNeverClosedAndDoubleReleaseIgnored() {
        val a = cache.acquire("vi-en")
        val b = cache.acquire("vi-en")
        cache.release("vi-en", a)
        assertEquals(0, main.pendingCount)          // còn một người dùng
        cache.trim()
        assertEquals(emptyList<String>(), closed)
        cache.release("vi-en", b)
        cache.release("vi-en", b)                   // nhả thừa: bỏ qua
        assertEquals(1, main.pendingCount)
        cache.trim()                                // đóng ngay, huỷ hẹn giờ
        assertEquals(listOf("vi-en#1"), closed)
        assertEquals(0, main.pendingCount)
    }

    @Test fun pairsAreSeparate() {
        val a = cache.acquire("vi-en"); val b = cache.acquire("en-vi")
        cache.release("vi-en", a); cache.release("en-vi", b)
        assertEquals(2, cache.size)
        main.runPending()
        assertEquals(setOf("vi-en#1", "en-vi#2"), closed.toSet())
    }
}
