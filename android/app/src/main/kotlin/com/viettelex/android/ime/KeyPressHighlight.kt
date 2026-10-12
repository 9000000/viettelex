package com.viettelex.android.ime

/**
 * "Phím sẫm khi bấm" (Keys.KEY_PRESS_HIGHLIGHT, port iOS 803cbd15): trạng thái phím chữ / số /
 * ký hiệu đang đè, theo từng ngón (pointer id). THUẦN — không Android — để unit-test máy trạng
 * thái (chạm / nhấc / huỷ / bắt đầu vuốt / trôi khỏi phím).
 *
 * Mảng cấp sẵn theo [capacity] pointer: đường chạm KHÔNG cấp phát. Mỗi hàm trả `true` khi
 * trạng thái đổi (người gọi invalidate đúng khung phím đó), `false` ⇒ không làm gì.
 * Vẽ: [BalloonView] tô lớp ink 12% lên khung phím — trùng màu `theme.pressed(keyFill)` của
 * phím space/chức năng, nhãn (ink) giữ nguyên — nên KeyboardView (~40 phím) không phải vẽ lại.
 */
class KeyPressHighlight(capacity: Int = 32) {
    private val l = FloatArray(capacity)
    private val t = FloatArray(capacity)
    private val r = FloatArray(capacity)
    private val b = FloatArray(capacity)
    private val on = BooleanArray(capacity)

    /** Số phím đang sẫm (0 ⇒ onDraw bỏ qua ngay). */
    var count = 0
        private set

    fun isPressed(pid: Int): Boolean = pid in on.indices && on[pid]
    fun left(pid: Int) = l[pid]
    fun top(pid: Int) = t[pid]
    fun right(pid: Int) = r[pid]
    fun bottom(pid: Int) = b[pid]
    val capacity: Int get() = on.size

    /** Ngón [pid] chạm phím khung [left, top, right, bottom]. */
    fun down(pid: Int, left: Float, top: Float, right: Float, bottom: Float): Boolean {
        if (pid !in on.indices) return false
        l[pid] = left; t[pid] = top; r[pid] = right; b[pid] = bottom
        if (!on[pid]) { on[pid] = true; count++ }
        return true
    }

    /** Nhấc / huỷ / bắt đầu vuốt / popup — bỏ sẫm ngón [pid]. */
    fun up(pid: Int): Boolean {
        if (pid !in on.indices || !on[pid]) return false
        on[pid] = false; count--
        return true
    }

    /**
     * Ngón [pid] đang ở (x, y): ra khỏi khung phím quá [slop] (trôi sang phím khác) ⇒ bỏ sẫm.
     * Đã bỏ thì không bật lại (phím chữ đã chèn lúc chạm — như iOS touchDragExit).
     */
    fun drift(pid: Int, x: Float, y: Float, slop: Float): Boolean {
        if (pid !in on.indices || !on[pid]) return false
        if (x >= l[pid] - slop && x <= r[pid] + slop && y >= t[pid] - slop && y <= b[pid] + slop) return false
        on[pid] = false; count--
        return true
    }

    /** Bỏ hết (ẩn bàn phím, đổi layout, huỷ mọi chạm). */
    fun clearAll(): Boolean {
        if (count == 0) return false
        on.fill(false); count = 0
        return true
    }
}
