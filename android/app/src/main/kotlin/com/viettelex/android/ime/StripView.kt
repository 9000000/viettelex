package com.viettelex.android.ime

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import com.viettelex.android.R
import com.viettelex.keyboard.BarChip
import com.viettelex.keyboard.BarLayout
import com.viettelex.keyboard.SlotTapLatch
import com.viettelex.keyboard.SuggestionSet
import com.viettelex.keyboard.SuggestionSlots
import kotlin.math.abs
import com.viettelex.keyboard.tr

/**
 * Strip gợi ý (spec §6.6, §7.1): [☰ 52][ "nguyên văn" | từ 1 | từ 2 / ≤3 emoji ][⌄ 52],
 * thẻ Dán kiểu iOS 27, trạng thái thu gọn 14 dp với ☰/⌄ nổi. View này PHỦ lên mép trên
 * vùng phím 4 dp (nút nổi cao 18 dp như iOS) — chạm không trúng mục tiêu nào trả false
 * để rơi xuống [KeyboardView].
 */
@SuppressLint("ViewConstructor")
class StripView(context: Context, private val theme: ImeTheme, private val feedback: Feedback) : View(context) {

    interface Listener {
        fun onSuggestion(item: String)
        fun onToggleTemplates()
        /** Chevron đã đổi trạng thái; gọi SAU animation (refresh gợi ý khi mở lại). */
        fun onBarToggled(collapsed: Boolean)
        /** Chiều cao strip đổi (animation) — root đo lại. */
        fun onStripHeightChanged()
        /** Chạm ô "↩︎ Khôi phục" sau vuốt ⌫ xoá theo từ. */
        fun onRestoreDeleted()
        /** Icon con trỏ: mở/đóng bảng sửa văn bản. */
        fun onToggleEditPanel()
        /** Giữ lâu icon con trỏ: bật/tắt chế độ một tay (chỉ khi [oneHandAvailable]). */
        fun onToggleOneHand()
        /** Nút 📋 (khi lịch sử clipboard bật): mở/đóng bảng lịch sử. */
        fun onToggleClipboard()
        /** Nút 😊 ("Nút emoji" = Thanh trên): chạm = bảng emoji. */
        fun onEmojiButton() {}
        /**
         * Giữ nút 😊 strip: menu như giữ phím 😊 (đổi bàn phím, giọng nói, một tay…). Toạ độ px của
         * StripView; IME đổi sang toạ độ bàn phím. true = menu đã mở (nhận [onEmojiButtonHoldMove]).
         */
        fun onEmojiButtonHold(anchorCx: Float, anchorTop: Float, anchorBottom: Float, x: Float, y: Float): Boolean = false
        fun onEmojiButtonHoldMove(x: Float, y: Float) {}
        fun onEmojiButtonHoldEnd(cancel: Boolean) {}
    }

    /** Điện thoại (không tablet): giữ lâu icon con trỏ = một tay. */
    var oneHandAvailable = false

    /**
     * Lời mời dán (thẻ Dán / chip clipboard) hiện (true) / rời bar (false) — PasteOfferOnce.
     * Gọi khi ĐỔI, và mỗi lượt show khi đang hiện; lúc gõ chữ (không có lời mời) không gọi.
     */
    var onPasteOffer: ((Boolean) -> Unit)? = null
    private var pasteOfferOn = false
    private fun notePasteOffer(on: Boolean = paste || (0 until chipCount).any { i ->
        slotPayload[i]?.let { it == SuggestionSet.PASTE_TOKEN || it.startsWith(SuggestionSet.CLIP_CHIP_PREFIX) } == true
    }) {
        if (!on && on == pasteOfferOn) return
        pasteOfferOn = on
        onPasteOffer?.invoke(on)
    }

    var listener: Listener? = null

    private val d = theme.density
    var suggestionsEnabled = false; private set
    /** Dải giữ chỗ (công tắc toàn cục — [KeyLayout.stripReserved]); nội dung theo [suggestionsEnabled]. */
    private var reserved = false
    var collapsed = false; private set
    /** 1 = mở, 0 = thu gọn (animation 200 ms). */
    private var openness = 1f
    private var anim: ValueAnimator? = null
    private var plane = Plane.LETTERS
    private var templatesEnabled = true

    // --- nội dung bar ---
    private val slotText = arrayOfNulls<String>(3)      // đã ellipsize
    private val slotPayload = arrayOfNulls<String>(3)
    private val slotL = FloatArray(3); private val slotR = FloatArray(3)
    private val emojiText = arrayOfNulls<String>(3)
    private val emojiL = FloatArray(3); private val emojiR = FloatArray(3)
    private var emojiCount = 0
    private var paste = false
    /** Slot đang là chip tách số (vẽ nền pill, chia đều bar theo [chipCount]). */
    private var chipCount = 0
    /** Nút 📋 lịch sử clipboard + chỉ báo ẩn danh (đặt trước ⌄, bar co lại). */
    private var clipButton = false
    private var clipOpen = false
    /** Nút 😊 cạnh ⌄ ("Nút emoji" = Thanh trên) — luôn hiện (cả khi có gợi ý / thu gọn), StripGeometry.EMOJI_W. */
    var emojiButton = false; private set
    private var lastSig = ""
    private var lastSet: SuggestionSet? = null
    /** Bar đang có nội dung gợi ý (chữ/emoji/chip/thẻ Dán/pill) ⇒ ẩn icon con trỏ + 📋 (#113). */
    private var hasContent = false

    /** Icon con trỏ + 📋 có hiện không — chỉ đổi khi nội dung rỗng↔có (StripGeometry.toolsShown). */
    private fun tools(): Boolean = StripGeometry.toolsShown(hasContent, plane == Plane.EDIT, clipOpen)

    private val wordPaint = TextPaint(theme.text(StripGeometry.WORD_SP))
    private val wordOff = theme.centerOffset(wordPaint)
    /** Gboard nhấn mạnh gợi ý giữa (medium). */
    private val wordCenterPaint = TextPaint(theme.text(StripGeometry.WORD_SP, medium = true))
    private val wordCenterOff = theme.centerOffset(wordCenterPaint)
    private val emojiPaint = theme.text(22f)
    private val emojiOff = theme.centerOffset(emojiPaint)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pasteTitle = theme.text(15f, medium = true, align = Paint.Align.LEFT)
    private val pasteSub = theme.text(13f, color = theme.withAlpha(theme.ink, 0.7f), align = Paint.Align.LEFT)
    private val pasteTitleText = tr("Dán")
    private val pasteSubText = tr("Nội dung vừa copy")
    private var pasteIconCx = 0f; private var pasteTextX = 0f; private var pasteSubX = 0f
    private var pasteL = 0f; private var pasteR = 0f; private var pasteT = 0f; private var pasteB = 0f
    private var pasteShowSub = true
    private val chipPaint = theme.fill(theme.chip)
    private val pressPaint = theme.fill(theme.withAlpha(theme.ink, 0.10f))
    private var pressed = T_NONE
    private var pressedIndex = 0
    private var pasteTitleBase = 0f; private var pasteSubBase = 0f; private var pasteIconCy = 0f

    // --- vuốt ⌫: xem trước đoạn sẽ xoá / ô Khôi phục (đè nội dung bar tới khi gỡ) ---
    private var swipePreview: String? = null
    /** Dòng trạng thái không chạm được (vd "Đang dịch…", nhắc tải gói dịch); null = gỡ. */
    private var statusText: String? = null
    private var restoreOffer = false
    /** Hoàn tác thêm dấu (SuggestionSlots tầng 1) — vẽ cùng kiểu pill ô Khôi phục. */
    private var actionPill: BarChip? = null
    private val restoreDefault = "↩\uFE0E " + tr("Khôi phục")
    private var restoreText = restoreDefault
    private val chipText = TextPaint(theme.text(15f, medium = true))
    private val chipTextOff = theme.centerOffset(chipText)

    // --- touch ---
    private var target = T_NONE
    private var targetIndex = 0
    private var downX = 0f; private var downY = 0f

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        layoutPaste()
    }

    /** Bề rộng dành cho 😊 + 📋 bên trái ⌄. */
    private fun extraW(): Float = theme.dp(StripGeometry.rightExtraW(CLIP_W, clipButton, tools(), emojiButton))
    /** Lề mỗi bên cho pill căn giữa: zone + phần lớn hơn giữa icon con trỏ (trái) và 📋/🕶 (phải). */
    private fun sideW(): Float = theme.dp(KeyLayout.STRIP_ZONE_W) + maxOf(if (tools()) theme.dp(STRIP_TOOL_W) else 0f, extraW())

    /** Nút 📋 (lịch sử bật) + chỉ báo ẩn danh; [open] = bảng lịch sử đang mở (tô đậm). */
    fun setExtras(clipButton: Boolean, open: Boolean = clipOpen) {
        if (clipButton == this.clipButton && open == clipOpen) return
        this.clipButton = clipButton; clipOpen = open
        lastSet?.let { layoutSlots(it) }
        layoutPaste()
        invalidate()
    }

    /** Chiều cao strip (dp → px) — root dùng để đặt vùng phím. */
    fun stripPx(): Float = if (!reserved) 0f
        else theme.dp(KeyLayout.COLLAPSED_STRIP + (KeyLayout.OPEN_STRIP - KeyLayout.COLLAPSED_STRIP) * openness)

    /** Chiều cao view = strip + 4 dp phủ lên mép hàng phím (nút nổi 18 dp). */
    fun viewHeightPx(): Int = if (!reserved) 0 else (stripPx() + theme.dp(4f)).toInt()

    /** [reserved]: giữ chỗ dải dù ô này không có gợi ý (bàn phím không đổi cao giữa các ô). */
    fun configure(enabled: Boolean, collapsed: Boolean, templatesEnabled: Boolean, reserved: Boolean = enabled,
                  emojiButton: Boolean = false) {
        anim?.cancel()
        if (emojiButton != this.emojiButton) { this.emojiButton = emojiButton; layoutPaste() }
        this.suggestionsEnabled = enabled
        this.reserved = reserved || enabled
        this.collapsed = collapsed
        this.templatesEnabled = templatesEnabled
        openness = if (collapsed) 0f else 1f
        lastSig = ""
        if (!enabled || collapsed) { clearContent(); notePasteOffer(false) }
        invalidate()
    }

    fun setPlane(p: Plane) {
        if (p == plane) return
        val before = tools()
        plane = p
        if (p == Plane.EMOJI || p == Plane.EMOJI_SEARCH) { paste = false; notePasteOffer(false) }
        if (tools() != before) { lastSet?.let { layoutSlots(it) }; layoutPaste() }
        invalidate()
    }

    private val barVisible get() = suggestionsEnabled && plane != Plane.EMOJI && plane != Plane.EMOJI_SEARCH

    private fun clearContent() {
        for (i in 0..2) { slotText[i] = null; slotPayload[i] = null; emojiText[i] = null }
        emojiCount = 0; paste = false; chipCount = 0; actionPill = null
        lastSet = null; hasContent = false
    }

    /** Vuốt ⌫: đoạn sẽ xoá (null = gỡ). */
    fun showSwipePreview(text: String?) {
        if (text == swipePreview) return
        swipePreview = text
        invalidate()
    }

    /** Trạng thái tạm (không chạm được) đè lên thanh gợi ý; null = gỡ. */
    fun showStatus(text: String?) {
        if (text == statusText) return
        statusText = text
        invalidate()
    }

    /** Ô "↩︎ Khôi phục" một lượt sau vuốt ⌫ xoá; [label] khác (vd "Hoàn tác" công cụ văn bản). */
    fun showRestore(on: Boolean, label: String? = null) {
        val text = label?.let { "↩\uFE0E $it" } ?: restoreDefault
        if (on == restoreOffer && text == restoreText) return
        restoreOffer = on
        restoreText = text
        invalidate()
    }

    /** Có phím chữ ⇒ ẩn thẻ Dán NGAY (không đợi gợi ý nền). */
    fun hidePasteCard() {
        notePasteOffer(false)
        if (!paste) return
        paste = false; lastSig = ""
        invalidate()
    }

    fun show(set: SuggestionSet?) {
        if (!suggestionsEnabled || collapsed) return
        if (set == null) return
        val sig = set.signature() + (if (set.paste) "\u0005p" else "")
        if (sig != lastSig || width <= 0) {
            lastSig = sig
            lastSet = set
            layoutSlots(set)
            invalidate()
        }
        notePasteOffer()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        if (w != oldw) { lastSet?.let { layoutSlots(it) }; layoutPaste() }
    }

    private fun layoutSlots(set: SuggestionSet) {
        val disp = arrayOfNulls<String>(3)
        val toolsBefore = tools()
        clearContent()
        lastSet = set
        // Thứ tự ưu tiên slot (hoàn tác > clipboard > Thêm dấu > chip số > chữ): SuggestionSlots.
        // Gboard: từ kế tiếp tốt nhất ở GIỮA; không ngoặc kép quanh nguyên văn.
        val l = SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true, pasteLabel = pasteTitleText)
        hasContent = StripGeometry.hasContent(l, set.idle)
        val shown = tools()
        if (shown != toolsBefore) layoutPaste()
        // Trái: ô mẫu câu + icon con trỏ (bảng sửa); phải: 📋 + ⌄. Có gợi ý ⇒ ẩn con trỏ/📋 (#113).
        val barL = theme.dp(StripGeometry.barLeft(KeyLayout.STRIP_ZONE_W, STRIP_TOOL_W, shown))
        val barR = theme.dp(StripGeometry.barRight(width / d, KeyLayout.STRIP_ZONE_W, CLIP_W, clipButton, shown, emojiButton))
        when (l) {
            is BarLayout.Pill -> { actionPill = l.chip; return }
            BarLayout.PasteCard -> { paste = true; return }
            is BarLayout.Chips -> {
                // Chip tách số thay thẻ Dán: [Dán OTP 482913][Dán] — chia đều bar, nền pill.
                chipCount = l.chips.size
                val each = (barR - barL) / chipCount
                val pad = theme.dp(10f)
                for (i in 0 until chipCount) {
                    slotL[i] = barL + i * each; slotR[i] = slotL[i] + each
                    slotPayload[i] = l.chips[i].payload
                    slotText[i] = TextUtils.ellipsize(l.chips[i].label, chipText, each - 2 * pad - theme.dp(4f),
                        TextUtils.TruncateAt.END).toString()
                }
                return
            }
            is BarLayout.Slots -> {
                for (i in 0..2) l.slots[i]?.let { disp[i] = it.label; slotPayload[i] = it.payload }
                emojiCount = l.emojis.size
                for (i in l.emojis.indices) emojiText[i] = l.emojis[i]
            }
        }

        // Gboard: 3 ô bằng nhau, không vạch ngăn; emoji chia đều ô thứ 3.
        val third = (barR - barL) / 3f
        val pad = theme.dp(4f)
        StripGeometry.thirds(barL, barR, slotL, slotR)
        for (i in 0..2) {
            val t = disp[i] ?: continue
            val p = if (i == 1) wordCenterPaint else wordPaint
            slotText[i] = TextUtils.ellipsize(t, p, third - 2 * pad, TextUtils.TruncateAt.MIDDLE).toString()
        }
        if (emojiCount > 0) {
            val each = third / emojiCount
            for (i in 0 until emojiCount) { emojiL[i] = slotL[2] + i * each; emojiR[i] = slotL[2] + (i + 1) * each }
        }
    }

    /** Chip clipboard kiểu Gboard: pill màu secondary container giữa bar, icon + "Dán" + mô tả. */
    private fun layoutPaste() {
        val cy = theme.dp(KeyLayout.BAR_CY)
        val h = theme.dp(StripGeometry.PILL_H)
        val icon = theme.dp(18f); val gap = theme.dp(6f); val padH = theme.dp(12f)
        val tW = pasteTitle.measureText(pasteTitleText); val sW = pasteSub.measureText(pasteSubText)
        val maxW = maxOf(0f, width - 2 * sideW())
        var total = padH + icon + gap + tW + gap + sW + padH
        pasteShowSub = total <= maxW
        if (!pasteShowSub) total = padH + icon + gap + tW + padH
        pasteL = (width - total) / 2; pasteR = pasteL + total
        pasteT = cy - h / 2; pasteB = cy + h / 2
        pasteIconCx = pasteL + padH + icon / 2
        pasteIconCy = cy
        pasteTextX = pasteL + padH + icon + gap
        pasteSubX = pasteTextX + tW + gap
        pasteTitleBase = cy + theme.centerOffset(pasteTitle)
        pasteSubBase = cy + theme.centerOffset(pasteSub)
    }

    // MARK: animation thu gọn

    private fun toggleCollapsed() {
        feedback.click(Feedback.MODIFIER, this)
        val target = !collapsed
        collapsed = target
        lastSig = ""
        if (target) clearContent()
        anim?.cancel()
        anim = ValueAnimator.ofFloat(openness, if (target) 0f else 1f).apply {
            duration = 200
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                openness = it.animatedValue as Float
                listener?.onStripHeightChanged()
                invalidate()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    anim = null
                    listener?.onBarToggled(collapsed)
                }
            })
            start()
        }
    }

    // MARK: vẽ

    override fun onDraw(c: Canvas) {
        if (!barVisible) return
        val w = width.toFloat()
        val o = openness
        // Icon toolbar kiểu Gboard ở đúng vị trí ☰/⌄ cũ: nội suy giữa vị trí nổi (thu gọn)
        // và vị trí zone (mở).
        val cyOpen = theme.dp(KeyLayout.BAR_CY)
        val cyFloat = theme.dp(7f)
        val cy = cyFloat + (cyOpen - cyFloat) * o
        if (templatesEnabled) {
            val bx = theme.dp(32f) + (theme.dp(26f) - theme.dp(32f)) * o
            val active = plane == Plane.TEMPLATES && o > 0.5f
            if (active) c.drawCircle(bx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.ink, if (active) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.GRID, bx, cy, theme.dp(StripGeometry.iconDp(o)), iconPaint)
        }
        if (tools()) {
            // Icon con trỏ (bảng sửa văn bản) cạnh ô mẫu câu — ẩn khi đang có gợi ý (#113).
            val ex = theme.dp(88f) + (theme.dp(KeyLayout.STRIP_ZONE_W + STRIP_TOOL_W / 2) - theme.dp(88f)) * o
            val active = plane == Plane.EDIT && o > 0.5f
            if (active || pressed == T_EDIT) c.drawCircle(ex, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.ink, if (active) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.CURSOR, ex, cy, theme.dp(StripGeometry.iconDp(o)), iconPaint)
        }
        val chx = (w - theme.dp(24f)) + (theme.dp(24f) - theme.dp(26f)) * o
        iconPaint.color = theme.withAlpha(theme.ink, 0.75f)
        ImeIcons.draw(c, ImeIcons.CHEVRON_DOWN, chx, cy, theme.dp(StripGeometry.iconDp(o, delta = 2f)), iconPaint, rotationDeg = 180f * (1f - o))
        drawExtras(c, w, cy, o)
        if (o <= 0f || collapsed && anim == null) return
        val alpha = (255 * o).toInt()
        statusText?.let { drawChip(c, it, alpha, TextUtils.TruncateAt.END); return }
        swipePreview?.let { drawChip(c, "⌫ " + it.replace('\n', ' '), alpha, TextUtils.TruncateAt.START); return }
        if (restoreOffer) { drawChip(c, restoreText, alpha, TextUtils.TruncateAt.END); return }
        actionPill?.let { drawChip(c, it.label, alpha, TextUtils.TruncateAt.END); return }
        if (paste) { drawPaste(c, alpha); return }
        val barCy = cyOpen
        val hh = theme.dp(StripGeometry.PILL_H / 2); val inset = theme.dp(2f)
        if (pressed == T_SLOT) {
            val i = pressedIndex
            c.drawRoundRect(slotL[i] + inset, barCy - hh, slotR[i] - inset, barCy + hh, hh, hh, pressPaint)
        } else if (pressed == T_EMOJI) {
            val i = pressedIndex
            c.drawRoundRect(emojiL[i] + inset, barCy - hh, emojiR[i] - inset, barCy + hh, hh, hh, pressPaint)
        }
        if (chipCount > 0) {
            chipText.color = theme.ink; chipText.alpha = alpha
            val ci = theme.dp(3f)
            for (i in 0 until chipCount) {
                val s = slotText[i] ?: continue
                chipPaint.alpha = if (pressed == T_SLOT && pressedIndex == i) (alpha * 0.8f).toInt() else alpha
                c.drawRoundRect(slotL[i] + ci, barCy - hh, slotR[i] - ci, barCy + hh, hh, hh, chipPaint)
                c.drawText(s, (slotL[i] + slotR[i]) / 2, barCy + chipTextOff, chipText)
            }
            chipPaint.alpha = 255
            return
        }
        wordPaint.color = theme.ink; wordPaint.alpha = alpha
        wordCenterPaint.color = theme.ink; wordCenterPaint.alpha = alpha
        for (i in 0..2) {
            val s = slotText[i] ?: continue
            if (i == 1) c.drawText(s, (slotL[i] + slotR[i]) / 2, barCy + wordCenterOff, wordCenterPaint)
            else c.drawText(s, (slotL[i] + slotR[i]) / 2, barCy + wordOff, wordPaint)
        }
        emojiPaint.alpha = alpha
        for (i in 0 until emojiCount) {
            val s = emojiText[i] ?: continue
            c.drawText(s, (emojiL[i] + emojiR[i]) / 2, barCy + emojiOff, emojiPaint)
        }
    }

    /** 😊 (Thanh trên) rồi 📋 (bấm được) bên trái ⌄; thu gọn thì nhỏ lại ở hàng nổi. Không có chỉ báo ẩn danh (Phil 27/09 bỏ). */
    private fun drawExtras(c: Canvas, w: Float, cy: Float, o: Float) {
        val zoneL = w - theme.dp(KeyLayout.STRIP_ZONE_W) * o - theme.dp(48f) * (1f - o)
        var x = zoneL
        if (emojiButton) {
            val cx = x - theme.dp(StripGeometry.EMOJI_W) / 2
            if (pressed == T_EMOJI_BTN && o > 0.5f) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.ink, 0.75f)
            ImeIcons.draw(c, ImeIcons.FACE, cx, cy, theme.dp(StripGeometry.iconDp(o)), iconPaint)
            x -= theme.dp(StripGeometry.EMOJI_W)
        }
        if (clipButton && tools()) {
            val cx = x - theme.dp(CLIP_W) / 2
            if (clipOpen && o > 0.5f) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.ink, if (clipOpen) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.CLIPBOARD, cx, cy, theme.dp(StripGeometry.iconDp(o, delta = 1f)), iconPaint)
        }
    }

    /** Pill giữa bar (cùng kiểu thẻ Dán) cho xem trước vuốt ⌫ / Khôi phục. */
    private fun drawChip(c: Canvas, text: String, alpha: Int, trunc: TextUtils.TruncateAt) {
        val cy = theme.dp(KeyLayout.BAR_CY)
        val padH = theme.dp(14f); val h = theme.dp(StripGeometry.PILL_H)
        val maxW = maxOf(0f, width - 2 * sideW() - 2 * padH)
        val t = TextUtils.ellipsize(text, chipText, maxW, trunc).toString()
        val w = chipText.measureText(t) + 2 * padH
        val l = (width - w) / 2
        chipPaint.alpha = if (pressed == T_RESTORE || pressed == T_PILL) (alpha * 0.8f).toInt() else alpha
        c.drawRoundRect(l, cy - h / 2, l + w, cy + h / 2, h / 2, h / 2, chipPaint)
        chipPaint.alpha = 255
        chipText.color = theme.ink; chipText.alpha = alpha
        c.drawText(t, width / 2f, cy + chipTextOff, chipText)
    }

    private fun drawPaste(c: Canvas, alpha: Int) {
        chipPaint.alpha = if (pressed == T_PASTE) (alpha * 0.8f).toInt() else alpha
        val r = (pasteB - pasteT) / 2
        c.drawRoundRect(pasteL, pasteT, pasteR, pasteB, r, r, chipPaint)
        chipPaint.alpha = 255
        iconPaint.color = theme.withAlpha(theme.ink, alpha / 255f)
        ImeIcons.draw(c, ImeIcons.CLIPBOARD, pasteIconCx, pasteIconCy, theme.dp(18f), iconPaint)
        pasteTitle.alpha = alpha
        c.drawText(pasteTitleText, pasteTextX, pasteTitleBase, pasteTitle)
        if (pasteShowSub) {
            pasteSub.color = theme.withAlpha(theme.ink, 0.7f * alpha / 255f)
            c.drawText(pasteSubText, pasteSubX, pasteSubBase, pasteSub)
        }
    }

    // MARK: touch

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                target = findTarget(e.x, e.y)
                downX = e.x; downY = e.y
                if (target == T_SLOT || target == T_EMOJI || target == T_PASTE || target == T_RESTORE || target == T_PILL || target == T_EDIT || target == T_EMOJI_BTN) {
                    pressed = target; pressedIndex = targetIndex; invalidate()
                }
                // chốt từ đang HIỆN dưới ngón tay — gợi ý nền về trước lúc nhấc không được đổi nó
                tap.down(when (target) {
                    T_SLOT -> slotPayload[targetIndex]
                    T_EMOJI -> emojiText[targetIndex]
                    T_PILL -> actionPill?.payload
                    else -> null
                })
                longFired = false
                removeCallbacks(editLongRun)
                if (target == T_EDIT && oneHandAvailable) postDelayed(editLongRun, LONG_MS)
                emojiHoldOpen = false
                removeCallbacks(emojiLongRun)
                if (target == T_EMOJI_BTN) postDelayed(emojiLongRun, LONG_MS)
                return target != T_NONE
            }
            MotionEvent.ACTION_MOVE -> if (emojiHoldOpen) listener?.onEmojiButtonHoldMove(e.x, e.y)
            MotionEvent.ACTION_UP -> {
                removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
                if (emojiHoldOpen) { emojiHoldOpen = false; target = T_NONE; listener?.onEmojiButtonHoldEnd(false); return true }
                val t = if (longFired) T_NONE else target; target = T_NONE
                if (pressed != T_NONE) { pressed = T_NONE; invalidate() }
                if (abs(e.x - downX) > theme.dp(40f) || abs(e.y - downY) > theme.dp(40f)) return true
                fire(t)
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
                if (emojiHoldOpen) { emojiHoldOpen = false; listener?.onEmojiButtonHoldEnd(true) }
                target = T_NONE; tap.cancel(); if (pressed != T_NONE) { pressed = T_NONE; invalidate() } }
        }
        return true
    }

    private fun findTarget(x: Float, y: Float): Int {
        if (!barVisible) return T_NONE
        val w = width.toFloat()
        val strip = stripPx()
        if (collapsed || openness < 1f) {
            if (y > theme.dp(18f)) return T_NONE
            if (templatesEnabled && x < theme.dp(64f)) return T_BURGER
            if (x >= theme.dp(64f) && x < theme.dp(112f)) return T_EDIT
            if (x >= w - theme.dp(48f)) return T_CHEVRON
            val em = if (emojiButton) theme.dp(StripGeometry.EMOJI_W) else 0f
            if (emojiButton && x >= w - theme.dp(48f) - em) return T_EMOJI_BTN
            if (clipButton && x >= w - theme.dp(48f + CLIP_W) - em) return T_CLIP
            return T_NONE
        }
        if (y > strip) return T_NONE          // không lấn hàng Q–P
        val zone = theme.dp(KeyLayout.STRIP_ZONE_W)
        if (x < zone) return if (templatesEnabled) T_BURGER else T_NONE
        val tools = tools()
        if (tools && x < zone + theme.dp(STRIP_TOOL_W)) return T_EDIT
        if (x >= w - zone) return T_CHEVRON
        val em = if (emojiButton) theme.dp(StripGeometry.EMOJI_W) else 0f
        if (emojiButton && x >= w - zone - em) return T_EMOJI_BTN
        if (clipButton && tools && x >= w - zone - em - theme.dp(CLIP_W)) return T_CLIP
        if (x >= w - zone - extraW()) return T_NONE
        if (swipePreview != null || statusText != null) return T_NONE
        if (restoreOffer) return T_RESTORE
        if (actionPill != null) return T_PILL
        if (paste) return T_PASTE
        for (i in 0 until emojiCount) if (x >= emojiL[i] && x < emojiR[i]) { targetIndex = i; return T_EMOJI }
        val n = if (chipCount > 0) chipCount else 3
        for (i in 0 until n) if (slotText[i] != null && x >= slotL[i] && x < slotR[i]) { targetIndex = i; return T_SLOT }
        return T_NONE
    }

    private fun fire(t: Int) {
        when (t) {
            T_BURGER -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleTemplates() }
            T_CHEVRON -> toggleCollapsed()
            T_EDIT -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleEditPanel() }
            T_CLIP -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleClipboard() }
            T_EMOJI_BTN -> { feedback.click(Feedback.MODIFIER, this); listener?.onEmojiButton() }
            T_PASTE -> { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(SuggestionSet.PASTE_TOKEN) }
            T_RESTORE -> { feedback.click(Feedback.MODIFIER, this); listener?.onRestoreDeleted() }
            T_PILL -> tap.up()?.let { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(it) }
            T_SLOT, T_EMOJI -> tap.up()?.let { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(it) }
        }
    }

    private val tap = SlotTapLatch()
    private var longFired = false
    private val editLongRun = Runnable {
        longFired = true
        pressed = T_NONE; invalidate()
        feedback.longPress(this)
        listener?.onToggleOneHand()
    }

    /** Menu giữ 😊 strip đang mở (nhận move / nhấc). */
    private var emojiHoldOpen = false
    private val emojiLongRun = Runnable {
        if (target != T_EMOJI_BTN) return@Runnable
        longFired = true
        pressed = T_NONE; invalidate()
        val cx = emojiButtonCx()
        emojiHoldOpen = listener?.onEmojiButtonHold(cx, 0f, stripPx(), downX, downY) == true
    }

    /** Tâm ngang nút 😊 (px) theo độ mở hiện tại — cùng công thức [drawExtras]. */
    private fun emojiButtonCx(): Float {
        val o = openness
        return width - theme.dp(KeyLayout.STRIP_ZONE_W) * o - theme.dp(48f) * (1f - o) - theme.dp(StripGeometry.EMOJI_W) / 2
    }

    fun onHidden() {
        removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
        if (emojiHoldOpen) { emojiHoldOpen = false; listener?.onEmojiButtonHoldEnd(true) }
        target = T_NONE; pressed = T_NONE; tap.cancel()
    }

    companion object {
        private const val T_NONE = 0
        private const val T_BURGER = 1
        private const val T_CHEVRON = 2
        private const val T_PASTE = 3
        private const val T_SLOT = 4
        private const val T_EMOJI = 5
        private const val T_RESTORE = 6
        private const val T_EDIT = 7
        private const val T_CLIP = 8
        private const val T_PILL = 9
        private const val T_EMOJI_BTN = 10
        /** Bề ngang ô icon con trỏ (sau ô mẫu câu), dp. */
        const val STRIP_TOOL_W = StripGeometry.TOOL_W
        private const val LONG_MS = 450L
        private const val CLIP_W = StripGeometry.CLIP_W
    }
}
