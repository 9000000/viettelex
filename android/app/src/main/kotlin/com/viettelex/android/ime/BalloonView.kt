package com.viettelex.android.ime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.Build
import android.view.View

/**
 * Preview phím kiểu Gboard (spec §6.5 — hình dạng Android từ 26/09/2026).
 * Overlay phủ toàn bàn phím, không nhận touch. Path dựng lại CHỈ khi hình dạng đổi
 * (cùng hàng phím ⇒ cùng path) bằng path.reset() — không alloc trên hot path.
 * Toạ độ theo view gốc (strip + phím).
 */
@SuppressLint("ViewConstructor")
class BalloonView(context: Context, private val theme: ImeTheme) : View(context) {
    private val path = Path()
    private val fill = theme.fill(theme.balloonFill).apply {
        // Bóng mềm 2dp lệch xuống 1dp, opacity 0.3. Shadow layer trên path chỉ được
        // tăng tốc phần cứng từ API 28; máy cũ bỏ bóng.
        if (Build.VERSION.SDK_INT >= 28) setShadowLayer(theme.dp(3f), 0f, theme.dp(1.5f), 0x33000000)
    }
    private val textPaint = theme.text(28f, color = theme.balloonInk)
    private val textOff = theme.centerOffset(textPaint)

    private var visible = false
    private var text = ""
    private var ox = 0f; private var oy = 0f          // gốc bubble trong view
    private var bubbleW = 0f; private var bubbleH = 0f
    private var shapeW = -1f; private var shapeH = -1f

    init {
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onTouchEvent(event: android.view.MotionEvent?) = false

    // MARK: phím sẫm khi bấm (Keys.KEY_PRESS_HIGHLIGHT)
    // Lớp ink 12% trên khung phím đang đè — cùng màu theme.pressed(keyFill) của phím space/chức
    // năng, nhãn ink không đổi. Vẽ ở overlay này (display list vài lệnh, vốn đã vẽ lại mỗi chạm
    // vì balloon) thay vì KeyboardView ⇒ chạm phím chữ không ghi lại ~40 phím. Toạ độ view gốc.
    /** Trạng thái theo ngón — KeyboardView ghi (chỉ khi công tắc BẬT). */
    val press = KeyPressHighlight()
    private val pressPaint = theme.fill(theme.withAlpha(theme.ink, 0.12f))
    private val pressRadius = theme.dp(KeyLayout.KEY_RADIUS)

    @Suppress("DEPRECATION")
    fun invalidatePress(pid: Int) {
        invalidate(press.left(pid).toInt() - 1, press.top(pid).toInt() - 1,
            press.right(pid).toInt() + 1, press.bottom(pid).toInt() + 1)
    }

    fun clearPress() { if (press.clearAll()) invalidate() }

    private fun drawPress(c: Canvas) {
        val p = press
        for (i in 0 until p.capacity) if (p.isPressed(i))
            c.drawRoundRect(p.left(i), p.top(i), p.right(i), p.bottom(i), pressRadius, pressRadius, pressPaint)
    }

    /**
     * keyRect theo toạ độ view gốc. Preview kiểu Gboard/Material: thẻ bo góc nổi NGAY
     * TRÊN phím (không cổ nối như iOS), rộng hơn phím chút, chữ lớn.
     */
    fun show(kl: Float, kt: Float, kr: Float, kb: Float, text: String) {
        val kw = kr - kl; val kh = kb - kt
        val bw = maxOf(kw * 1.2f, theme.dp(44f))
        val bh = maxOf(kh * 1.15f, theme.dp(52f))
        // Không vẽ ra ngoài cửa sổ IME được: kẹp ở 0 (strip gợi ý là headroom).
        val top = maxOf(kt - theme.dp(4f) - bh, 0f)
        val x = ((kl + kr) / 2 - bw / 2).coerceIn(0f, maxOf(0f, width - bw))
        if (bw != shapeW || bh != shapeH) {
            shapeW = bw; shapeH = bh
            path.reset()
            val r = theme.dp(10f)
            path.addRoundRect(0f, 0f, bw, bh, r, r, Path.Direction.CW)
        }
        invalidateBalloon()          // vùng cũ
        ox = x; oy = top; bubbleW = bw; bubbleH = bh
        this.text = text
        visible = true
        invalidateBalloon()          // vùng mới
    }

    fun hide() {
        if (!visible) return
        visible = false
        invalidateBalloon()
    }

    @Suppress("DEPRECATION")
    private fun invalidateBalloon() {
        val pad = theme.dp(4f)
        invalidate((ox - pad).toInt(), (oy - pad).toInt(), (ox + bubbleW + pad).toInt(), (oy + shapeH + pad).toInt())
    }

    // MARK: popup nhiều lựa chọn (DomainPopup / KeyVariants)
    // Hàng ô nổi trên phím: ô đang chọn nền màu nhấn (action) chữ actionInk như stock (ô xanh
    // chữ trắng). Paint/mảng dựng LƯỜI lần đầu mở popup — bàn phím không bao giờ giữ thì 0 chi phí.

    private class Pop(theme: ImeTheme) {
        val panel = theme.fill(theme.balloonFill).apply {
            if (Build.VERSION.SDK_INT >= 28) setShadowLayer(theme.dp(3f), 0f, theme.dp(1.5f), 0x4D000000)
        }
        val hi = theme.fill(theme.action)
        val text = theme.text(18f, color = theme.balloonInk)
        val ink = theme.balloonInk
        val selInk = theme.actionInk
        val rect = android.graphics.RectF()
        val fm = Paint.FontMetrics()
        var choices: List<String> = emptyList()
        var slotL = FloatArray(0)
        var size = FloatArray(0)
        var itemW = 0f
        var sel = -1
        /** Icon [ImeIcons] từng ô (menu giữ 😊); null = ô chữ. */
        var icons: IntArray? = null
        var iconSize = 0f
        val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    }
    private var pop: Pop? = null
    private var popVisible = false

    /** Popup đang hiện (test/debug). */
    val popupVisible: Boolean get() = popVisible
    /** Ô đang chọn (-1 = không chọn / huỷ). */
    val popupSelection: Int get() = if (popVisible) pop?.sel ?: -1 else -1

    /**
     * Hiện hàng [choices] trong khung panel (toạ độ view gốc); [slotLefts] mép trái từng ô,
     * [itemW] bề rộng ô, [textSp] cỡ chữ (tự thu nhỏ cho vừa ô, vd ".com.vn"), [sel] ô chọn sẵn.
     */
    fun showPopup(l: Float, t: Float, r: Float, b: Float, slotLefts: FloatArray, itemW: Float,
                  choices: List<String>, textSp: Float, sel: Int, icons: IntArray? = null) {
        val p = pop ?: Pop(theme).also { pop = it }
        p.rect.set(l, t, r, b)
        p.choices = choices; p.slotL = slotLefts; p.itemW = itemW; p.sel = sel
        p.icons = icons; p.iconSize = theme.dp(24f)
        val full = theme.sp(textSp)
        p.text.textSize = full
        val room = itemW - theme.dp(6f)
        p.size = FloatArray(choices.size) { i ->
            val w = p.text.measureText(choices[i])
            if (w > room && w > 0f) full * maxOf(0.6f, room / w) else full
        }
        popVisible = true
        invalidate()
    }

    fun selectPopup(sel: Int) {
        val p = pop ?: return
        if (!popVisible || p.sel == sel) return
        p.sel = sel
        invalidate()
    }

    fun hidePopup() {
        if (!popVisible) return
        popVisible = false
        invalidate()
    }

    private fun drawPopup(c: Canvas, p: Pop) {
        val r = theme.dp(10f)
        c.drawRoundRect(p.rect, r, r, p.panel)
        val inset = theme.dp(4f)
        val top = p.rect.top + inset; val bot = p.rect.bottom - inset
        for (i in p.choices.indices) {
            val x0 = p.slotL[i]
            if (i == p.sel) c.drawRoundRect(x0 + theme.dp(1f), top, x0 + p.itemW - theme.dp(1f), bot, theme.dp(7f), theme.dp(7f), p.hi)
            val icon = p.icons?.getOrNull(i) ?: -1
            if (icon >= 0) {
                p.iconPaint.color = if (i == p.sel) p.selInk else p.ink
                ImeIcons.draw(c, icon, x0 + p.itemW / 2, (top + bot) / 2, p.iconSize, p.iconPaint)
                continue
            }
            p.text.textSize = p.size[i]
            p.text.color = if (i == p.sel) p.selInk else p.ink
            p.text.getFontMetrics(p.fm)
            c.drawText(p.choices[i], x0 + p.itemW / 2, (top + bot) / 2 - (p.fm.ascent + p.fm.descent) / 2, p.text)
        }
    }

    override fun onDraw(c: Canvas) {
        if (press.count > 0) drawPress(c)      // dưới popup / bubble (bubble hàng dưới đè phím hàng trên)
        if (popVisible) pop?.let { drawPopup(c, it) }
        if (!visible) return
        c.save()
        c.translate(ox, oy)
        c.drawPath(path, fill)
        c.drawText(text, bubbleW / 2, bubbleH / 2 + textOff, textPaint)
        c.restore()
    }
}
