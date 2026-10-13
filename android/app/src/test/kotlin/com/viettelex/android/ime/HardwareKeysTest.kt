package com.viettelex.android.ime

import android.view.KeyEvent
import com.viettelex.keyboard.FieldTraits
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.KeyboardData
import com.viettelex.keyboard.KeyboardSession
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.UserLangModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel

/** Telex bằng bàn phím cứng: phân loại KeyEvent + luồng qua session / IcProxy thật / FakeEditor. */
class HardwareKeysTest {
    companion object {
        @BeforeClass @JvmStatic fun assets() {
            val dir = listOf(File("src/main/assets"), File("app/src/main/assets"), File("android/app/src/main/assets"))
                .first { File(it, Keys.ASSET_LEXICON).exists() }
            KeyboardData.install { name ->
                RandomAccessFile(File(dir, name), "r").use { f -> f.channel.map(FileChannel.MapMode.READ_ONLY, 0, f.length()) }
            }
        }
        const val SHIFT = KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        const val CAPS = KeyEvent.META_CAPS_LOCK_ON
        const val CTRL = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        const val ALT = KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        const val META = KeyEvent.META_META_ON or KeyEvent.META_META_LEFT_ON
    }

    private fun code(c: Char) = KeyEvent.KEYCODE_A + (c.lowercaseChar() - 'a')

    // MARK: phân loại

    @Test fun lettersFollowShiftAndCapsLock() {
        assertEquals(HwKey.Letter('v'), HardwareKeys.classify(code('v'), 0))
        assertEquals(HwKey.Letter('V'), HardwareKeys.classify(code('v'), SHIFT))
        assertEquals(HwKey.Letter('V'), HardwareKeys.classify(code('v'), CAPS))
        assertEquals(HwKey.Letter('v'), HardwareKeys.classify(code('v'), CAPS or SHIFT))
        // unicode của layout hệ thống thắng keycode (AZERTY: phím Q ra 'a').
        assertEquals(HwKey.Letter('a'), HardwareKeys.classify(KeyEvent.KEYCODE_Q, 0, 'a'.code))
        assertEquals(HwKey.Letter('A'), HardwareKeys.classify(KeyEvent.KEYCODE_Q, SHIFT, 'A'.code))
    }

    @Test fun modifierCombosPass() {
        for (m in listOf(CTRL, ALT, META, KeyEvent.META_FUNCTION_ON, CTRL or SHIFT)) {
            assertEquals(HwKey.Pass, HardwareKeys.classify(code('c'), m, 'c'.code))
            assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_SPACE, m))   // Ctrl+Space: đổi layout hệ thống
            assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_DEL, m))     // Ctrl+⌫ app tự xoá từ
        }
        assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_TAB, KeyEvent.META_ALT_ON))
    }

    @Test fun modifierKeysThemselvesAreIgnored() {
        for (k in listOf(KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT, KeyEvent.KEYCODE_CTRL_LEFT,
                KeyEvent.KEYCODE_ALT_RIGHT, KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_CAPS_LOCK))
            assertEquals(HwKey.Modifier, HardwareKeys.classify(k, SHIFT))
    }

    @Test fun navigationFunctionAndEscapePass() {
        for (k in listOf(KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_MOVE_HOME,
                KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_F1, KeyEvent.KEYCODE_F12, KeyEvent.KEYCODE_ESCAPE,
                KeyEvent.KEYCODE_FORWARD_DEL, KeyEvent.KEYCODE_INSERT, KeyEvent.KEYCODE_BACK))
            assertEquals(HwKey.Pass, HardwareKeys.classify(k, 0))
        assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_TAB, 0, '\t'.code))
    }

    @Test fun spaceEnterBackspaceDigitsPunctuation() {
        assertEquals(HwKey.Space, HardwareKeys.classify(KeyEvent.KEYCODE_SPACE, 0, ' '.code))
        assertEquals(HwKey.Space, HardwareKeys.classify(KeyEvent.KEYCODE_SPACE, SHIFT, ' '.code))
        assertEquals(HwKey.Enter, HardwareKeys.classify(KeyEvent.KEYCODE_ENTER, 0, '\n'.code))
        assertEquals(HwKey.Enter, HardwareKeys.classify(KeyEvent.KEYCODE_NUMPAD_ENTER, SHIFT))
        assertEquals(HwKey.Backspace, HardwareKeys.classify(KeyEvent.KEYCODE_DEL, 0))
        assertEquals(HwKey.Text("1"), HardwareKeys.classify(KeyEvent.KEYCODE_1, 0, '1'.code))
        assertEquals(HwKey.Text("!"), HardwareKeys.classify(KeyEvent.KEYCODE_1, SHIFT, '!'.code))
        assertEquals(HwKey.Text("."), HardwareKeys.classify(KeyEvent.KEYCODE_PERIOD, 0, '.'.code))
        assertEquals(HwKey.Text("?"), HardwareKeys.classify(KeyEvent.KEYCODE_SLASH, SHIFT, '?'.code))
        assertEquals(HwKey.Text("4", numpad = true), HardwareKeys.classify(KeyEvent.KEYCODE_NUMPAD_4, 0, '4'.code))
        assertEquals(Key.Text("4", numpad = true), HardwareKeys.sessionKey(HwKey.Text("4", numpad = true), true))
        // Numpad khi tắt NumLock (unicode 0) ⇒ điều hướng, để app.
        assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_NUMPAD_4, 0, 0))
    }

    @Test fun deadKeysAndNonAsciiPass() {
        val deadAcute = 0x0301 or android.view.KeyCharacterMap.COMBINING_ACCENT
        assertEquals(HwKey.Pass, HardwareKeys.classify(KeyEvent.KEYCODE_APOSTROPHE, 0, deadAcute))
        assertEquals(HwKey.Pass, HardwareKeys.classify(code('e'), 0, 'é'.code))
    }

    @Test fun sessionKeyRouting() {
        assertEquals(Key.Letter('a'), HardwareKeys.sessionKey(HwKey.Letter('a'), false))
        assertEquals(Key.Space, HardwareKeys.sessionKey(HwKey.Space, false))
        assertEquals(Key.Backspace, HardwareKeys.sessionKey(HwKey.Backspace, true))
        assertNull(HardwareKeys.sessionKey(HwKey.Backspace, false))   // không soạn ⇒ app tự xoá
        assertNull(HardwareKeys.sessionKey(HwKey.Enter, true))        // Enter thật tới app
        assertNull(HardwareKeys.sessionKey(HwKey.Pass, true))
        assertNull(HardwareKeys.sessionKey(HwKey.Modifier, true))
    }

    // MARK: luồng gõ qua session + IcProxy + FakeEditor

    private val tracker = SelectionTracker()

    private inner class Rig(initial: String = "", settings: KeyboardSettings = KeyboardSettings()) {
        val ed = FakeEditor(initial)
        val p = IcProxy({ ed }, tracker).also { tracker.reset(ed.selStart, ed.selEnd); it.startInput(initial, true) }
        val s = KeyboardSession(UserLangModel(), null) { 0L }.also { it.startInput(settings, FieldTraits()) }
        /** Mô phỏng VietTelexIME.onHardwareKeyDown; trả true = nuốt (app không nhận phím). */
        fun key(keyCode: Int, meta: Int = 0, unicode: Int = 0): Boolean {
            val k = HardwareKeys.classify(keyCode, meta, unicode)
            when (k) {
                HwKey.Pass -> { if (s.bridge.isComposing) s.externalSelectionChange(); return false }
                HwKey.Enter -> { p.begin(); try { s.commitComposing(p) } finally { p.end() }; return false }
                else -> {}
            }
            val sk = HardwareKeys.sessionKey(k, s.bridge.isComposing) ?: return false
            p.begin(); try { s.handle(sk, p) } finally { p.end() }
            // Edit của chính mình KHÔNG được coi là đổi từ ngoài.
            assertFalse("tracker coi edit của mình là ngoài", tracker.onUpdate(ed.selStart, ed.selEnd))
            return true
        }
        fun type(text: String, meta: Int = 0) {
            for (c in text) when (c) {
                ' ' -> assertTrue(key(KeyEvent.KEYCODE_SPACE, meta))
                in '0'..'9' -> assertTrue(key(KeyEvent.KEYCODE_0 + (c - '0'), meta, c.code))
                else -> assertTrue(key(code(c), meta))
            }
        }
    }

    @Test fun vieetjSpaceBecomesViet() {
        val r = Rig()
        r.type("vieetj ")
        assertEquals("việt ", r.ed.text)
        assertTrue(r.ed.keys.isEmpty())                        // commitText, không key event
    }

    @Test fun shiftAndCapsLockGiveUppercase() {
        val r = Rig()
        assertTrue(r.key(code('v'), SHIFT))
        r.type("ieetj ")
        assertEquals("Việt ", r.ed.text)
        r.type("nam", CAPS)
        assertEquals("Việt NAM", r.ed.text)
    }

    @Test fun ctrlCIsNotSwallowedAndForgetsWord() {
        val r = Rig()
        r.type("vie")
        assertFalse(r.key(code('c'), CTRL, 'c'.code))           // app nhận Ctrl+C
        assertEquals("vie", r.ed.text)
        assertFalse(r.s.bridge.isComposing)
        assertFalse(r.key(KeyEvent.KEYCODE_CTRL_LEFT, CTRL))    // chính phím Ctrl: không nuốt
    }

    @Test fun modifierKeyDownKeepsComposition() {
        val r = Rig()
        r.type("vie")
        assertFalse(r.key(KeyEvent.KEYCODE_SHIFT_LEFT, SHIFT))  // nhấn Shift giữa từ không cắt từ
        assertTrue(r.s.bridge.isComposing)
        r.type("etj")
        assertEquals("việt", r.ed.text)
    }

    @Test fun backspaceWhileComposingGoesToEngineElsePassesToApp() {
        val r = Rig()
        r.type("vieetj")
        assertEquals("việt", r.ed.text)
        assertTrue(r.key(KeyEvent.KEYCODE_DEL))
        assertEquals("việ", r.ed.text)
        r.type(" ")
        assertFalse(r.key(KeyEvent.KEYCODE_DEL))                // không soạn ⇒ app tự xoá
    }

    @Test fun punctuationIsBoundaryAndEnterCommitsThenPasses() {
        val r = Rig()
        r.type("dduwowcj")
        assertTrue(r.key(KeyEvent.KEYCODE_COMMA, 0, ','.code))
        assertEquals("được,", r.ed.text)
        r.type(" google")
        assertFalse(r.key(KeyEvent.KEYCODE_ENTER, 0, '\n'.code)) // Enter thật tới app
        assertFalse(r.s.bridge.isComposing)
        assertEquals("được, google", r.ed.text)
    }

    @Test fun vniDigitsOnHardwareKeyboard() {
        val r = Rig(settings = KeyboardSettings(vniMode = true))
        r.type("tie6ng1 vie6t5 ")
        assertEquals("tiếng việt ", r.ed.text)
        r.type("2026 ")                                          // ngoài từ: số
        assertEquals("tiếng việt 2026 ", r.ed.text)
        // Telex: số trên phím cứng vẫn là ranh giới
        val t = Rig()
        t.type("vieetj1")
        assertEquals("việt1", t.ed.text)
        assertFalse(t.s.bridge.isComposing)
    }

    // #124: số bàn phím số (numpad) không bao giờ bỏ dấu VNI (như UniKey) — chốt từ rồi chèn
    // số; hàng số trên vẫn bỏ dấu.
    @Test fun vniNumpadDigitsAreBoundaries() {
        val r = Rig(settings = KeyboardSettings(vniMode = true))
        r.type("a")
        assertTrue(r.key(KeyEvent.KEYCODE_NUMPAD_1, 0, '1'.code))
        assertFalse(r.s.bridge.isComposing)
        r.type("a1 ")
        assertTrue(r.key(KeyEvent.KEYCODE_NUMPAD_0, 0, '0'.code))
        assertEquals("a1á 0", r.ed.text)
    }
}
