package com.viettelex.android.shared

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * RAM-AUDIT #5: app cài đặt ở process ":settings", bàn phím ở process chính; prefs đồng bộ
 * bằng broadcast (gom key) + mốc file (lưới an toàn).
 */
class PrefSyncTest {
    @Test fun pendingKeysCoalesce() {
        val p = PendingKeys()
        assertTrue(p.add("a"))          // key đầu ⇒ hẹn một lượt phát
        assertFalse(p.add("b"))
        assertFalse(p.add("a"))
        assertEquals(listOf("a", "b"), p.drain())
        assertEquals(emptyList<String>(), p.drain())
        assertTrue(p.add("c"))          // sau khi phát ⇒ lượt mới
    }

    @Test fun diskStampDetectsExternalWrites() {
        var stat = 1L to 10L
        val d = DiskStamp { stat }
        assertFalse(d.changed())        // lần đầu chỉ ghi nhận
        assertFalse(d.changed())
        stat = 2L to 10L                // process cài đặt ghi (mtime đổi)
        assertTrue(d.changed())
        assertFalse(d.changed())
        stat = 2L to 11L                // cùng mtime (độ phân giải thô) nhưng cỡ đổi
        assertTrue(d.changed())
    }

    private fun manifest(): org.w3c.dom.Element {
        val f = listOf("src/main", "app/src/main").map { File(it, "AndroidManifest.xml") }.first { it.exists() }
        return DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(f).documentElement
    }

    private fun attr(e: org.w3c.dom.Element, name: String): String? =
        e.getAttributeNS("http://schemas.android.com/apk/res/android", name).takeIf { it.isNotEmpty() }

    /** IME ở process mặc định; app cài đặt + FileProvider (Luyện vuốt) ở ":settings". */
    @Test fun manifestProcesses() {
        val app = manifest().getElementsByTagName("application").item(0) as org.w3c.dom.Element
        fun one(tag: String) = app.getElementsByTagName(tag).item(0) as org.w3c.dom.Element
        assertEquals(":settings", attr(one("activity"), "process"))
        assertEquals(":settings", attr(one("provider"), "process"))
        assertNull("bàn phím ở process chính", attr(one("service"), "process"))
        // Activity của app + activity thư viện mở từ app (Billing, Play Core, GMS) đều ở ":settings".
        val acts = app.getElementsByTagName("activity")
        for (i in 0 until acts.length) {
            val a = acts.item(i) as org.w3c.dom.Element
            assertEquals(attr(a, "name"), ":settings", attr(a, "process"))
        }
        assertTrue(acts.length >= 3)
    }
}
