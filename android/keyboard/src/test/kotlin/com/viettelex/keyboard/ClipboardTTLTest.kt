package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Giữ lịch sử clipboard" 1 giờ / 24 giờ / 7 ngày — cùng khoá + id iOS ClipboardTTLTests. */
class ClipboardTTLTest {
    private val hour = 3_600_000L
    private val day = 24 * hour

    @Test fun parse() {
        assertEquals("clipboardTTL", Keys.CLIPBOARD_TTL)
        assertEquals(hour, ClipboardTTL.of("1h").ms)
        assertEquals(day, ClipboardTTL.of("24h").ms)
        assertEquals(7 * day, ClipboardTTL.of("7d").ms)
        assertEquals(ClipboardTTL.HOUR_1, ClipboardTTL.of(null))     // chưa đặt → 1 giờ
        assertEquals(ClipboardTTL.HOUR_1, ClipboardTTL.of("30d"))    // lạ → 1 giờ
        assertEquals(ClipboardTTL.HOUR_1, ClipboardTTL.of(true))     // sai kiểu → 1 giờ
        assertEquals(listOf("1h", "24h", "7d"), ClipboardTTL.IDS.toList())
    }

    @Test fun settingsLoad() {
        assertEquals(ClipboardTTL.HOUR_1, KeyboardSettings.load { null }.clipboardTtl)
        assertEquals(ClipboardTTL.DAYS_7, KeyboardSettings.load { if (it == Keys.CLIPBOARD_TTL) "7d" else null }.clipboardTtl)
    }

    @Test fun prune24hThen1h() {
        val h = ClipboardHistory(ttlMs = ClipboardTTL.HOURS_24.ms)
        h.add("hai giờ trước", 0)
        assertEquals(listOf("hai giờ trước"), h.items(2 * hour).map { it.text })   // 24h: giữ
        h.ttlMs = ClipboardTTL.HOUR_1.ms                                            // rút ngắn → prune kế tiếp xoá
        assertEquals(emptyList<String>(), h.items(2 * hour).map { it.text })
    }

    @Test fun prune7dSensitivePinned() {
        val h = ClipboardHistory(ttlMs = ClipboardTTL.DAYS_7.ms)
        h.add("tám ngày", 0)
        h.add("ghim", 0); assertTrue(h.togglePin("ghim"))
        h.add("sáu ngày", 2 * day)
        h.add("Xk9#mP2qL", 8 * day - 200_000)    // giống mật khẩu
        // 8 ngày → xoá; bí mật quá 2 phút → xoá dù 7 ngày; ghim giữ.
        assertEquals(listOf("ghim", "sáu ngày"), h.items(8 * day).map { it.text })
    }

    @Test fun deserializeKeepsTtl() {
        val src = ClipboardHistory(ttlMs = ClipboardTTL.HOURS_24.ms).apply { add("abc", 0) }
        val h = ClipboardHistory.deserialize(src.serialize(), ttlMs = ClipboardTTL.HOURS_24.ms)
        assertEquals(ClipboardTTL.HOURS_24.ms, h.ttlMs)
        assertEquals(listOf("abc"), h.items(23 * hour).map { it.text })
        assertEquals(ClipboardTTL.HOUR_1.ms, ClipboardHistory.deserialize(src.serialize()).ttlMs)   // mặc định 1 giờ
    }

    @Test fun backupSpecIncludesKey() {
        val kind = BackupSettings.byKey[Keys.CLIPBOARD_TTL]?.kind as? SettingKind.Choice
            ?: error("clipboardTTL phải có trong BackupSettings (Choice)")
        assertEquals("1h", kind.default)
        assertEquals(setOf("1h", "24h", "7d"), kind.allowed)
        // Giá trị lạ trong prefs ⇒ snapshot ghi mặc định.
        assertEquals("1h", BackupPrefs.settings { if (it == Keys.CLIPBOARD_TTL) "1y" else null }[Keys.CLIPBOARD_TTL])
        assertEquals("7d", BackupPrefs.settings { if (it == Keys.CLIPBOARD_TTL) "7d" else null }[Keys.CLIPBOARD_TTL])
    }
}
