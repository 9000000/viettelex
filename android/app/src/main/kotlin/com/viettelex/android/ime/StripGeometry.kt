package com.viettelex.android.ime

import com.viettelex.keyboard.BarLayout

/**
 * Hình học slot thanh gợi ý — THUẦN. 3 slot BẰNG NHAU, cố định theo bề rộng bar (không
 * theo nội dung) ⇒ không "lúc rộng lúc hẹp" như lỗi iOS 27/09/2026. Thẻ Dán thay CẢ bar
 * (StripView không vẽ slot khi thẻ hiện). Pinned by StripGeometryTest.
 */
object StripGeometry {
    /** Chiều cao pill (thẻ Dán, chip số, Khôi phục) và ô nhấn slot, dp. */
    const val PILL_H = 32f
    /** Bề ngang ô icon con trỏ (sau ô mẫu câu) / ô 📋 (trước ⌄), dp. */
    const val TOOL_W = 44f
    const val CLIP_W = 40f
    /** Ô nút 😊 sát trái ⌄ ("Nút emoji" = Thanh trên), dp. */
    const val EMOJI_W = 40f
    /** Icon thanh công cụ khi mở (☰ mẫu câu, con trỏ, 📋), dp; ⌄ nhỏ hơn 2 dp. */
    const val ICON_OPEN = 22f
    /** Icon khi thu gọn (hàng nổi 14 dp). */
    const val ICON_COLLAPSED = 14f
    /** Cỡ chữ gợi ý (sp) — Gboard ~16–17; giữa đậm vừa. */
    const val WORD_SP = 17f

    /** Cỡ icon nội suy theo độ mở [o] (0 thu gọn … 1 mở); [delta] = bớt so với [ICON_OPEN]. */
    fun iconDp(o: Float, delta: Float = 0f): Float =
        ICON_COLLAPSED + (ICON_OPEN - delta - ICON_COLLAPSED) * o.coerceIn(0f, 1f)

    /**
     * #113 kiểu Gboard: đang có nội dung gợi ý (chữ, emoji, chip số/email, thẻ Dán, pill hoàn
     * tác) ⇒ ẩn icon con trỏ + 📋 để 3 slot rộng hơn; ☰ và ⌄ giữ nguyên. Bảng sửa / lịch sử
     * clipboard đang mở ⇒ vẫn hiện icon tương ứng để đóng được. Chỉ đổi khi nội dung rỗng↔có.
     */
    fun toolsShown(hasContent: Boolean, editOpen: Boolean, clipOpen: Boolean): Boolean =
        !hasContent || editOpen || clipOpen

    /**
     * Bar có nội dung đẩy icon đi: chữ/emoji, chip số/email/Dán, thẻ Dán, pill hoàn tác.
     * [idle] (ô trống, chưa có từ trước — SuggestionSet.idle): chữ đệm phổ biến KHÔNG tính.
     */
    fun hasContent(l: BarLayout, idle: Boolean = false): Boolean = when (l) {
        is BarLayout.Slots -> !idle && (l.emojis.isNotEmpty() || l.slots.any { it != null })
        is BarLayout.Chips -> l.chips.isNotEmpty()
        is BarLayout.Pill, BarLayout.PasteCard -> true
    }

    /** Mép trái vùng slot (dp): zone ☰ + ô icon con trỏ khi [toolsShown]. */
    fun barLeft(zoneW: Float, toolW: Float, toolsShown: Boolean): Float =
        zoneW + if (toolsShown) toolW else 0f

    /**
     * Bề ngang các nút giữa slot và zone ⌄ (dp): 😊 ([emojiButton], LUÔN — cả khi có gợi ý, để emoji
     * không mất lối vào) + 📋 (chỉ khi có nút và [toolsShown]).
     */
    fun rightExtraW(clipW: Float, clipButton: Boolean, toolsShown: Boolean, emojiButton: Boolean = false): Float =
        (if (emojiButton) EMOJI_W else 0f) + (if (clipButton && toolsShown) clipW else 0f)

    /** Mép phải vùng slot (dp): trừ zone ⌄, ô 😊 ([emojiButton]) và ô 📋 (chỉ khi có nút và [toolsShown]). */
    fun barRight(width: Float, zoneW: Float, clipW: Float, clipButton: Boolean, toolsShown: Boolean,
                 emojiButton: Boolean = false): Float =
        width - zoneW - rightExtraW(clipW, clipButton, toolsShown, emojiButton)

    /** Mép trái/phải slot i (0..2) trong [barL, barR] → ghi vào [l]/[r]. */
    fun thirds(barL: Float, barR: Float, l: FloatArray, r: FloatArray) {
        val third = (barR - barL) / 3f
        for (i in 0..2) { l[i] = barL + i * third; r[i] = if (i == 2) barR else l[i] + third }
    }
}
