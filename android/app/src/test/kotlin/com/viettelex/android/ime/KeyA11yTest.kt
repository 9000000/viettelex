package com.viettelex.android.ime

import com.viettelex.keyboard.L10n
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** TalkBack: mỗi phím một nhãn đọc được (trước: cả bàn phím importantForAccessibility = NO). */
class KeyA11yTest {
    @After fun reset() { L10n.lang = L10n.DEFAULT }

    private fun d(kind: Int, label: String = "", upper: String = label, insert: String = "", shifted: Boolean = false, ret: String = "return") =
        KeyA11y.describe(kind, label, upper, insert, shifted, ret)

    @Test fun labels() {
        assertEquals("a", d(KeyKind.LETTER, "a", "A"))
        assertEquals("A", d(KeyKind.LETTER, "a", "A", shifted = true))
        assertEquals("Xoá", d(KeyKind.BACKSPACE, "⌫"))
        assertEquals("Dấu cách", d(KeyKind.SPACE))
        assertEquals("Xuống dòng", d(KeyKind.RETURN))
        assertEquals("Tìm", d(KeyKind.RETURN, ret = "Tìm"))
        assertEquals("Số", d(KeyKind.PLANE, "?123", insert = "123"))
        assertEquals("Chữ cái", d(KeyKind.PLANE, "ABC", insert = "ABC"))
        assertEquals(",", d(KeyKind.PUNCT, ",", insert = ","))
        L10n.lang = "en"
        assertEquals("Space", d(KeyKind.SPACE))
        assertEquals("Delete", d(KeyKind.BACKSPACE, "⌫"))
    }

    /** Trợ năng không được thêm việc mỗi phím: helper chỉ gắn một lần, không gọi trong đường chạm. */
    @Test fun noPerKeystrokeWork() {
        val src = listOf(File("src/main/kotlin"), File("app/src/main/kotlin")).first { it.isDirectory }
            .resolve("com/viettelex/android/ime/KeyboardView.kt").readText()
        val touch = src.substringAfter("override fun onTouchEvent(").substringBefore("private fun up(")
        assertTrue("đường chạm không gọi helper trợ năng", "a11y." !in touch)
        assertTrue(src.contains("setAccessibilityDelegate(this, a11y)"))
    }
}
