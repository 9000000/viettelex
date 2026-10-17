package com.viettelex.keyboard

import kotlin.math.pow

/*
 * Theme bàn phím — MỌI token màu ở một chỗ (ARGB Int thuần, không phụ thuộc Android
 * để test JVM). Bảng màu y hệt iOS (iOS/Keyboard/KeyboardTheme.swift) — sửa màu thì
 * sửa cả hai. Vẽ phím vẫn phẳng: không bóng, không blur runtime.
 */

/** Tiện ích màu ARGB + tương phản WCAG 2.x. */
object ThemeColor {
    fun argb(a: Int, r: Int, g: Int, b: Int) = (a shl 24) or (r shl 16) or (g shl 8) or b
    fun rgb(hex: Int) = hex or (0xFF shl 24)
    fun alpha(c: Int) = (c ushr 24) and 0xFF
    fun red(c: Int) = (c shr 16) and 0xFF
    fun green(c: Int) = (c shr 8) and 0xFF
    fun blue(c: Int) = c and 0xFF
    fun withAlpha(c: Int, a: Float): Int =
        argb((alpha(c) * a).toInt().coerceIn(0, 255), red(c), green(c), blue(c))

    const val WHITE = -0x1          // 0xFFFFFFFF
    const val BLACK = -0x1000000    // 0xFF000000

    /** Trộn [fg] (có alpha) lên nền [bg] (coi như đục) → màu đục. */
    fun over(fg: Int, bg: Int): Int {
        val a = alpha(fg) / 255f
        fun ch(f: Int, b: Int) = (f * a + b * (1 - a) + 0.5f).toInt().coerceIn(0, 255)
        return argb(255, ch(red(fg), red(bg)), ch(green(fg), green(bg)), ch(blue(fg), blue(bg)))
    }

    fun luminance(c: Int): Double {
        fun ch(v: Int): Double { val s = v / 255.0; return if (s <= 0.03928) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4) }
        return 0.2126 * ch(red(c)) + 0.7152 * ch(green(c)) + 0.0722 * ch(blue(c))
    }

    /** Tỉ lệ tương phản WCAG (1…21), bỏ qua alpha. */
    fun contrast(x: Int, y: Int): Double {
        val a = luminance(x); val b = luminance(y)
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }
}

/** Bộ token đã giải (theo sáng/tối + ảnh nền). */
data class ThemePalette(
    /** Nền bàn phím; [bgBottom] ≠ null ⇒ gradient dọc (Kính giả lập — Android không có backdrop mờ). */
    val bg: Int,
    val bgBottom: Int? = null,
    val keyFill: Int,
    /** Phím chức năng (Android: nền riêng như Gboard). */
    val specialFill: Int,
    val ink: Int,
    val trail: Int,
    val balloon: Int,
    val popup: Int,
    val action: Int,
    val actionInk: Int,
    val chip: Int,
    /** Viền phím 1dp (tương phản cao / kính) — stroke thường, không offscreen. */
    val keyBorder: Int? = null,
    val isDark: Boolean,
    /** true ⇒ nền là ảnh nền (IME vẽ bitmap + lớp phủ thay cho [bg]). */
    val wallpaper: Boolean = false,
    /** Chữ/icon trên phím (ĐỤC) sau độ trong suốt phím; null = [ink]. Balloon/popup giữ [ink]. */
    val keyLabel: Int? = null,
    /** Alpha chữ/icon trên phím (độ trong suốt ký tự) — IME nhân vào alpha lúc vẽ. */
    val labelAlpha: Float = 1f,
    /**
     * Hệ số alpha bề mặt PHÍM theo độ trong suốt phím (1 = như cũ). KHÔNG áp cho ảnh nền —
     * ảnh nền có độ tối/mờ riêng ([wallpaperLayer]).
     */
    val surfaceAlpha: Float = 1f,
    /** Chữ trên phím do người dùng chọn ([KeyStyle]) — độ trong suốt không đổi sang đen/trắng. */
    val keyLabelPinned: Boolean = false,
) {
    val keyInk: Int get() = keyLabel ?: ink

    /** Lớp phủ ảnh nền: đen cho theme tối, trắng cho theme sáng. */
    val wallpaperOverlay: Int get() = if (isDark) ThemeColor.BLACK else ThemeColor.WHITE

    /**
     * Cách vẽ ảnh nền (mô hình vẽ thuần — IME + bản xem trước dùng chung): ảnh luôn ĐỤC, lớp phủ
     * theo "Độ tối lớp phủ". Độ trong suốt phím KHÔNG làm mất ảnh nền (bug 100% trước đây: ảnh +
     * lớp phủ nhân surfaceAlpha ⇒ 0 ⇒ ảnh biến mất).
     */
    fun wallpaperLayer(dim: Int): WallpaperLayer =
        WallpaperLayer(1f, ThemeColor.withAlpha(wallpaperOverlay, dim.coerceIn(0, 80) / 100f))

    /**
     * Có ảnh nền: phím hơi trong để ảnh lộ ra. Độ trong chọn sao cho chữ ≥ 4.5:1 (AA)
     * kể cả trên ảnh TỆ NHẤT (trắng dưới theme tối, đen dưới theme sáng), lớp phủ 0%.
     */
    fun overWallpaper(): ThemePalette {
        val worst = if (isDark) ThemeColor.WHITE else ThemeColor.BLACK
        fun legible(base: Int): Int {
            val translucent = ThemeColor.alpha(base) < 255
            val solid = if (translucent) (if (isDark) ThemeColor.BLACK else ThemeColor.WHITE) else base
            var a = if (translucent) 0.5f else WALLPAPER_KEY_ALPHA
            while (a < 1f && ThemeColor.contrast(ink, ThemeColor.over(ThemeColor.withAlpha(solid, a), worst)) < 4.5) a += 0.05f
            return ThemeColor.withAlpha(solid, a.coerceAtMost(1f))
        }
        return copy(keyFill = legible(keyFill), specialFill = legible(specialFill), bgBottom = null, wallpaper = true)
    }

    companion object { const val WALLPAPER_KEY_ALPHA = 0.8f }
}

/** Ảnh nền: alpha bitmap + màu lớp phủ (ARGB). */
data class WallpaperLayer(val imageAlpha: Float, val overlay: Int)

/**
 * Độ trong suốt (Cài đặt → Giao diện), hai thanh độc lập 0…100% — y hệt iOS
 * (KeyboardTransparency trong iOS/Keyboard/KeyboardTheme.swift):
 * - phím: nền phím + viền (+ nền theme khi KHÔNG có ảnh nền); 100% = phím vô hình, chỉ còn chữ.
 *   Ảnh nền luôn giữ nguyên (đã có độ tối/mờ riêng).
 * - ký tự: chữ/icon/nhãn phụ trên phím; 100% = phím trơn không chữ.
 * Áp bằng alpha của MÀU lúc dựng theme — không alpha nhóm, 0 chi phí mỗi phím.
 */
object KeyboardTransparency {
    /** Chữ phím ≥ 18sp = "chữ lớn" WCAG → 3:1; dưới ngưỡng mới đổi sang đen/trắng. */
    const val MIN_LABEL_CONTRAST = 3.0

    fun clamp(v: Int) = v.coerceIn(0, 100)
    /** 0% → 1 (như cũ), 100% → 0. */
    fun alpha(pct: Int) = 1f - clamp(pct) / 100f

    /**
     * Thứ lộ ra sau cửa sổ IME trong suốt: cửa sổ app (nền windowBackground — thường
     * trắng / tối Material). Không đo được từ IME → ước lượng theo sáng/tối hệ thống.
     */
    fun systemBackdrop(dark: Boolean) = if (dark) ThemeColor.rgb(0x121212) else ThemeColor.rgb(0xFFFFFF)

    /** Giữ [ink] nếu còn đọc được trên [bg]; không thì đen/trắng (cái tương phản hơn). */
    fun readable(ink: Int, bg: Int): Int {
        val c = ThemeColor
        if (c.contrast(ink, bg) >= MIN_LABEL_CONTRAST) return ink
        val alt = if (c.contrast(c.WHITE, bg) >= c.contrast(c.BLACK, bg)) c.WHITE else c.BLACK
        return if (c.contrast(alt, bg) > c.contrast(ink, bg)) alt else ink
    }
}

fun ThemePalette.withTransparency(keyboard: Int, labels: Int, systemDark: Boolean): ThemePalette {
    val t = KeyboardTransparency
    val k = t.clamp(keyboard); val l = t.clamp(labels)
    if (k == 0 && l == 0) return this
    var p = copy(labelAlpha = t.alpha(l))
    if (k > 0) {
        val s = t.alpha(k)
        val c = ThemeColor
        fun f(x: Int) = c.withAlpha(x, s)
        p = p.copy(bg = f(bg), bgBottom = bgBottom?.let(::f), keyFill = f(keyFill), specialFill = f(specialFill),
            action = f(action), chip = f(chip), keyBorder = keyBorder?.let(::f), surfaceAlpha = s)
        // Nền thật sau chữ ≈ lớp nền mới trên cửa sổ app. Ảnh nền vẫn hiện nguyên ⇒ ước lượng
        // bằng tông lớp phủ (tối cho theme tối, sáng cho theme sáng).
        val sys = t.systemBackdrop(systemDark)
        val behind = c.over(if (wallpaper) wallpaperOverlay else p.bg, sys)
        val label = if (keyLabelPinned) ink else t.readable(ink, c.over(p.keyFill, behind))
        p = p.copy(keyLabel = label, actionInk = t.readable(actionInk, c.over(p.action, behind)),
            isDark = if (label != ink) c.luminance(label) > 0.5 else isDark)
    }
    return p
}

enum class KeyboardTheme(val id: String, val viTitle: String, val isPlus: Boolean) {
    SYSTEM("system", "Hệ thống", false),
    OLED("oled", "Tối OLED", false),
    /** Trợ năng → luôn miễn phí. */
    CONTRAST("contrast", "Tương phản cao", false),
    PEACH("peach", "Hồng đào", true),
    MINT("mint", "Bạc hà", true),
    SKY("sky", "Trời xanh", true),
    LAVENDER("lavender", "Oải hương", true),
    GLASS("glass", "Kính", true);

    /** Tên hiển thị theo ngôn ngữ giao diện ([L10n]); [viTitle] = khoá dịch. */
    val title: String get() = tr(viTitle)

    /**
     * Palette cố định của theme; SYSTEM trả null (IME dùng màu Material You trong
     * resources như trước — không đổi hình người dùng cũ).
     */
    fun palette(systemDark: Boolean): ThemePalette? {
        val c = ThemeColor
        return when (this) {
            SYSTEM -> null
            OLED -> ThemePalette(bg = c.BLACK, keyFill = c.rgb(0x1C1C1E), specialFill = c.rgb(0x3A3A3C),
                ink = c.WHITE, trail = c.withAlpha(c.WHITE, 0.6f), balloon = c.rgb(0x2C2C2E),
                popup = c.rgb(0x2C2C2E), action = c.rgb(0x0A84FF), actionInk = c.WHITE,
                chip = c.rgb(0x3A3A3C), isDark = true)
            CONTRAST -> ThemePalette(bg = c.BLACK, keyFill = c.rgb(0x141414), specialFill = c.rgb(0x4D4D4D),
                ink = c.WHITE, trail = c.rgb(0xFFD60A), balloon = c.rgb(0x141414), popup = c.rgb(0x141414),
                action = c.rgb(0xFFD60A), actionInk = c.BLACK, chip = c.rgb(0x4D4D4D),
                keyBorder = c.withAlpha(c.WHITE, 0.85f), isDark = true)
            PEACH -> pastel(0xFBE3E1, 0xFFF8F7, 0xF1C4BF, 0x4A2226, 0xC2505A)
            MINT -> pastel(0xD9F2E7, 0xF6FFFA, 0xAFDDC9, 0x173B30, 0x1F7A5C)
            SKY -> pastel(0xDAE9F8, 0xF6FAFF, 0xB3CFEE, 0x14304C, 0x2C6BB8)
            LAVENDER -> pastel(0xE8E2F6, 0xFBF9FF, 0xCBBFEA, 0x2C2345, 0x6A48C4)
            // Android không có backdrop mờ sau cửa sổ IME → giả lập: gradient dịu +
            // phím trắng bán trong + viền sáng mảnh.
            GLASS -> if (systemDark) ThemePalette(bg = c.rgb(0x2B3040), bgBottom = c.rgb(0x16181F),
                keyFill = c.withAlpha(c.WHITE, 0.16f), specialFill = c.withAlpha(c.WHITE, 0.08f),
                ink = c.WHITE, trail = c.withAlpha(c.WHITE, 0.6f), balloon = c.rgb(0x4A4A4E),
                popup = c.rgb(0x3A3D48), action = c.rgb(0xA8C7FA), actionInk = c.rgb(0x062E6F),
                chip = c.withAlpha(c.WHITE, 0.3f), keyBorder = c.withAlpha(c.WHITE, 0.18f), isDark = true)
            else ThemePalette(bg = c.rgb(0xDCE6F2), bgBottom = c.rgb(0xC5D0DE),
                keyFill = c.withAlpha(c.WHITE, 0.55f), specialFill = c.withAlpha(c.WHITE, 0.3f),
                ink = c.rgb(0x1F1F1F), trail = c.withAlpha(c.rgb(0x0B57D0), 0.6f), balloon = c.WHITE,
                popup = c.WHITE, action = c.rgb(0x0B57D0), actionInk = c.WHITE,
                chip = c.withAlpha(c.WHITE, 0.8f), keyBorder = c.withAlpha(c.WHITE, 0.6f), isDark = false)
        }
    }

    companion object {
        fun of(id: String?): KeyboardTheme = entries.firstOrNull { it.id == id } ?: SYSTEM

        private fun pastel(bg: Int, key: Int, special: Int, ink: Int, accent: Int): ThemePalette {
            val c = ThemeColor
            return ThemePalette(bg = c.rgb(bg), keyFill = c.rgb(key), specialFill = c.rgb(special),
                ink = c.rgb(ink), trail = c.withAlpha(c.rgb(accent), 0.6f), balloon = c.rgb(key),
                popup = c.rgb(key), action = c.rgb(accent), actionInk = c.WHITE, chip = c.rgb(special),
                isDark = false)
        }
    }
}

/**
 * Cổng Plus cho theme — dùng [PlusGate] thật: [PlusFeature.PREMIUM_THEMES] gồm theme
 * cao cấp + ảnh nền. Hệ thống/OLED/tương phản cao luôn miễn phí.
 */
object ThemeGate {
    fun allows(t: KeyboardTheme) = !t.isPlus || PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES)
    val allowsWallpaper: Boolean get() = PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES)
    /** "Tuỳ chỉnh nâng cao" đi cùng quyền theme cao cấp (Plus). */
    val allowsAdvanced: Boolean get() = PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES)
}

/** Cài đặt giao diện — app ghi, IME đọc mỗi lần dựng input view. */
data class ThemeSettings(
    val theme: KeyboardTheme = KeyboardTheme.SYSTEM,
    val wallpaper: Boolean = false,
    /** % lớp phủ 0…80. */
    val dim: Int = 30,
    /** Bán kính mờ 0…20 — app áp lúc lưu ảnh, IME chỉ hiện. */
    val blur: Int = 0,
    /** Đổi mỗi lần lưu ảnh → IME bỏ bitmap cũ. */
    val version: Long = 0,
    /** Độ trong suốt phím / ký tự 0…100 (miễn phí, mọi theme). */
    val keyboardTransparency: Int = 0,
    val labelTransparency: Int = 0,
    /**
     * Khung cắt đã chỉnh (null = ảnh cũ / chưa chỉnh → cắt giữa). Thuộc về ẢNH (như file) nên
     * "Khôi phục giao diện gốc" giữ nguyên.
     */
    val crop: WallpaperCrop? = null,
    /** "Tuỳ chỉnh nâng cao" (Plus) — lưu nguyên kể cả khi hết quyền; áp qua [effectiveKeyStyle]. */
    val keyStyle: KeyStyle = KeyStyle.DEFAULT,
) {
    /**
     * "Khôi phục giao diện gốc": mọi chỉnh ở màn Giao diện về mặc định. Ảnh nền chỉ bỏ
     * chọn (file giữ để bật lại); version giữ nguyên (không vứt bitmap cache vô cớ).
     */
    fun resetToDefaults() = ThemeSettings(version = version, crop = crop)
    val isDefault: Boolean get() = this == resetToDefaults()

    val effectiveTheme: KeyboardTheme get() = if (ThemeGate.allows(theme)) theme else KeyboardTheme.SYSTEM
    fun wallpaperActive(fileExists: Boolean) = wallpaper && fileExists && ThemeGate.allowsWallpaper
    /** Tuỳ chỉnh nâng cao thực dùng: hết quyền Plus ⇒ mặc định (giá trị lưu giữ nguyên). */
    val effectiveKeyStyle: KeyStyle get() = if (ThemeGate.allowsAdvanced) keyStyle else KeyStyle.DEFAULT

    fun toMap(): Map<String, Any> = mapOf(Keys.KEYBOARD_THEME to theme.id, Keys.WALLPAPER_ENABLED to wallpaper,
        Keys.WALLPAPER_DIM to dim, Keys.WALLPAPER_BLUR to blur, Keys.WALLPAPER_VERSION to version,
        Keys.KEYBOARD_TRANSPARENCY to keyboardTransparency, Keys.KEY_LABEL_TRANSPARENCY to labelTransparency) +
        (crop?.let { mapOf(Keys.WALLPAPER_CROP to it.serialize()) } ?: emptyMap()) + keyStyle.toMap()

    companion object {
        fun load(get: (String) -> Any?) = ThemeSettings(
            theme = KeyboardTheme.of(get(Keys.KEYBOARD_THEME) as? String),
            wallpaper = get(Keys.WALLPAPER_ENABLED) as? Boolean ?: false,
            dim = ((get(Keys.WALLPAPER_DIM) as? Number)?.toInt() ?: 30).coerceIn(0, 80),
            blur = ((get(Keys.WALLPAPER_BLUR) as? Number)?.toInt() ?: 0).coerceIn(0, 20),
            version = (get(Keys.WALLPAPER_VERSION) as? Number)?.toLong() ?: 0,
            keyboardTransparency = KeyboardTransparency.clamp((get(Keys.KEYBOARD_TRANSPARENCY) as? Number)?.toInt() ?: 0),
            labelTransparency = KeyboardTransparency.clamp((get(Keys.KEY_LABEL_TRANSPARENCY) as? Number)?.toInt() ?: 0),
            crop = WallpaperCrop.parse(get(Keys.WALLPAPER_CROP) as? String),
            keyStyle = KeyStyle.load(get),
        )
    }
}

/** Toán ảnh nền thuần (test JVM): cỡ lưu, inSampleSize, mờ hộp 3 lượt ≈ Gauss. */
object WallpaperMath {
    const val MAX_EDGE = 1080
    const val MAX_BYTES = 400_000
    /** Bản gốc giữ để chỉnh khung về sau — cạnh dài ≤ chừng này. */
    const val SOURCE_MAX_EDGE = 2048

    /**
     * Cỡ px ảnh nướng cho IME từ bản gốc iw×ih + khung [crop] (null = cả ảnh, như cũ).
     * Mật độ điểm ảnh = đúng bản cũ (cả ảnh thu ≤[MAX_EDGE]) × zoom, kẹp cạnh dài ≤[MAX_EDGE]
     * và không phóng to ⇒ ở khung mặc định (zoom 1) IME giải ĐÚNG bằng số điểm ảnh như trước;
     * zoom vào thì nét hơn nhưng không bao giờ vượt trần cũ (file ≤1080 px).
     */
    fun bakedSize(iw: Int, ih: Int, crop: WallpaperCrop?): Pair<Int, Int> {
        if (crop == null || iw <= 0 || ih <= 0) return targetSize(iw, ih)
        val r = crop.pixelRect(iw, ih)
        val cw = r[2] - r[0]; val ch = r[3] - r[1]
        val base = minOf(1.0, MAX_EDGE.toDouble() / maxOf(iw, ih))
        val s = minOf(1.0, base * crop.zoom(iw, ih), MAX_EDGE.toDouble() / maxOf(cw, ch))
        return maxOf(1, Math.round(cw * s).toInt()) to maxOf(1, Math.round(ch * s).toInt())
    }

    /**
     * Ước lượng cỡ px vùng bàn phím dọc khi IME chưa từng đo (xem [Keys.IME_PORTRAIT_SIZE]):
     * vùng phím + strip gợi ý mở + đệm thanh điều hướng.
     */
    fun estimatePortraitPx(screenShortPx: Int, density: Float, keyAreaDp: Float, stripDp: Float, navPx: Int): Pair<Int, Int> =
        screenShortPx to Math.round((keyAreaDp + stripDp) * density + navPx)

    /** "w×h" → cặp px dương, sai ⇒ null. */
    fun parseSize(s: String?): Pair<Int, Int>? {
        val p = s?.split("x")?.mapNotNull { it.trim().toIntOrNull() } ?: return null
        return if (p.size == 2 && p[0] > 0 && p[1] > 0 && p[0] < 20000 && p[1] < 20000) p[0] to p[1] else null
    }

    /** Cỡ lưu: cạnh dài ≤ [maxEdge], giữ tỉ lệ, không phóng to. */
    fun targetSize(w: Int, h: Int, maxEdge: Int = MAX_EDGE): Pair<Int, Int> {
        val long = maxOf(w, h)
        if (long <= maxEdge) return w to h
        val s = maxEdge.toDouble() / long
        return maxOf(1, Math.round(w * s).toInt()) to maxOf(1, Math.round(h * s).toInt())
    }

    /** inSampleSize (lũy thừa 2) lớn nhất mà ảnh giải ra vẫn ≥ req ở cả hai chiều. */
    fun sampleSize(srcW: Int, srcH: Int, reqW: Int, reqH: Int): Int {
        var s = 1
        while (srcW / (s * 2) >= reqW && srcH / (s * 2) >= reqH) s *= 2
        return s
    }

    /** Cỡ cần giải để aspect-fill view vw×vh px (kẹp ≤ bản lưu). */
    fun fillSize(imgW: Int, imgH: Int, vw: Int, vh: Int): Pair<Int, Int> {
        if (vw <= 0 || vh <= 0 || imgW <= 0 || imgH <= 0) return imgW to imgH
        val s = maxOf(vw.toDouble() / imgW, vh.toDouble() / imgH).coerceAtMost(1.0)
        return maxOf(1, Math.ceil(imgW * s).toInt()) to maxOf(1, Math.ceil(imgH * s).toInt())
    }

    /**
     * Vùng ảnh THẤY ĐƯỢC khi aspect-fill (center-crop) view vw×vh: [left, top, right, bottom]
     * theo px ảnh gốc — IME chỉ giải vùng này (BitmapRegionDecoder), không giải cả ảnh.
     */
    fun visibleCrop(imgW: Int, imgH: Int, vw: Int, vh: Int): IntArray {
        if (vw <= 0 || vh <= 0 || imgW <= 0 || imgH <= 0) return intArrayOf(0, 0, imgW, imgH)
        val s = maxOf(vw.toDouble() / imgW, vh.toDouble() / imgH)
        val cw = minOf(imgW, Math.ceil(vw / s - 1e-9).toInt().coerceAtLeast(1))
        val ch = minOf(imgH, Math.ceil(vh / s - 1e-9).toInt().coerceAtLeast(1))
        val l = (imgW - cw) / 2; val t = (imgH - ch) / 2
        return intArrayOf(l, t, l + cw, t + ch)
    }

    /**
     * Kế hoạch giải của IME cho file w×h trên view vw×vh: [left, top, right, bottom, inSampleSize]
     * — chỉ vùng thấy được (cắt giữa), sample vừa phủ view. File đã nướng theo khung ⇒ vùng =
     * gần cả file ở hướng dọc, dải giữa ([WallpaperCrop.landscape]) ở hướng ngang.
     */
    fun decodePlan(w: Int, h: Int, vw: Int, vh: Int): IntArray {
        val c = visibleCrop(w, h, vw, vh)
        val (needW, needH) = fillSize(w, h, vw, vh)
        return intArrayOf(c[0], c[1], c[2], c[3], sampleSize(w, h, needW, needH))
    }

    /** Mờ hộp 3 lượt (ngang + dọc) trên ARGB — thay RenderScript đã bỏ. In-place. */
    fun blur(px: IntArray, w: Int, h: Int, radius: Int) {
        if (radius <= 0 || w <= 0 || h <= 0) return
        val tmp = IntArray(px.size)
        val r = maxOf(1, radius / 2)   // 3 lượt hộp bán kính r ≈ Gauss σ≈radius
        repeat(3) {
            boxPass(px, tmp, w, h, r, horizontal = true)
            boxPass(tmp, px, w, h, r, horizontal = false)
        }
    }

    private fun boxPass(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val lines = if (horizontal) h else w
        val len = if (horizontal) w else h
        val div = 2 * r + 1
        for (line in 0 until lines) {
            fun idx(i: Int): Int { val k = i.coerceIn(0, len - 1); return if (horizontal) line * w + k else k * w + line }
            var sa = 0; var sr = 0; var sg = 0; var sb = 0
            for (i in -r..r) { val c = src[idx(i)]; sa += c ushr 24; sr += (c shr 16) and 0xFF; sg += (c shr 8) and 0xFF; sb += c and 0xFF }
            for (i in 0 until len) {
                dst[idx(i)] = ((sa / div) shl 24) or ((sr / div) shl 16) or ((sg / div) shl 8) or (sb / div)
                val out = src[idx(i - r)]; val inn = src[idx(i + r + 1)]
                sa += (inn ushr 24) - (out ushr 24)
                sr += ((inn shr 16) and 0xFF) - ((out shr 16) and 0xFF)
                sg += ((inn shr 8) and 0xFF) - ((out shr 8) and 0xFF)
                sb += (inn and 0xFF) - (out and 0xFF)
            }
        }
    }
}
