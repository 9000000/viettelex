package com.viettelex.keyboard

/**
 * Popup giữ phím ở hàng đáy bàn chữ (Android) — phần THUẦN, dùng chung hàng ô
 * [DomainPopup.layout] / [DomainPopup.Hold] (ô đầu chọn sẵn, trượt chọn, nhấc chạy, trượt xa huỷ).
 * TalkBack / touch exploration tắt popup ⇒ view giữ hành vi giữ lâu cũ.
 */
object CommaPopup {
    /**
     * Giữ "," (bàn chữ ô thường; ô URL/email có "/" "@" riêng): dấu câu hay dùng. KHÔNG có 🎤
     * (giọng nói ở menu giữ 😊 — [EmojiKeyMenu]). "." đứng đầu (chọn sẵn, #113: đã giữ phím
     * thì muốn ký tự khác ","; chạm vẫn ra ",") ⇒ giữ rồi nhấc tại chỗ ra "." như iOS.
     */
    val choices: List<String> = listOf(".", ",", "?", "!", ":", ";", "'", "\"", "-", "…")
    const val PRESELECT = 0

    /** Bề rộng ô (dp): 10 ô ⇒ hẹp hơn ô biến thể (38) để hàng không phủ kín bề ngang điện thoại. */
    fun itemWidthDp(tablet: Boolean): Float = if (tablet) 48f else 34f

    /**
     * Giữ "." khi "Phím cạnh dấu cách" = Dấu chấm ([SpaceSideKey.PERIOD]): cùng bộ dấu câu,
     * "," đứng đầu (chọn sẵn — đã giữ "." thì muốn ","), "." thứ hai.
     */
    val periodChoices: List<String> = listOf(",", ".") + choices.drop(2)

    /**
     * Lựa chọn của phím `key` ở bàn chữ; rỗng ⇒ phím khác (không hẹn giờ). `periodKey` = phím
     * "." này là phím cạnh space thay "," (Dấu chấm) — "." tablet / URL / email không có popup này.
     */
    fun choices(key: String, lettersPlane: Boolean, periodKey: Boolean = false): List<String> = when {
        !lettersPlane -> emptyList()
        key == "," -> choices
        key == "." && periodKey -> periodChoices
        else -> emptyList()
    }
}

/** Mục menu giữ phím 😊. */
enum class EmojiKeyAction {
    /** Danh sách bàn phím hệ thống (hành động giữ 😊 cũ). */
    SWITCH_KEYBOARD,
    /** Gõ giọng nói — chỉ khi máy có IME giọng nói. */
    VOICE,
    /** Bật / tắt chế độ một tay (điện thoại). */
    ONE_HAND,
    /** Bật / tắt bàn phím thả nổi (#112). */
    FLOATING,
    /** Mở app VietTelex (cài đặt). */
    SETTINGS,
}

/**
 * Giữ 😊 ⇒ hàng icon: 🌐 đổi bàn phím (chọn sẵn — giữ rồi nhấc tại chỗ = hành vi cũ) · 🎤 ·
 * ✋ một tay · 🪟 thả nổi · ⚙ cài đặt. Có phím 🌐 thật (needsGlobe) cũng vậy. Đang thả nổi ⇒
 * IME truyền oneHandAvailable = false (một tay tắt khi nổi).
 */
object EmojiKeyMenu {
    const val PRESELECT = 0

    fun actions(voiceAvailable: Boolean, oneHandAvailable: Boolean, floatingAvailable: Boolean): List<EmojiKeyAction> {
        val out = ArrayList<EmojiKeyAction>(5)
        out += EmojiKeyAction.SWITCH_KEYBOARD
        if (voiceAvailable) out += EmojiKeyAction.VOICE
        if (oneHandAvailable) out += EmojiKeyAction.ONE_HAND
        if (floatingAvailable) out += EmojiKeyAction.FLOATING
        out += EmojiKeyAction.SETTINGS
        return out
    }

    /** Nhãn (mô tả trợ năng / debug); một tay / thả nổi đang bật ⇒ mục là "tắt" / "gắn lại". */
    fun label(a: EmojiKeyAction, oneHandOn: Boolean, floatingOn: Boolean = false): String = when (a) {
        EmojiKeyAction.SWITCH_KEYBOARD -> tr("Đổi bàn phím")
        EmojiKeyAction.VOICE -> tr("Gõ bằng giọng nói")
        EmojiKeyAction.ONE_HAND -> if (oneHandOn) tr("Tắt chế độ một tay") else tr("Chế độ một tay")
        EmojiKeyAction.FLOATING -> if (floatingOn) tr("Gắn bàn phím xuống đáy") else tr("Thả nổi bàn phím")
        EmojiKeyAction.SETTINGS -> tr("Cài đặt VietTelex")
    }
}
