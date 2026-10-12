package com.viettelex.keyboard

/**
 * Setting bàn phím — mặc định y iOS (khác macOS: simpleTelex BẬT). Đọc lại mỗi lần
 * bàn phím hiện ([load]).
 */
data class KeyboardSettings(
    var freeMarking: Boolean = true,
    var simpleTelex: Boolean = true,
    var liveSpellCheck: Boolean = true,
    var autoRestore: Boolean = true,
    var quickTelex: Boolean = false,
    var modernTone: Boolean = false,
    /** Chính tả teencode — mặc định TẮT (issue #94). */
    var teencode: Boolean = false,
    /**
     * Kiểu gõ VNI — mặc định TẮT (Telex). Số 1–9/0 mang dấu KHI ĐANG SOẠN TỪ (hoặc sửa dấu
     * từ ngay trước con trỏ); ngoài từ vẫn là số. Engine giống macOS (`vniMode`).
     */
    var vniMode: Boolean = false,
    var showSuggestions: Boolean = true,
    /** Chip "Thêm dấu" tự hiện khi chữ trước con trỏ không dấu — mặc định TẮT (hiệu năng thắng). */
    var addTonesChip: Boolean = false,
    /** Chip số trên thanh gợi ý — mặc định BẬT (chỉ đọc context ngay sau chữ số/phép tính). */
    var numberChips: Boolean = true,
    /** "Hiện kết quả phép tính" (12*3= → chip 36 ở slot đầu) — mặc định BẬT; chỉ đọc context ngay sau "=". */
    var mathResults: Boolean = true,
    /**
     * "Gợi ý cả khi ứng dụng tắt gợi ý" (#113, như Gboard/Laban) — mặc định BẬT: ô chữ đặt
     * NO_SUGGESTIONS (không mật khẩu/ẩn danh/số) vẫn gợi ý chữ, nhưng không tự sửa, không học từ.
     * Tắt ⇒ như cũ: chỉ thanh công cụ ([StripMode.TOOLS]).
     */
    var suggestInNoSuggestFields: Boolean = true,
    /** Đi theo showSuggestions (không có toggle riêng). */
    var learnWords: Boolean = true,
    var filterSensitive: Boolean = true,
    var hapticFeedback: Boolean = false,
    /** Độ mạnh rung 10…100 % ([HapticStrength]) — chỉ dùng khi hapticFeedback bật. */
    var hapticStrength: Int = HapticStrength.DEFAULT,
    /** Âm thanh phím riêng — mặc định TẮT (tắt ⇒ AudioManager.playSoundEffect như cũ, 0 chi phí). */
    var keySound: Boolean = false,
    /** Âm lượng âm phím riêng 0…100 %. */
    var keySoundVolume: Int = 50,
    /** Kiểu âm phím ([KeySoundStyle.id]) — mặc định "subtle" (Nhẹ nhàng). */
    var keySoundStyle: String = KeySoundStyle.DEFAULT.id,
    /** Gợi ý sửa lỗi chạm trượt (AdjacentKeyFixer) — mặc định BẬT. */
    var autoFixAdjacent: Boolean = true,
    /** Quyết định theo ngữ cảnh ("he is" giữ tiếng Anh) — mặc định BẬT. */
    var contextualEnglish: Boolean = true,
    /** Sửa dấu từ đã gõ xong (⌫ mở lại từ; phím dấu thanh nạp lại từ trước con trỏ) — mặc định BẬT. */
    var reEditWords: Boolean = true,
    /** Gõ vuốt (thử nghiệm) — mặc định TẮT; tắt ⇒ không dựng template, không ghi checkpoint. */
    var swipeTyping: Boolean = false,
    /**
     * Vuốt ra từ tiếng Anh (công tắc con của gõ vuốt) — mặc định BẬT: câu Việt chen từ
     * Anh rất thường (check mail, gửi file); decoder nghiêng Việt + biên độ nên chỉ ra
     * tiếng Anh khi hình vuốt thắng rõ / đang trong mạch Anh, và từ điển chỉ nạp khi gõ
     * vuốt đang bật. Giống iOS.
     */
    var swipeEnglish: Boolean = true,
    /** Giải mã vuốt bằng mô hình FUTO Swipe (thử nghiệm, mặc định TẮT — [FutoSwipe]). Giống iOS. */
    var swipeFuto: Boolean = false,
    /** Chọn phím theo ngữ cảnh lúc chạm vùng biên 2 phím (TouchTarget) — thử nghiệm, mặc định BẬT. */
    var smartTouch: Boolean = true,
    /** Tự sửa từ gõ sai ở dấu cách ([AutoCorrect]) — thử nghiệm, mặc định TẮT. Giống iOS. */
    var autoCorrect: Boolean = false,
    /** Tự động viết hoa đầu câu (auto-shift theo cờ CAP_* của ô) — mặc định BẬT. */
    var autoCapitalize: Boolean = true,
    /** Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh — mặc định TẮT. Giống iOS. */
    var spaceSwipeLanguage: Boolean = false,
    /** Tự thêm dấu cách sau . , ? ! ; : ([AutoSpace]) — mặc định TẮT; tắt ⇒ không đọc context. */
    var autoSpaceAfterPunct: Boolean = false,
    /** Telex cho bàn phím cứng — mặc định BẬT; tắt ⇒ IME không đụng KeyEvent. */
    var hardwareTelex: Boolean = true,
    /** Gõ tắt — mặc định BẬT, bảng mặc định RỖNG (như macOS; "Thêm bộ gợi ý" trong app). */
    var shortcutsEnabled: Boolean = true,
    var shortcuts: ShortcutTable = ShortcutTable(),
    // Phần UI (iOS đọc rải rác trong KeyboardView) — gom về đây cho IME.
    var templatesEnabled: Boolean = true,
    var showSpaceLogo: Boolean = true,
    /** Ô phóng to chữ khi bấm phím — mặc định BẬT; tắt ⇒ không tạo/vẽ balloon. */
    var keyPreview: Boolean = true,
    /** Phím sẫm khi bấm (phím chữ/số/ký hiệu) — mặc định BẬT như iOS; tắt ⇒ đường chạm không thêm việc. */
    var keyPressHighlight: Boolean = true,
    /** −10…10 dp mỗi hàng. */
    var rowHeightAdjust: Int = 0,
    /** Hàng phím số 1…0 trên hàng chữ — mặc định TẮT. */
    var numberRow: Boolean = false,
    /** Nâng bàn phím 0…[KEYBOARD_RAISE_MAX] dp (đệm nền dưới hàng đáy) — mặc định 0. */
    var keyboardRaise: Int = 0,
    /** Giữ q…p ra 1…0 (chỉ khi hàng số tắt) — mặc định BẬT. Giống iOS. */
    var longPressNumbers: Boolean = true,
    /** Giữ a–l, z–m ra ký hiệu — mặc định TẮT. Giống iOS. */
    var longPressSymbols: Boolean = false,
    /** Chế độ một tay: "off" | "left" | "right" — mặc định tắt (tablet bỏ qua). */
    var oneHandMode: String = "off",
    /** Bàn phím thả nổi (#112) — mặc định TẮT; bật ⇒ một tay + nâng bàn phím bị bỏ qua. */
    var floatingKeyboard: Boolean = false,
    var debugTouchLog: Boolean = false,
    /** Lịch sử clipboard — mặc định TẮT. */
    var clipboardHistory: Boolean = false,
    /** Ẩn danh thủ công: không học từ, không lưu clipboard. */
    var incognito: Boolean = false,
    /** Giá trị Keys.USERLM_RESET_AT (0 = chưa từng xoá). */
    var userlmResetAt: Long = 0,
) {
    companion object {
        /** Trần thanh "Nâng bàn phím" (dp). */
        const val KEYBOARD_RAISE_MAX = 48
        fun clampRaise(dp: Int): Int = dp.coerceIn(0, KEYBOARD_RAISE_MAX)

        /** [get] trả giá trị thô của key (vd `prefs.all[key]`), null nếu vắng. */
        fun load(get: (String) -> Any?): KeyboardSettings {
            val s = KeyboardSettings()
            fun b(key: String, cur: Boolean): Boolean = (get(key) as? Boolean) ?: cur
            s.freeMarking = b(Keys.FREE_MARKING, s.freeMarking)
            s.simpleTelex = b(Keys.SIMPLE_TELEX, s.simpleTelex)
            s.liveSpellCheck = b(Keys.LIVE_SPELL_CHECK, s.liveSpellCheck)
            s.autoRestore = b(Keys.AUTO_RESTORE, s.autoRestore)
            s.quickTelex = b(Keys.QUICK_TELEX, s.quickTelex)
            s.modernTone = b(Keys.MODERN_TONE, s.modernTone)
            s.teencode = b(Keys.TEENCODE, s.teencode)
            s.vniMode = b(Keys.VNI_MODE, s.vniMode)
            s.showSuggestions = b(Keys.SHOW_SUGGESTIONS, s.showSuggestions)
            s.filterSensitive = b(Keys.FILTER_SENSITIVE, s.filterSensitive)
            s.addTonesChip = b(Keys.ADD_TONES_CHIP, s.addTonesChip)
            s.numberChips = b(Keys.NUMBER_CHIPS, s.numberChips)
            s.mathResults = b(Keys.MATH_RESULTS, s.mathResults)
            s.suggestInNoSuggestFields = b(Keys.SUGGEST_IN_NO_SUGGEST_FIELDS, s.suggestInNoSuggestFields)
            s.hapticFeedback = b(Keys.HAPTIC_FEEDBACK, s.hapticFeedback)
            s.hapticStrength = HapticStrength.clamp((get(Keys.HAPTIC_STRENGTH) as? Number)?.toInt() ?: HapticStrength.DEFAULT)
            s.keySound = b(Keys.KEY_SOUND, s.keySound)
            s.keySoundVolume = ((get(Keys.KEY_SOUND_VOLUME) as? Number)?.toInt() ?: s.keySoundVolume).coerceIn(0, 100)
            s.keySoundStyle = (get(Keys.KEY_SOUND_STYLE) as? String)?.takeIf { it in KeySoundStyle.IDS } ?: KeySoundStyle.DEFAULT.id
            s.autoFixAdjacent = b(Keys.AUTO_FIX_ADJACENT, s.autoFixAdjacent)
            s.contextualEnglish = b(Keys.CONTEXTUAL_ENGLISH, s.contextualEnglish)
            s.reEditWords = b(Keys.RE_EDIT_WORDS, s.reEditWords)
            s.swipeTyping = b(Keys.SWIPE_TYPING, s.swipeTyping)
            s.swipeEnglish = b(Keys.SWIPE_ENGLISH, s.swipeEnglish)
            s.swipeFuto = b(Keys.SWIPE_FUTO, s.swipeFuto)
            s.smartTouch = b(Keys.SMART_TOUCH, s.smartTouch)
            s.autoCorrect = b(Keys.AUTO_CORRECT, s.autoCorrect)
            s.autoCapitalize = b(Keys.AUTO_CAPITALIZE, s.autoCapitalize)
            s.spaceSwipeLanguage = b(Keys.SPACE_SWIPE_LANGUAGE, s.spaceSwipeLanguage)
            s.autoSpaceAfterPunct = b(Keys.AUTO_SPACE_AFTER_PUNCT, s.autoSpaceAfterPunct)
            s.hardwareTelex = b(Keys.HARDWARE_TELEX, s.hardwareTelex)
            s.shortcutsEnabled = b(Keys.SHORTCUTS_ENABLED, s.shortcutsEnabled)
            if (s.shortcutsEnabled) s.shortcuts = ShortcutTable(ShortcutFile.parse(get(Keys.SHORTCUTS) as? String))
            s.templatesEnabled = b(Keys.TEMPLATES_ENABLED, s.templatesEnabled)
            s.showSpaceLogo = b(Keys.SHOW_SPACE_LOGO, s.showSpaceLogo)
            s.keyPreview = b(Keys.KEY_PREVIEW, s.keyPreview)
            s.keyPressHighlight = b(Keys.KEY_PRESS_HIGHLIGHT, s.keyPressHighlight)
            s.debugTouchLog = b(Keys.DEBUG_TOUCH_LOG, s.debugTouchLog)
            s.numberRow = b(Keys.NUMBER_ROW, s.numberRow)
            s.keyboardRaise = clampRaise((get(Keys.KEYBOARD_RAISE) as? Number)?.toInt() ?: 0)
            s.longPressNumbers = b(Keys.LONG_PRESS_NUMBERS, s.longPressNumbers)
            s.longPressSymbols = b(Keys.LONG_PRESS_SYMBOLS, s.longPressSymbols)
            s.oneHandMode = (get(Keys.ONE_HAND_MODE) as? String)?.takeIf { it == "left" || it == "right" } ?: "off"
            s.floatingKeyboard = b(Keys.FLOATING_KEYBOARD, s.floatingKeyboard)
            s.clipboardHistory = b(Keys.CLIPBOARD_HISTORY, s.clipboardHistory)
            s.incognito = b(Keys.INCOGNITO, s.incognito)
            s.rowHeightAdjust = ((get(Keys.ROW_HEIGHT_ADJUST) as? Number)?.toInt() ?: 0).coerceIn(-10, 10)
            s.userlmResetAt = (get(Keys.USERLM_RESET_AT) as? Number)?.toLong() ?: 0
            s.learnWords = s.showSuggestions   // bật gợi ý = bật học (quyết định 2026-07-24)
            return s
        }
    }
}
