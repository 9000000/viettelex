import UIKit
import CoreText

// Theme bàn phím — MỌI token màu ở một chỗ (dùng chung Keyboard + App + test).
// Android giữ bảng y hệt ở android/keyboard/.../KeyboardTheme.kt — sửa màu thì
// sửa cả hai. Vẽ phím vẫn phẳng: không bóng, không blur runtime, không offscreen
// pass (xem lịch sử bỏ shadow trong KeyboardView). Kính = để lộ backdrop mờ SẴN
// CÓ của hệ thống + phím bán trong suốt, không tự blur.

/// Màu RGBA thuần (0…1) — tách khỏi UIColor để test tính tương phản.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }
    static let white = RGBA(hex: 0xFFFFFF), black = RGBA(hex: 0x000000)
    func alpha(_ x: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * x) }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    /// Trộn màu này (có alpha) lên nền đục.
    func over(_ bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a))
    }
    /// Độ chói tương đối WCAG 2.x.
    var luminance: Double {
        func ch(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }
    /// Tỉ lệ tương phản WCAG (1…21), cả hai màu coi như đục.
    static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let a = x.luminance, b = y.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Bộ token một theme đã giải (theo sáng/tối hệ thống + ảnh nền).
struct KeyboardPalette: Equatable {
    /// nil = nền trong suốt (backdrop hệ thống lộ ra: theme Hệ thống, Kính).
    var background: RGBA?
    var keyFill: RGBA
    /// Phím chức năng khi ĐÈ (iOS 26+: mọi phím cùng nền, đè thì sẫm lại).
    var specialFill: RGBA
    var ink: RGBA
    var trail: RGBA
    /// Chữ/icon thanh gợi ý.
    var barInk: RGBA
    var balloon: RGBA
    /// Phím return dạng hành động (go/search/send…).
    var accent: RGBA
    var accentInk: RGBA
    /// Viền phím 1pt (chỉ theme tương phản cao) — borderWidth không gây offscreen.
    var keyBorder: RGBA?
    /// Chữ sáng trên nền tối → icon hệ thống, emoji plane, … đi theo nhánh tối.
    var isDark: Bool
    /// Chữ/icon TRÊN PHÍM sau hai thanh trượt độ trong suốt; nil = `ink`.
    /// `ink` giữ nguyên cho balloon/popup — phản hồi khi gõ luôn rõ.
    var keyLabel: RGBA? = nil
    /// Hệ số alpha của bề mặt PHÍM (nền phím, viền, phím shift bật) theo độ trong suốt phím
    /// (1 = như cũ). KHÔNG áp cho ảnh nền — ảnh nền có độ tối/mờ riêng (wallpaperLayer).
    var surfaceAlpha: Double = 1
    /// Chữ trên phím do người dùng chọn (Tuỳ chỉnh nâng cao) — độ trong suốt không đổi
    /// nó sang đen/trắng.
    var keyLabelPinned = false

    /// Nền phía sau phần KHÔNG phải phím (thanh gợi ý, bảng emoji, ô tìm emoji) tối hay sáng;
    /// nil = `isDark`. Khác `isDark` khi theme tự vẽ phím nhưng nền theo hệ thống.
    var surfaceDark: Bool? = nil

    var keyInk: RGBA { keyLabel ?? ink }

    /// "Nền theo hệ thống": bỏ nền theme (vật liệu bàn phím hệ thống lộ ra, cùng màu dải
    /// 🌐/🎤), GIỮ màu phím. Chữ thanh gợi ý đổi đen/trắng nếu không đọc được trên nền đó.
    func onSystemBackdrop(systemDark: Bool) -> KeyboardPalette {
        var p = self
        p.background = nil
        p.barInk = KeyboardTransparency.readable(barInk, on: KeyboardTransparency.systemBackdrop(dark: systemDark))
        p.surfaceDark = systemDark
        return p
    }

    /// Có ảnh nền: phím hơi trong để ảnh lộ ra; lớp phủ (dim) do view vẽ riêng.
    /// Độ trong được chọn sao cho chữ vẫn ≥ 4.5:1 (WCAG AA) kể cả trên ảnh TỆ NHẤT
    /// (trắng tuyền dưới theme tối, đen tuyền dưới theme sáng) và lớp phủ 0%.
    static let wallpaperKeyAlpha = 0.8
    func overWallpaper() -> KeyboardPalette {
        let worst: RGBA = isDark ? .white : .black
        func legible(_ base: RGBA) -> RGBA {
            // Theme phím vốn trong (Kính): đổi sang phím phủ đen/trắng bán trong.
            let translucent = base.a < 1
            let solid = translucent ? (isDark ? RGBA.black : RGBA.white) : base
            var a = translucent ? 0.5 : Self.wallpaperKeyAlpha
            while a < 1, RGBA.contrast(ink, solid.alpha(a).over(worst)) < 4.5 { a += 0.05 }
            return solid.alpha(min(a, 1))
        }
        var p = self
        p.keyFill = legible(keyFill)
        p.specialFill = legible(specialFill)
        p.background = nil
        return p
    }
    /// Màu lớp phủ ảnh nền: tối cho theme tối, sáng cho theme sáng.
    var wallpaperOverlay: RGBA { isDark ? .black : .white }

    /// Cách vẽ ảnh nền (mô hình vẽ thuần — KeyboardView + bản xem trước dùng chung): ảnh luôn
    /// ĐỤC, lớp phủ theo "Độ tối lớp phủ". Độ trong suốt phím KHÔNG làm mất ảnh nền (bug 100%
    /// trước đây: ảnh + lớp phủ nhân surfaceAlpha ⇒ 0 ⇒ ảnh biến mất).
    func wallpaperLayer(dim: Int) -> (imageAlpha: Double, overlay: RGBA) {
        (1, wallpaperOverlay.alpha(Double(max(0, min(80, dim))) / 100))
    }
}

/// Độ trong suốt (Cài đặt → Giao diện), hai thanh độc lập 0…100%:
/// - phím: nền phím + viền (+ nền theme khi KHÔNG có ảnh nền); 100% = phím vô hình, chỉ còn
///   chữ. Ảnh nền luôn giữ nguyên (đã có độ tối/mờ riêng).
/// - ký tự: chữ/icon/nhãn phụ trên phím; 100% = phím trơn không chữ.
/// Áp bằng alpha của MÀU lúc dựng palette — không alpha nhóm (không offscreen pass,
/// không làm mờ chữ theo), 0 chi phí mỗi phím. Balloon/popup không đổi.
/// Android giữ y hệt ở android/keyboard/.../KeyboardTheme.kt.
enum KeyboardTransparency {
    static let keyboardKey = "keyboardTransparency"
    static let labelKey = "keyLabelTransparency"
    /// Chữ trên phím ≥ 18pt = "chữ lớn" WCAG → ngưỡng 3:1. Dưới ngưỡng (vì nền đã
    /// trong suốt, lộ nền khác tông) mới đổi sang đen/trắng.
    static let minLabelContrast = 3.0

    static func clamp(_ v: Int) -> Int { max(0, min(100, v)) }
    /// 0% → 1 (như cũ), 100% → 0.
    static func alpha(_ pct: Int) -> Double { 1 - Double(clamp(pct)) / 100 }

    /// Nền hệ thống sau input view: iOS luôn có lớp kính bàn phím (không gỡ được) —
    /// tối đo từ stock iOS 27 (#202020), sáng xấp xỉ kính sáng.
    static func systemBackdrop(dark: Bool) -> RGBA { dark ? RGBA(hex: 0x202020) : RGBA(hex: 0xD4D6DC) }

    /// Giữ `ink` nếu còn đọc được trên `bg`; không thì đen/trắng (cái tương phản hơn).
    static func readable(_ ink: RGBA, on bg: RGBA) -> RGBA {
        guard RGBA.contrast(ink, bg) < minLabelContrast else { return ink }
        let alt: RGBA = RGBA.contrast(.white, bg) >= RGBA.contrast(.black, bg) ? .white : .black
        return RGBA.contrast(alt, bg) > RGBA.contrast(ink, bg) ? alt : ink
    }
}

extension KeyboardPalette {
    func withTransparency(keyboard: Int, labels: Int, systemDark: Bool,
                          wallpaper: Bool) -> KeyboardPalette {
        typealias T = KeyboardTransparency
        let k = T.clamp(keyboard), l = T.clamp(labels)
        guard k > 0 || l > 0 else { return self }
        var p = self
        var label = ink
        if k > 0 {
            let s = T.alpha(k)
            p.surfaceAlpha = s
            p.background = background?.alpha(s)
            p.keyFill = keyFill.alpha(s)
            p.specialFill = specialFill.alpha(s)
            p.accent = accent.alpha(s)
            p.keyBorder = keyBorder?.alpha(s)
            // Nền thật sau chữ ≈ lớp nền mới trên backdrop hệ thống. Ảnh nền vẫn hiện nguyên
            // ⇒ ước lượng bằng tông lớp phủ (tối cho theme tối, sáng cho theme sáng).
            let sys = T.systemBackdrop(dark: systemDark)
            let behind = (wallpaper ? wallpaperOverlay : p.background)?.over(sys) ?? sys
            if !keyLabelPinned { label = T.readable(ink, on: p.keyFill.over(behind)) }
            p.barInk = T.readable(barInk, on: behind)
            p.accentInk = T.readable(accentInk, on: p.accent.over(behind))
            if label != ink { p.isDark = label.luminance > 0.5 }
        }
        let la = T.alpha(l)
        p.keyLabel = label.alpha(la)
        p.accentInk = p.accentInk.alpha(la)
        return p
    }
}

enum KeyboardTheme: String, CaseIterable {
    case system, oled, contrast, peach, mint, sky, lavender, glass

    var title: String {
        switch self {
        case .system: return L("Hệ thống")
        case .oled: return L("Tối OLED")
        case .contrast: return L("Tương phản cao")
        case .peach: return L("Hồng đào")
        case .mint: return L("Bạc hà")
        case .sky: return L("Trời xanh")
        case .lavender: return L("Oải hương")
        case .glass: return L("Kính")
        }
    }

    /// Theme tự vẽ nền (OLED, tương phản cao, pastel) — có tuỳ chọn "Nền theo hệ thống".
    /// Hệ thống / Kính vốn trong suốt.
    var hasOwnBackground: Bool { palette(systemDark: false).background != nil }

    /// Key App Group + sao lưu của "Nền theo hệ thống" cho theme này ("systemBackdropOled"…);
    /// nil = theme vốn trong suốt (không có tuỳ chọn).
    var systemBackdropKey: String? {
        guard hasOwnBackground else { return nil }
        return "systemBackdrop" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Theme cao cấp thuộc gói Plus. Tương phản cao là trợ năng → luôn miễn phí.
    var isPlus: Bool {
        switch self {
        case .system, .oled, .contrast: return false
        case .peach, .mint, .sky, .lavender, .glass: return true
        }
    }

    func palette(systemDark: Bool) -> KeyboardPalette {
        let blue = RGBA(r: 0, g: 0.478, b: 1)   // ≈ systemBlue
        switch self {
        case .system:
            // Sáng: giá trị cũ của KeyboardView. Tối: theo bàn phím STOCK iOS 27 (đo pixel
            // ảnh chụp simulator iPhone 17, English US, dark, 27/09/2026): nền #202020, MỌI
            // phím (chữ, shift, ⌫, 123, space, return) #444444, chữ trắng. Trước đây
            // #6B6B6B (phím chữ iOS ≤ 18, KeyboardKit standardButtonBackground dark) — sáng
            // hơn hẳn stock iOS 26/27 (góp ý user). Đè phím: sẫm lại về phía nền.
            return systemDark
                ? KeyboardPalette(background: nil, keyFill: RGBA(hex: 0x444444),
                                  specialFill: RGBA(hex: 0x2E2E2E), ink: .white,
                                  trail: RGBA.white.alpha(0.55), barInk: .white,
                                  balloon: RGBA(r: 0.35, g: 0.35, b: 0.35),
                                  accent: blue, accentInk: .white, keyBorder: nil, isDark: true)
                : KeyboardPalette(background: nil, keyFill: .white,
                                  specialFill: RGBA(r: 0.68, g: 0.70, b: 0.74), ink: .black,
                                  trail: blue.alpha(0.55), barInk: .black, balloon: .white,
                                  accent: blue, accentInk: .white, keyBorder: nil, isDark: false)
        case .oled:
            return KeyboardPalette(background: .black, keyFill: RGBA(hex: 0x1C1C1E),
                                   specialFill: RGBA(hex: 0x3A3A3C), ink: .white,
                                   trail: RGBA.white.alpha(0.6), barInk: .white,
                                   balloon: RGBA(hex: 0x2C2C2E),
                                   accent: RGBA(hex: 0x0A84FF), accentInk: .white,
                                   keyBorder: nil, isDark: true)
        case .contrast:
            // Nền đen tuyền, phím đen viền trắng, chữ trắng, nhấn vàng (≥ AAA 7:1).
            return KeyboardPalette(background: .black, keyFill: RGBA(hex: 0x141414),
                                   specialFill: RGBA(hex: 0x4D4D4D), ink: .white,
                                   trail: RGBA(hex: 0xFFD60A), barInk: .white,
                                   balloon: RGBA(hex: 0x141414),
                                   accent: RGBA(hex: 0xFFD60A), accentInk: .black,
                                   keyBorder: RGBA.white.alpha(0.85), isDark: true)
        case .peach:
            return Self.pastel(bg: 0xFBE3E1, key: 0xFFF8F7, special: 0xF1C4BF,
                               ink: 0x4A2226, accent: 0xC2505A)
        case .mint:
            return Self.pastel(bg: 0xD9F2E7, key: 0xF6FFFA, special: 0xAFDDC9,
                               ink: 0x173B30, accent: 0x1F7A5C)
        case .sky:
            return Self.pastel(bg: 0xDAE9F8, key: 0xF6FAFF, special: 0xB3CFEE,
                               ink: 0x14304C, accent: 0x2C6BB8)
        case .lavender:
            return Self.pastel(bg: 0xE8E2F6, key: 0xFBF9FF, special: 0xCBBFEA,
                               ink: 0x2C2345, accent: 0x6A48C4)
        case .glass:
            // Nền trong suốt: backdrop mờ của hệ thống lộ ra (miễn phí, không
            // blur tự vẽ); phím trắng bán trong kiểu Liquid Glass.
            return systemDark
                ? KeyboardPalette(background: nil, keyFill: RGBA.white.alpha(0.16),
                                  specialFill: RGBA.white.alpha(0.32), ink: .white,
                                  trail: RGBA.white.alpha(0.6), barInk: .white,
                                  balloon: RGBA(hex: 0x4A4A4E),
                                  accent: blue, accentInk: .white, keyBorder: RGBA.white.alpha(0.18),
                                  isDark: true)
                : KeyboardPalette(background: nil, keyFill: RGBA.white.alpha(0.55),
                                  specialFill: RGBA.white.alpha(0.3), ink: .black,
                                  trail: blue.alpha(0.55), barInk: .black, balloon: .white,
                                  accent: blue, accentInk: .white, keyBorder: RGBA.white.alpha(0.6),
                                  isDark: false)
        }
    }

    private static func pastel(bg: UInt32, key: UInt32, special: UInt32,
                               ink: UInt32, accent: UInt32) -> KeyboardPalette {
        let a = RGBA(hex: accent)
        return KeyboardPalette(background: RGBA(hex: bg), keyFill: RGBA(hex: key),
                               specialFill: RGBA(hex: special), ink: RGBA(hex: ink),
                               trail: a.alpha(0.6), barInk: RGBA(hex: ink),
                               balloon: RGBA(hex: key), accent: a, accentInk: .white,
                               keyBorder: nil, isDark: false)
    }
}

/// Cổng Plus cho theme: dùng PlusGate thật (iOS/Shared) — `.premiumThemes` gồm
/// theme cao cấp + ảnh nền. Hệ thống/OLED/tương phản cao luôn miễn phí.
enum ThemeGate {
    static func allows(_ theme: KeyboardTheme) -> Bool {
        !theme.isPlus || PlusGate.isUnlocked(.premiumThemes)
    }
    static var allowsWallpaper: Bool { PlusGate.isUnlocked(.premiumThemes) }
}

/// Cài đặt giao diện (App Group) — app ghi, bàn phím đọc mỗi lần hiện.
struct ThemeSettings: Equatable {
    static let themeKey = "keyboardTheme"
    static let wallpaperKey = "wallpaperEnabled"
    static let dimKey = "wallpaperDim"        // % lớp phủ 0…80
    static let blurKey = "wallpaperBlur"      // bán kính mờ 0…20 (app áp khi lưu ảnh)
    static let versionKey = "wallpaperVersion" // đổi mỗi lần lưu ảnh → vứt cache
    static let cropKey = "wallpaperCrop"      // "x,y,w,h" chuẩn hoá theo ảnh gốc; thiếu = cắt giữa

    var theme: KeyboardTheme = .system
    var wallpaper = false
    var dim = 30
    var blur = 0
    var version: Double = 0
    /// Khung cắt đã chỉnh (nil = ảnh cũ / chưa chỉnh → cắt giữa). Thuộc về ẢNH (như file),
    /// nên "Khôi phục giao diện gốc" giữ nguyên.
    var crop: WallpaperCrop?
    /// Độ trong suốt phím / ký tự 0…100 (miễn phí, mọi theme).
    var keyboardTransparency = 0
    var labelTransparency = 0
    /// Theme bật "Nền theo hệ thống" (tuỳ chọn RIÊNG từng theme có nền; mặc định không theme nào).
    var systemBackdropThemes: Set<KeyboardTheme> = []
    /// "Tuỳ chỉnh nâng cao" (Plus) — lưu nguyên kể cả khi hết quyền; áp qua `effectiveKeyStyle`.
    var keyStyle = KeyStyle()

    /// "Khôi phục giao diện gốc": mọi chỉnh ở màn Giao diện về mặc định. Ảnh nền chỉ
    /// bỏ chọn (file giữ nguyên để bật lại); version giữ nguyên (không vứt cache vô cớ).
    func resetToDefaults() -> ThemeSettings {
        var s = ThemeSettings()
        s.version = version
        s.crop = crop
        return s
    }
    var isDefault: Bool { self == resetToDefaults() }

    static func load(_ d: UserDefaults?) -> ThemeSettings {
        var s = ThemeSettings()
        guard let d else { return s }
        if let raw = d.string(forKey: themeKey), let t = KeyboardTheme(rawValue: raw) { s.theme = t }
        s.wallpaper = d.bool(forKey: wallpaperKey)
        if d.object(forKey: dimKey) != nil { s.dim = max(0, min(80, d.integer(forKey: dimKey))) }
        s.blur = max(0, min(20, d.integer(forKey: blurKey)))
        s.version = d.double(forKey: versionKey)
        s.crop = WallpaperCrop(serialized: d.string(forKey: cropKey))
        s.keyboardTransparency = KeyboardTransparency.clamp(d.integer(forKey: KeyboardTransparency.keyboardKey))
        s.labelTransparency = KeyboardTransparency.clamp(d.integer(forKey: KeyboardTransparency.labelKey))
        for t in KeyboardTheme.allCases {
            if let k = t.systemBackdropKey, d.bool(forKey: k) { s.systemBackdropThemes.insert(t) }
        }
        s.keyStyle = KeyStyle.load(d)
        return s
    }

    func save(_ d: UserDefaults?) {
        d?.set(theme.rawValue, forKey: Self.themeKey)
        d?.set(wallpaper, forKey: Self.wallpaperKey)
        d?.set(dim, forKey: Self.dimKey)
        d?.set(blur, forKey: Self.blurKey)
        d?.set(version, forKey: Self.versionKey)
        if let crop { d?.set(crop.serialized, forKey: Self.cropKey) } else { d?.removeObject(forKey: Self.cropKey) }
        d?.set(keyboardTransparency, forKey: KeyboardTransparency.keyboardKey)
        d?.set(labelTransparency, forKey: KeyboardTransparency.labelKey)
        for t in KeyboardTheme.allCases {
            if let k = t.systemBackdropKey { d?.set(systemBackdropThemes.contains(t), forKey: k) }
        }
        keyStyle.save(d)
    }

    /// Theme thực dùng sau cổng Plus (hết quyền → về Hệ thống, không crash/không trắng).
    var effectiveTheme: KeyboardTheme { ThemeGate.allows(theme) ? theme : .system }
    /// Tuỳ chỉnh nâng cao thực dùng: hết quyền Plus ⇒ mặc định (giá trị lưu giữ nguyên để
    /// mua lại là có lại).
    var effectiveKeyStyle: KeyStyle { ThemeGate.allowsAdvanced ? keyStyle : .default }
    /// Ảnh nền chỉ bật khi có quyền Plus VÀ file tồn tại.
    func wallpaperActive(fileExists: Bool) -> Bool {
        wallpaper && fileExists && ThemeGate.allowsWallpaper
    }

    /// Nền bàn phím để TRONG — lộ vật liệu bàn phím hệ thống, cùng màu dải 🌐/🎤 iOS vẽ bên
    /// dưới (kính iOS 26/27, sáng lẫn tối). Chỉ theme nền trong suốt (Hệ thống, Kính) không
    /// ảnh nền; theme có nền riêng (Tối OLED / Tương phản cao = đen tuyền, pastel) và ảnh nền
    /// tự vẽ nền ⇒ chấp nhận lệch màu với dải hệ thống. Độ trong suốt phím không đổi quyết
    /// định này (theme trong suốt vẫn trong suốt).
    func clearBackground(systemDark: Bool, wallpaperActive: Bool) -> Bool {
        !wallpaperActive && palette(systemDark: systemDark, wallpaperActive: false).background == nil
    }

    /// "Nền theo hệ thống" đang áp: theme có nền riêng + người dùng bật cho theme đó.
    /// Mặc định TẮT ⇒ 0 chi phí, như trước.
    var usesSystemBackdrop: Bool {
        effectiveTheme.hasOwnBackground && systemBackdropThemes.contains(effectiveTheme)
    }

    func palette(systemDark: Bool, wallpaperActive: Bool) -> KeyboardPalette {
        var p = effectiveTheme.palette(systemDark: systemDark)
        if usesSystemBackdrop, !wallpaperActive { p = p.onSystemBackdrop(systemDark: systemDark) }
        let style = effectiveKeyStyle
        p = style.applyColors(to: p)
        p.keyLabelPinned = style.labelColor != nil
        return (wallpaperActive ? p.overWallpaper() : p)
            .withTransparency(keyboard: keyboardTransparency, labels: labelTransparency,
                              systemDark: systemDark, wallpaper: wallpaperActive)
    }
}

// MARK: - Tuỳ chỉnh nâng cao (Plus): màu chữ/nền phím, bo góc, cỡ chữ, phông, độ đậm

/// Phông nhãn phím — CHỈ phông hệ thống (không nhúng phông: giữ nhẹ app). Id dùng chung
/// Android (Keys.KEY_LABEL_FONT); máy không có kiểu đó (Android không có "rounded") ⇒ mặc định.
enum KeyLabelFont: String, CaseIterable {
    /// SF Compact như stock (SF Pro nếu máy không có Compact).
    case standard = "default"
    case rounded, serif, mono, condensed

    var title: String {
        switch self {
        case .standard: return L("Mặc định")
        case .rounded: return L("Tròn")
        case .serif: return L("Có chân")
        case .mono: return L("Đơn cách")
        case .condensed: return L("Hẹp")
        }
    }
}

/// "Độ đậm" nhãn phím → độ đậm hệ thống.
enum KeyLabelWeight: String, CaseIterable {
    case light, regular, medium, bold, heavy

    var title: String {
        switch self {
        case .light: return L("Mỏng")
        case .regular: return L("Thường")
        case .medium: return L("Vừa")
        case .bold: return L("Đậm")
        case .heavy: return L("Rất đậm")
        }
    }
    var uiWeight: UIFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// "Tuỳ chỉnh nâng cao" ở Cài đặt → Giao diện (Plus). Mọi giá trị nil/mặc định = như cũ.
/// Màu: MỘT màu dùng cho cả sáng lẫn tối (đơn giản, đoán được); "Theo theme" = nil.
/// Lưu App Group bằng số nguyên có giá trị canh (-1 / 0 = mặc định) để sao lưu kiểu
/// `.int` như mọi setting khác. Android giữ y hệt (android/keyboard/.../KeyStyle.kt).
/// Áp lúc dựng palette / plane (0 chi phí mỗi phím).
struct KeyStyle: Equatable {
    static let labelColorKey = "keyLabelColor"     // 0xRRGGBB; -1 = theo theme
    static let fillColorKey = "keyFillColor"       // 0xRRGGBB; -1 = theo theme
    static let cornerKey = "keyCornerRadius"       // 0…100 (% nửa cạnh ngắn); -1 = mặc định
    static let fontScaleKey = "keyFontScale"       // 80…150 (%); 0 = mặc định
    static let fontKey = "keyLabelFont"            // KeyLabelFont.rawValue
    static let weightKey = "keyLabelWeight"        // KeyLabelWeight.rawValue
    static let colorRange = -1...0xFFFFFF
    static let cornerRange = -1...100
    static let fontScaleRange = 0...150
    static let fontScaleMin = 80, fontScaleMax = 150

    var labelColor: UInt32?
    var fillColor: UInt32?
    /// 0 = chữ nhật, 100 = tròn/viên thuốc (bán kính = nửa cạnh ngắn của phím); nil = mặc định.
    var corner: Int?
    /// 80…150 (% cỡ mặc định); nil = mặc định.
    var fontScale: Int?
    var font: KeyLabelFont = .standard
    var weight: KeyLabelWeight = .regular

    static let `default` = KeyStyle()
    var isDefault: Bool { self == .default }
    /// Có đổi chữ (phông / độ đậm / cỡ) — bật đường đo + kẹp chữ.
    var customizesLabels: Bool { font != .standard || weight != .regular || fontScale != nil }
    var labelScale: CGFloat { CGFloat(fontScale ?? 100) / 100 }

    static func parseColor(_ v: Int?) -> UInt32? {
        guard let v, v >= 0, v <= 0xFFFFFF else { return nil }
        return UInt32(v)
    }
    static func parseCorner(_ v: Int?) -> Int? {
        guard let v, v >= 0 else { return nil }
        return min(v, 100)
    }
    static func parseFontScale(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return min(max(v, fontScaleMin), fontScaleMax)
    }

    static func load(_ d: UserDefaults?) -> KeyStyle {
        var s = KeyStyle()
        guard let d else { return s }
        func int(_ k: String) -> Int? { (d.object(forKey: k) as? NSNumber)?.intValue }
        s.labelColor = parseColor(int(labelColorKey))
        s.fillColor = parseColor(int(fillColorKey))
        s.corner = parseCorner(int(cornerKey))
        s.fontScale = parseFontScale(int(fontScaleKey))
        s.font = d.string(forKey: fontKey).flatMap(KeyLabelFont.init(rawValue:)) ?? .standard
        s.weight = d.string(forKey: weightKey).flatMap(KeyLabelWeight.init(rawValue:)) ?? .regular
        return s
    }

    func save(_ d: UserDefaults?) {
        d?.set(labelColor.map { Int($0) } ?? -1, forKey: Self.labelColorKey)
        d?.set(fillColor.map { Int($0) } ?? -1, forKey: Self.fillColorKey)
        d?.set(corner ?? -1, forKey: Self.cornerKey)
        d?.set(fontScale ?? 0, forKey: Self.fontScaleKey)
        d?.set(font.rawValue, forKey: Self.fontKey)
        d?.set(weight.rawValue, forKey: Self.weightKey)
    }

    /// Bán kính bo góc phím cỡ `size`: 0% = chữ nhật, 100% = nửa cạnh ngắn (phím vuông ⇒
    /// tròn, phím dài ⇒ viên thuốc). nil ⇒ `fallback` (bo mặc định).
    static func cornerRadius(percent: Int?, size: CGSize, fallback: CGFloat) -> CGFloat {
        guard let p = percent else { return fallback }
        let half = max(0, min(size.width, size.height)) / 2
        return half * CGFloat(min(max(p, 0), 100)) / 100
    }

    /// Màu phím theo lựa chọn (trước ảnh nền / độ trong suốt). Màu chữ do người dùng chọn
    /// được giữ nguyên; chỉ đổi nền ⇒ chữ theme đổi đen/trắng nếu không đọc được trên nền mới.
    /// Ô phóng to / popup đi theo để chữ trong đó luôn đọc được.
    func applyColors(to p: KeyboardPalette) -> KeyboardPalette {
        guard labelColor != nil || fillColor != nil else { return p }
        var q = p
        q.surfaceDark = p.surfaceDark ?? p.isDark   // thanh gợi ý / emoji giữ tông nền cũ
        if let f = fillColor {
            let c = RGBA(hex: f)
            q.keyFill = c
            // Phím khi đè: sẫm (nền sáng) / sáng (nền tối) hơn một chút.
            let toward: RGBA = c.luminance > 0.4 ? .black : .white
            q.specialFill = toward.alpha(0.18).over(c)
            q.balloon = c
        }
        if let l = labelColor {
            q.ink = RGBA(hex: l)
        } else {
            let sys = KeyboardTransparency.systemBackdrop(dark: p.isDark)
            q.ink = KeyboardTransparency.readable(p.ink, on: q.keyFill.over(p.background?.over(sys) ?? sys))
        }
        if RGBA.contrast(q.ink, q.balloon.over(.white)) < KeyboardTransparency.minLabelContrast {
            q.balloon = q.ink.luminance > 0.5 ? RGBA(hex: 0x3A3A3C) : .white
        }
        q.isDark = q.ink.luminance > 0.5
        return q
    }
}

/// Số đo mực chữ theo em (đo một lần mỗi phông + độ đậm, CTLine — có thay phông dự phòng như
/// lúc vẽ thật). Dùng để kẹp cỡ chữ: chữ rộng nhất vừa bề ngang phím, dấu chồng (Ễ, Ỗ) và
/// phần dưới dòng (g, ỵ) nằm trọn trong phím / ô phóng to.
struct KeyLabelEm: Equatable {
    /// Bề ngang glyph rộng nhất / em.
    var width: CGFloat
    /// Mực trên baseline / dưới baseline (đều dương) theo em.
    var ascent: CGFloat
    var descent: CGFloat
    /// Hộp dòng của phông (UIFont.ascender, −descender) theo em — UILabel căn giữa hộp này.
    var lineAscender: CGFloat
    var lineDescender: CGFloat
    var inkHeight: CGFloat { ascent + descent }

    /// Mẫu chữ có thể hiện TRÊN phím (chữ hoa có dấu mũ/móc, không dấu thanh).
    static let keySample = "WMĐÂĂÊÔƠƯgjpqy"
    /// Mẫu chữ ô phóng to / popup ký tự phụ (dấu chồng).
    static let stackedSample = "ỄẪỖẰẲỮỂgjpqyỵỹ"

    static func measure(_ font: UIFont, sample: String) -> KeyLabelEm {
        let s = font.pointSize
        guard s > 0 else { return KeyLabelEm(width: 0, ascent: 0, descent: 0, lineAscender: 0, lineDescender: 0) }
        var maxW: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        for ch in sample {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: [.font: font]))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            maxW = max(maxW, ink.maxX, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            top = max(top, ink.maxY)
            bottom = max(bottom, -ink.minY)
        }
        return KeyLabelEm(width: maxW / s, ascent: top / s, descent: bottom / s,
                          lineAscender: font.ascender / s, lineDescender: -font.descender / s)
    }
}

/// Kẹp cỡ + baseline nhãn phím (thuần — test được).
enum KeyLabelFit {
    static let sidePad: CGFloat = 3
    static let vPad: CGFloat = 1

    /// Cỡ lớn nhất ≤ `want` để glyph rộng nhất vừa bề ngang và mực (trên + dưới baseline)
    /// vừa chiều cao phím.
    static func size(want: CGFloat, em: KeyLabelEm, keyWidth: CGFloat, keyHeight: CGFloat) -> CGFloat {
        var s = want
        // ×0.98: chừa sai số cỡ quang học (đo một cỡ, vẽ cỡ khác).
        if em.width > 0, keyWidth > 0 { s = min(s, (keyWidth - 2 * sidePad) / em.width * 0.98) }
        if em.inkHeight > 0, keyHeight > 0 { s = min(s, (keyHeight - 2 * vPad) / em.inkHeight) }
        return max(s, 1)
    }

    /// Baseline (pt dưới đỉnh phím): giữ `preferred` (baseline stock) nếu mực vẫn trong phím,
    /// không thì dời vừa đủ.
    static func baseline(preferred: CGFloat, size: CGFloat, em: KeyLabelEm, keyHeight: CGFloat) -> CGFloat {
        let lo = vPad + em.ascent * size, hi = keyHeight - vPad - em.descent * size
        guard lo <= hi else { return (lo + hi) / 2 }
        return min(max(preferred, lo), hi)
    }

    /// Cỡ lớn nhất ≤ `want` để chữ trong UILabel CĂN GIỮA hộp dòng (ô phóng to, popup) cao
    /// `height` không bị cắt mực trên/dưới (UILabel cắt nội dung theo bounds).
    static func centeredSize(want: CGFloat, em: KeyLabelEm, height: CGFloat) -> CGFloat {
        let line = em.lineAscender + em.lineDescender
        let over = max(0, em.ascent - em.lineAscender, em.descent - em.lineDescender)
        let need = line + 2 * over
        guard need > 0, height > 0 else { return want }
        return max(1, min(want, height / need))
    }
}

/// Phông nhãn phím đã giải (phông + độ đậm + hệ số cỡ) — KeyboardView giữ một bản tĩnh,
/// đặt lại mỗi lần hiện; UIFont cache theo cỡ trong bản này.
final class KeyLabelFonts {
    let font: KeyLabelFont
    let weight: KeyLabelWeight
    let scale: CGFloat
    /// Có tuỳ chỉnh chữ — false ⇒ đường cũ y nguyên (không đo, không kẹp).
    let active: Bool
    private let compact: UIFontDescriptor?
    private var cache: [CGFloat: UIFont] = [:]
    private var emCache: [String: KeyLabelEm] = [:]

    init(style: KeyStyle, compact: UIFontDescriptor?) {
        font = style.font; weight = style.weight; scale = style.labelScale
        active = style.customizesLabels
        self.compact = compact
    }

    /// Phông ở đúng cỡ `size` (nơi gọi tự nhân `scale` nếu cần).
    func font(size: CGFloat) -> UIFont {
        if let f = cache[size] { return f }
        let f = Self.make(font, weight, size: size, compact: compact)
        if cache.count > 64 { cache.removeAll() }
        cache[size] = f
        return f
    }

    static func make(_ design: KeyLabelFont, _ weight: KeyLabelWeight, size: CGFloat,
                     compact: UIFontDescriptor?) -> UIFont {
        let w = weight.uiWeight
        switch design {
        case .standard:
            guard let c = compact else { return .systemFont(ofSize: size, weight: w) }
            if weight == .regular { return UIFont(descriptor: c, size: size) }
            let d = c.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: w]])
            return UIFont(descriptor: d, size: size)
        case .rounded, .serif, .mono:
            let sd: UIFontDescriptor.SystemDesign = design == .rounded ? .rounded : design == .serif ? .serif : .monospaced
            let base = UIFont.systemFont(ofSize: size, weight: w)
            return base.fontDescriptor.withDesign(sd).map { UIFont(descriptor: $0, size: size) } ?? base
        case .condensed:
            return .systemFont(ofSize: size, weight: w, width: .condensed)
        }
    }

    /// Số đo em (đo ở cỡ thật của nhãn phím ~24pt — SF / New York đổi nét theo cỡ quang học,
    /// đo ở cỡ khác lệch bề ngang; một lần cho mỗi mẫu).
    func em(_ sample: String) -> KeyLabelEm {
        if let e = emCache[sample] { return e }
        let e = KeyLabelEm.measure(Self.make(font, weight, size: 24, compact: compact), sample: sample)
        emCache[sample] = e
        return e
    }
}

extension ThemeGate {
    /// "Tuỳ chỉnh nâng cao" đi cùng quyền theme cao cấp (Plus).
    static var allowsAdvanced: Bool { PlusGate.isUnlocked(.premiumThemes) }
}
