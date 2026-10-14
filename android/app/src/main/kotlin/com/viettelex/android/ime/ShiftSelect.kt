package com.viettelex.android.ime

/**
 * Giữ ⇧ + kéo phím cách (trackpad) ⇒ MỞ RỘNG vùng chọn thay vì dời con trỏ (kèm "Vuốt phím để
 * sao chép/dán"). Neo = đầu vùng chọn lúc bắt đầu kéo (không chọn ⇒ con trỏ); đầu kia (focus) đi
 * theo từng grapheme; IME gọi InputConnection.setSelection(anchor, focus) (anchor > focus hợp lệ
 * — vùng chọn ngược).
 *
 * Văn bản quanh vùng chọn đọc MỘT lần lúc bắt đầu ([begin]): window = trước + đang chọn + sau,
 * offset tuyệt đối [windowStart]. Focus không đi quá mép window (đầu/cuối ô, hoặc giới hạn đọc).
 *
 * THUẦN — pinned by ShiftSelectTest.
 */
class ShiftSelect private constructor(
    private val window: String,
    private val windowStart: Int,
    val anchor: Int,
    focus: Int,
) {
    var focus = focus
        private set

    val start: Int get() = minOf(anchor, focus)
    val end: Int get() = maxOf(anchor, focus)

    /** Dời focus [delta] grapheme (âm = trái). Trả focus mới, null nếu không đổi (chạm mép). */
    fun move(delta: Int): Int? {
        if (delta == 0) return null
        val rel = focus - windowStart
        val units = if (delta < 0) -Graphemes.unitsBack(window.substring(0, rel), -delta)
                    else Graphemes.unitsForward(window.substring(rel), delta)
        if (units == 0) return null
        focus += units
        return focus
    }

    companion object {
        /**
         * [selStart]..[selEnd] (tuyệt đối, UTF-16; bằng nhau = con trỏ), [before] = chữ trước
         * selStart, [selected] = chữ đang chọn, [after] = chữ sau selEnd. null nếu số liệu lệch
         * (vùng chọn đọc về khác độ dài, vị trí âm) — IME dùng Shift+mũi tên thay thế.
         */
        fun begin(selStart: Int, selEnd: Int, before: String, selected: String, after: String): ShiftSelect? {
            if (selStart < 0 || selEnd < selStart || before.length > selStart) return null
            if (selected.length != selEnd - selStart) return null
            return ShiftSelect(before + selected + after, selStart - before.length, selStart, selEnd)
        }
    }
}
