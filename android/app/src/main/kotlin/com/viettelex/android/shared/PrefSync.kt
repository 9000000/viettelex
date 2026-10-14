package com.viettelex.android.shared

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import androidx.core.content.ContextCompat
import com.viettelex.keyboard.Keys
import java.io.File

/**
 * Đồng bộ prefs [Keys.PREFS] giữa process bàn phím và process cài đặt (":settings", RAM-AUDIT #5).
 *
 * SharedPreferences KHÔNG an toàn đa process: mỗi process giữ một map trong RAM và ghi CẢ map ra
 * file. Cơ chế ở đây:
 *  - [forward]: mỗi process nghe thay đổi CỦA CHÍNH NÓ; gom phím trong [DEBOUNCE_MS], đợi mọi
 *    `apply()` trước đó xuống đĩa (commit rỗng trên luồng nền — cùng hàng đợi ghi) rồi mới phát
 *    broadcast nội bộ gói (không export) kèm danh sách key.
 *  - [listen]: process kia nhận ⇒ [reload] (MODE_MULTI_PROCESS: đọc lại file nếu đổi) ⇒ callback
 *    trên main với các key (IME áp như listener cùng process trước đây).
 *  - [DiskStamp]: lưới an toàn khi lỡ broadcast (process chưa sống / bị đóng băng): IME so mốc
 *    file (mtime + cỡ, 2 stat) mỗi lần hiện bàn phím — đổi ⇒ đọc lại + xoá cache.
 * Chỉ chạy khi prefs đổi — 0 chi phí mỗi phím.
 */
object PrefSync {
    const val ACTION = "com.viettelex.android.PREFS_CHANGED"
    private const val EXTRA_KEYS = "keys"
    private const val EXTRA_PID = "pid"
    const val DEBOUNCE_MS = 60L

    /** Đọc lại file nếu process khác đã ghi (cùng instance SharedPreferences; getter chờ nạp xong). */
    @Suppress("DEPRECATION")
    fun reload(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(Keys.PREFS, Context.MODE_MULTI_PROCESS)

    fun file(ctx: Context): File = File(ctx.applicationInfo.dataDir, "shared_prefs/${Keys.PREFS}.xml")

    // MARK: phát

    private var forwarding: SharedPreferences.OnSharedPreferenceChangeListener? = null
    private val pending = PendingKeys()
    private val io by lazy { Handler(HandlerThread("vt-prefsync").also { it.start() }.looper) }

    /** Một lần mỗi process: thay đổi prefs của process này ⇒ báo process kia. */
    @Synchronized
    fun forward(ctx: Context) {
        if (forwarding != null) return
        val app = ctx.applicationContext
        val sp = VTPrefs.of(app)
        val l = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (pending.add(key ?: return@OnSharedPreferenceChangeListener)) io.postDelayed({ flush(app, sp) }, DEBOUNCE_MS)
        }
        forwarding = l   // giữ mạnh (SharedPreferences chỉ giữ weak)
        sp.registerOnSharedPreferenceChangeListener(l)
    }

    private fun flush(app: Context, sp: SharedPreferences) {
        sp.edit().commit()   // xếp sau mọi apply() đang chờ ⇒ file trên đĩa đã có thay đổi
        val keys = pending.drain()
        if (keys.isEmpty()) return
        app.sendBroadcast(Intent(ACTION).setPackage(app.packageName)
            .putExtra(EXTRA_KEYS, keys.toTypedArray()).putExtra(EXTRA_PID, Process.myPid()))
    }

    // MARK: nhận

    /** Process khác đổi prefs ⇒ [reload] rồi [onChanged] (main thread) với các key đổi. */
    fun listen(ctx: Context, onChanged: (Set<String>) -> Unit): BroadcastReceiver {
        val app = ctx.applicationContext
        val main = Handler(Looper.getMainLooper())
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.getIntExtra(EXTRA_PID, 0) == Process.myPid()) return
                val keys = i.getStringArrayExtra(EXTRA_KEYS)?.toSet() ?: return
                reload(app)
                main.post { onChanged(keys) }
            }
        }
        ContextCompat.registerReceiver(app, r, IntentFilter(ACTION), ContextCompat.RECEIVER_NOT_EXPORTED)
        return r
    }

    fun unlisten(ctx: Context, r: BroadcastReceiver) {
        runCatching { ctx.applicationContext.unregisterReceiver(r) }
    }
}

/** Gom key chờ phát (thread-safe). [add] trả true khi cần hẹn một lượt phát mới. */
class PendingKeys {
    private val keys = LinkedHashSet<String>()
    @Synchronized fun add(key: String): Boolean {
        val first = keys.isEmpty()
        keys.add(key)
        return first
    }
    @Synchronized fun drain(): List<String> = keys.toList().also { keys.clear() }
}

/**
 * Mốc file prefs (mtime + cỡ). [changed] true khi file khác lần xem trước — IME đọc lại prefs và
 * bỏ mọi cache cài đặt (lưới an toàn khi lỡ broadcast). Lần đầu chỉ ghi nhận.
 */
class DiskStamp(private val stat: () -> Pair<Long, Long>) {
    private var last: Pair<Long, Long>? = null
    fun changed(): Boolean {
        val now = stat()
        val prev = last
        last = now
        return prev != null && prev != now
    }
}
