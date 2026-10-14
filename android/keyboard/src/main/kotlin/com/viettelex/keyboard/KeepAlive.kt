package com.viettelex.keyboard

/**
 * Giữ một tài nguyên đắt theo khoá (Translator ML Kit theo cặp ngôn ngữ) thêm [ttlMs] sau lần
 * nhả cuối rồi mới đóng — dịch liên tiếp vài câu không dựng/nạp lại model mỗi lần. Chỉ dùng trên
 * MỘT luồng ([main]); không ai dùng ⇒ không giữ gì quá [ttlMs].
 */
class KeepAlive<K : Any, V : Any>(
    private val ttlMs: Long,
    private val main: MainThread,
    private val create: (K) -> V,
    private val close: (V) -> Unit,
) {
    private class Entry<V>(val value: V) { var users = 0; var timer: Cancellable? = null }
    private val map = HashMap<K, Entry<V>>()

    /** Số tài nguyên đang mở (test). */
    val size: Int get() = map.size

    fun acquire(key: K): V {
        val e = map[key] ?: Entry(create(key)).also { map[key] = it }
        e.timer?.cancel(); e.timer = null
        e.users++
        return e.value
    }

    /** Nhả [value] lấy bằng [acquire]; người dùng cuối nhả ⇒ đóng sau [ttlMs] nếu không ai lấy lại. */
    fun release(key: K, value: V) {
        val e = map[key] ?: return
        if (e.value !== value || e.users == 0) return
        if (--e.users > 0) return
        e.timer = main.postDelayed(ttlMs, Runnable {
            if (map[key] === e && e.users == 0) { map.remove(key); close(e.value) }
        })
    }

    /** Đóng ngay mọi thứ không ai đang dùng. */
    fun trim() {
        val it = map.entries.iterator()
        while (it.hasNext()) {
            val e = it.next().value
            if (e.users == 0) { e.timer?.cancel(); it.remove(); close(e.value) }
        }
    }
}
