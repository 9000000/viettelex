package com.viettelex.android.ime

import android.view.KeyCharacterMap
import android.view.KeyEvent
import com.viettelex.keyboard.Key

/** Phím cứng sau khi phân loại — IME quyết định tiêu thụ hay để app xử lý. */
sealed class HwKey {
    /** Chữ ASCII a–z/A–Z (đã theo Shift/CapsLock) → engine Telex như phím chạm. */
    data class Letter(val ch: Char) : HwKey()
    /** Số / dấu câu in được → ranh giới từ (auto-restore) rồi chèn. [numpad]: số của bàn
     *  phím số — không mang dấu VNI (#124). */
    data class Text(val text: String, val numpad: Boolean = false) : HwKey()
    object Space : HwKey()
    /** Chốt từ đang soạn rồi để Enter THẬT đi tới app (Shift+Enter, "Enter để gửi"…). */
    object Enter : HwKey()
    /** ⌫: đang soạn ⇒ engine; không soạn ⇒ app tự xoá. */
    object Backspace : HwKey()
    /** Bản thân phím Shift/Ctrl/Alt/Meta/Fn/CapsLock…: không đụng, KHÔNG quên từ. */
    object Modifier : HwKey()
    /** Tổ hợp có Ctrl/Alt/Meta/Fn, điều hướng, F-key, Esc, Tab, phím chết…: để app xử lý, quên từ. */
    object Pass : HwKey()
}

/**
 * Phân loại KeyEvent bàn phím cứng. THUẦN (hằng KeyEvent inline lúc biên dịch) ⇒ test JVM.
 *
 * [unicode] = `event.getUnicodeChar(metaState)` (theo layout bàn phím của hệ thống, đã tính
 * Shift/CapsLock); 0 ⇒ suy chữ từ keycode A–Z (Shift XOR CapsLock).
 */
object HardwareKeys {
    /** Có một trong các modifier này ⇒ phím tắt của app/hệ thống, không bao giờ nuốt. */
    const val BLOCKING_META = KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK or
        KeyEvent.META_META_MASK or KeyEvent.META_FUNCTION_ON or KeyEvent.META_SYM_ON

    fun classify(keyCode: Int, metaState: Int, unicode: Int = 0): HwKey {
        if (isModifierKey(keyCode)) return HwKey.Modifier
        if (metaState and BLOCKING_META != 0) return HwKey.Pass
        when (keyCode) {
            KeyEvent.KEYCODE_DEL -> return HwKey.Backspace
            KeyEvent.KEYCODE_SPACE -> return HwKey.Space
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> return HwKey.Enter
        }
        // Phím chết (dấu ghép của layout như US-International): để hệ thống ghép.
        if (unicode and KeyCharacterMap.COMBINING_ACCENT != 0) return HwKey.Pass
        if (unicode == 0) {
            if (keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
                val shift = metaState and KeyEvent.META_SHIFT_ON != 0
                val caps = metaState and KeyEvent.META_CAPS_LOCK_ON != 0
                val c = 'a' + (keyCode - KeyEvent.KEYCODE_A)
                return HwKey.Letter(if (shift != caps) c.uppercaseChar() else c)
            }
            return HwKey.Pass
        }
        val ch = unicode.toChar()
        if (unicode > 0x7E || unicode < 0x20) return HwKey.Pass   // Tab, ký tự điều khiển, chữ ngoài ASCII (layout khác)
        if (ch in 'a'..'z' || ch in 'A'..'Z') return HwKey.Letter(ch)
        // số, dấu câu, ký hiệu ASCII in được; số numpad đánh dấu riêng (VNI: không bỏ dấu, #124)
        return HwKey.Text(ch.toString(), numpad = keyCode in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9)
    }

    /**
     * Phím session sẽ xử lý (IME trả true = nuốt), hoặc null = để app nhận KeyEvent.
     * ⌫ chỉ nuốt khi đang soạn (không soạn ⇒ app tự xoá, như bàn phím cứng thường).
     */
    fun sessionKey(k: HwKey, composing: Boolean): Key? = when (k) {
        is HwKey.Letter -> Key.Letter(k.ch)
        is HwKey.Text -> Key.Text(k.text, numpad = k.numpad)
        HwKey.Space -> Key.Space
        HwKey.Backspace -> if (composing) Key.Backspace else null
        HwKey.Enter, HwKey.Modifier, HwKey.Pass -> null
    }

    /** ≈ KeyEvent.isModifierKey (+ khoá) — hàm hệ thống không chạy được trên JVM test. */
    fun isModifierKey(keyCode: Int): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT,
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT,
        KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT,
        KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT,
        KeyEvent.KEYCODE_SYM, KeyEvent.KEYCODE_FUNCTION, KeyEvent.KEYCODE_NUM,
        KeyEvent.KEYCODE_CAPS_LOCK, KeyEvent.KEYCODE_NUM_LOCK, KeyEvent.KEYCODE_SCROLL_LOCK -> true
        else -> false
    }
}
