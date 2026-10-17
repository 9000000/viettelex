import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreText

/// Nền bàn phím trong suốt (lộ vật liệu bàn phím hệ thống, cùng màu dải 🌐/🎤) hay tự vẽ.
final class KeyboardBackdropTests: XCTestCase {
    private var savedPaywall = false
    override func setUp() { super.setUp(); savedPaywall = PlusGate.paywallEnabled; PlusGate.paywallEnabled = false }
    override func tearDown() { PlusGate.paywallEnabled = savedPaywall; super.tearDown() }

    func testDefaultSystemThemeIsClearInLightAndDark() {
        for dark in [false, true] {
            XCTAssertTrue(ThemeSettings().clearBackground(systemDark: dark, wallpaperActive: false))
            XCTAssertNil(ThemeSettings().palette(systemDark: dark, wallpaperActive: false).background)
        }
    }

    func testTransparentThemesStayClearWithKeyTransparency() {
        var s = ThemeSettings()
        s.keyboardTransparency = 60
        XCTAssertTrue(s.clearBackground(systemDark: true, wallpaperActive: false))
        s.theme = .glass
        XCTAssertTrue(s.clearBackground(systemDark: true, wallpaperActive: false))
    }

    func testOwnBackgroundThemesAndWallpaperDrawTheirOwn() {
        var s = ThemeSettings()
        // "Tối OLED" / "Tương phản cao" là nguồn nền ĐEN TUYỀN; pastel tự vẽ nền.
        for t in [KeyboardTheme.oled, .contrast, .peach, .mint, .sky, .lavender] {
            s.theme = t
            XCTAssertFalse(s.clearBackground(systemDark: true, wallpaperActive: false), t.rawValue)
        }
        s.theme = .system
        XCTAssertFalse(s.clearBackground(systemDark: true, wallpaperActive: true))
    }

    // MARK: "Nền theo hệ thống" (tuỳ chọn từng theme có nền, mặc định tắt)

    func testSystemBackdropOptionPerThemeDefaultOff() {
        var s = ThemeSettings()
        XCTAssertTrue(s.systemBackdropThemes.isEmpty)
        XCTAssertNil(KeyboardTheme.system.systemBackdropKey)
        XCTAssertNil(KeyboardTheme.glass.systemBackdropKey)
        XCTAssertEqual(KeyboardTheme.oled.systemBackdropKey, "systemBackdropOled")
        s.theme = .oled
        XCTAssertFalse(s.usesSystemBackdrop)
        let own = s.palette(systemDark: true, wallpaperActive: false)
        s.systemBackdropThemes = [.oled]
        XCTAssertTrue(s.usesSystemBackdrop)
        let sys = s.palette(systemDark: true, wallpaperActive: false)
        XCTAssertNil(sys.background)
        XCTAssertTrue(s.clearBackground(systemDark: true, wallpaperActive: false))
        XCTAssertEqual(sys.keyFill, own.keyFill)          // giữ màu phím theme
        XCTAssertEqual(sys.ink, own.ink)
        // Bật cho OLED không ảnh hưởng theme khác.
        s.theme = .contrast
        XCTAssertFalse(s.usesSystemBackdrop)
        XCTAssertNotNil(s.palette(systemDark: true, wallpaperActive: false).background)
        // Ảnh nền thắng (ảnh nền tự vẽ nền).
        s.theme = .oled
        XCTAssertFalse(s.clearBackground(systemDark: true, wallpaperActive: true))
        // Khôi phục giao diện gốc tắt hết.
        XCTAssertTrue(s.resetToDefaults().systemBackdropThemes.isEmpty)
    }

    func testSystemBackdropKeepsBarReadableAndSurfaceFollowsSystem() {
        var s = ThemeSettings()
        s.theme = .oled                                   // chữ trắng, theme tối cố định
        s.systemBackdropThemes = [.oled]
        let light = s.palette(systemDark: false, wallpaperActive: false)   // kính sáng phía sau
        let behind = KeyboardTransparency.systemBackdrop(dark: false)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(light.barInk, behind), KeyboardTransparency.minLabelContrast)
        XCTAssertEqual(light.surfaceDark, false)          // bảng emoji theo nền sáng
        XCTAssertTrue(light.isDark)                       // phím vẫn tối
        XCTAssertEqual(s.palette(systemDark: true, wallpaperActive: false).surfaceDark, true)
    }

    func testSystemBackdropSettingRoundTripsAndIsBackedUp() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "sysbd-\(UUID().uuidString)"))
        var s = ThemeSettings()
        s.systemBackdropThemes = [.oled, .peach]
        s.save(d)
        XCTAssertEqual(ThemeSettings.load(d).systemBackdropThemes, [.oled, .peach])
        for t in KeyboardTheme.allCases {
            guard let k = t.systemBackdropKey else { continue }
            XCTAssertEqual(BackupSettings.byKey[k]?.kind, .bool(false), k)   // có trong sao lưu, mặc định tắt
        }
    }

    // MARK: nền phủ trọn input view + bo góc

    /// Nền theme phủ TRỌN view (headroom balloon, strip, host cấp dư/thiếu, bar bật/tắt/thu
    /// gọn) — không để lộ khung kính xám của hệ thống ở mép trên (Phil 05/10, theme đen).
    @MainActor func testBackdropCoversWholeInputView() throws {
        let d = UserDefaultsProvider.shared
        let saved = d?.object(forKey: ThemeSettings.themeKey)
        defer { d?.set(saved, forKey: ThemeSettings.themeKey) }
        d?.set(KeyboardTheme.oled.rawValue, forKey: ThemeSettings.themeKey)
        let w: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 834 : 390
        for (suggestions, reserve) in [(true, true), (false, true), (false, false)] {
            let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
            let host = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 500))
            host.addSubview(kb)
            kb.frame = CGRect(x: 0, y: 0, width: w, height: 300)
            kb.applyAppearance(.dark, style: .dark)
            kb.configureInputKind(.normal)
            kb.setSuggestionsEnabled(suggestions, reserveStrip: reserve)
            kb.layoutIfNeeded()
            let want = kb.debugRequestedHeight
            for h in [want, want - 14, want - 40, want + 30, want + 120] {   // đúng / thiếu / dư
                kb.frame.size.height = h
                kb.setNeedsLayout(); kb.layoutIfNeeded()
                for f in kb.debugBackdrop.frames {
                    XCTAssertEqual(f, kb.bounds, "bar \(suggestions)/\(reserve) h \(h)")
                }
            }
        }
    }

    func testBackdropCornerRadiusOnlyPhoneIOS26() {
        XCTAssertGreaterThan(KeyLayout.backdropCornerRadius(phone: true, systemMajor: 26), 0)
        XCTAssertGreaterThan(KeyLayout.backdropCornerRadius(phone: true, systemMajor: 27), 0)
        XCTAssertEqual(KeyLayout.backdropCornerRadius(phone: true, systemMajor: 18), 0)
        XCTAssertEqual(KeyLayout.backdropCornerRadius(phone: false, systemMajor: 27), 0)
    }

    func testSystemKeysKeepContrastOnSystemBackdrop() {
        // Nền trong ⇒ phím nằm trên vật liệu hệ thống: chữ vẫn ≥ 4.5:1, phím tách khỏi nền.
        for dark in [false, true] {
            let p = KeyboardTheme.system.palette(systemDark: dark)
            let sys = KeyboardTransparency.systemBackdrop(dark: dark)
            XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.keyFill.over(sys)), 4.5)
            XCTAssertGreaterThan(RGBA.contrast(p.keyFill.over(sys), sys), 1.1)
        }
    }
}

/// Theme bàn phím: token, cổng Plus, lưu/đọc cài đặt, tương phản WCAG, pipeline ảnh nền.
final class KeyboardThemeTests: XCTestCase {

    private var savedDefaults: UserDefaults!
    private var savedPaywall = false
    private var suite = ""

    override func setUp() {
        super.setUp()
        savedDefaults = PlusGate.defaults
        savedPaywall = PlusGate.paywallEnabled
        PlusGate.paywallEnabled = false   // mặc định test = mở (test gating tự bật)
        suite = "themeplus-\(UUID().uuidString)"
        PlusGate.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        PlusGate.defaults.removePersistentDomain(forName: suite)
        PlusGate.defaults = savedDefaults
        PlusGate.paywallEnabled = savedPaywall
        super.tearDown()
    }

    /// Bật paywall + chưa mua (tắt cả công tắc giả lập Debug).
    private func lockPlus() {
        PlusGate.paywallEnabled = true
        PlusGate.setPurchased(false)
        PlusGate.debugOverride = false
    }

    // MARK: token

    func testThemeSetIsCompactAndSystemIsDefault() {
        XCTAssertTrue((6...8).contains(KeyboardTheme.allCases.count))
        XCTAssertEqual(ThemeSettings().theme, .system)
        XCTAssertEqual(ThemeSettings.load(nil).theme, .system)
    }

    /// Theme Hệ thống giữ NGUYÊN màu cũ của KeyboardView (không đổi hình người dùng cũ).
    func testSystemPaletteMatchesLegacyColors() {
        let light = KeyboardTheme.system.palette(systemDark: false)
        XCTAssertEqual(light.keyFill, .white)
        XCTAssertEqual(light.specialFill, RGBA(r: 0.68, g: 0.70, b: 0.74))
        XCTAssertEqual(light.ink, .black)
        XCTAssertNil(light.background)
        XCTAssertFalse(light.isDark)
        let dark = KeyboardTheme.system.palette(systemDark: true)
        // Tối: theo stock iOS 27 đo pixel (phím #444444 trên nền #202020) — xem UXFeedbackTests.
        XCTAssertEqual(dark.keyFill, RGBA(hex: 0x444444))
        XCTAssertEqual(dark.ink, .white)
        XCTAssertTrue(dark.isDark)
    }

    func testFixedThemesIgnoreSystemAppearance() {
        for t in KeyboardTheme.allCases where t != .system && t != .glass {
            XCTAssertEqual(t.palette(systemDark: false), t.palette(systemDark: true), t.rawValue)
            XCTAssertNotNil(t.palette(systemDark: false).background, "\(t) cần nền đục")
        }
        XCTAssertNil(KeyboardTheme.glass.palette(systemDark: false).background,
                     "Kính để lộ backdrop hệ thống, không tự blur")
    }

    func testIsDarkMatchesInkLuminance() {
        for t in KeyboardTheme.allCases {
            for d in [false, true] {
                let p = t.palette(systemDark: d)
                XCTAssertEqual(p.isDark, p.ink.luminance > 0.5, "\(t) dark=\(d)")
            }
        }
    }

    // MARK: tương phản WCAG

    /// Tương phản cao: chữ/nền phím ≥ 7:1 (AAA, vượt AA 4.5), cả khi đè phím, nhấn
    /// (return hành động) và thanh gợi ý trên nền bàn phím.
    func testHighContrastMeetsWCAG() {
        let p = KeyboardTheme.contrast.palette(systemDark: false)
        let bg = p.background!
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.keyFill.over(bg)), 7)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.specialFill.over(bg)), 7)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.accentInk, p.accent), 7)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.barInk, bg), 7)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.balloon), 7)
        // Ranh giới phím phải thấy được (viền ≥ 3:1 so với nền — WCAG 1.4.11).
        XCTAssertGreaterThanOrEqual(RGBA.contrast(p.keyBorder!.over(bg), bg), 3)
    }

    /// Mọi theme đục: chữ trên phím đạt AA (4.5:1).
    func testAllOpaqueThemesMeetAA() {
        for t in KeyboardTheme.allCases {
            for d in [false, true] {
                let p = t.palette(systemDark: d)
                // Nền trong suốt: kiểm trên backdrop hệ thống xấp xỉ (xám sáng / xám tối).
                let bg = p.background ?? (p.isDark ? RGBA(hex: 0x2A2A2A) : RGBA(hex: 0xD1D4DA))
                let key = p.keyFill.over(bg)
                XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, key), 4.5, "\(t) dark=\(d) phím")
                XCTAssertGreaterThanOrEqual(RGBA.contrast(p.barInk, bg), 4.5, "\(t) dark=\(d) bar")
                XCTAssertGreaterThanOrEqual(RGBA.contrast(p.accentInk, p.accent), 3, "\(t) dark=\(d) nhấn")
            }
        }
    }

    /// Có ảnh nền: phím bán trong 80%. Kể cả ảnh tệ nhất (đen tuyền dưới theme sáng,
    /// trắng tuyền dưới theme tối) và lớp phủ 0%, chữ vẫn ≥ 4.5:1.
    func testWallpaperKeysStayLegibleOnWorstImage() {
        for t in KeyboardTheme.allCases {
            for d in [false, true] {
                let p = ThemeSettings(theme: t).palette(systemDark: d, wallpaperActive: true)
                XCTAssertNil(p.background)
                let worst: RGBA = p.isDark ? .white : .black
                XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.keyFill.over(worst)), 4.5,
                                            "\(t) dark=\(d) phím")
                XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.specialFill.over(worst)), 4.5,
                                            "\(t) dark=\(d) phím đè")
                XCTAssertLessThan(p.keyFill.a, 1.0001)
                // Ảnh vẫn lộ ra ở theme sáng (phím không đục hoàn toàn).
                if !p.isDark { XCTAssertLessThan(p.keyFill.a, 1, "\(t) phím nên hơi trong") }
            }
        }
    }

    func testContrastMath() {
        XCTAssertEqual(RGBA.contrast(.white, .black), 21, accuracy: 0.01)
        XCTAssertEqual(RGBA.contrast(.white, .white), 1, accuracy: 0.001)
        // #767676 trên trắng ≈ 4.54 (mốc AA quen thuộc).
        XCTAssertEqual(RGBA.contrast(RGBA(hex: 0x767676), .white), 4.54, accuracy: 0.02)
    }

    // MARK: cổng Plus

    func testGateOpenWhilePaywallOff() {
        PlusGate.paywallEnabled = false
        for t in KeyboardTheme.allCases { XCTAssertTrue(ThemeGate.allows(t)) }
        XCTAssertTrue(ThemeGate.allowsWallpaper)
    }

    func testFreeThemesStayFreeBehindPaywall() {
        lockPlus()
        XCTAssertTrue(ThemeGate.allows(.system))
        XCTAssertTrue(ThemeGate.allows(.oled))
        XCTAssertTrue(ThemeGate.allows(.contrast))
        XCTAssertFalse(ThemeGate.allows(.glass))
        XCTAssertFalse(ThemeGate.allowsWallpaper)
        PlusGate.setPurchased(true)
        XCTAssertTrue(ThemeGate.allows(.glass))
        XCTAssertTrue(ThemeGate.allowsWallpaper)
    }

    func testFreeThemesIncludeAccessibility() {
        XCTAssertFalse(KeyboardTheme.system.isPlus)
        XCTAssertFalse(KeyboardTheme.contrast.isPlus, "trợ năng không được khoá sau Plus")
        XCTAssertTrue(KeyboardTheme.glass.isPlus)
        XCTAssertTrue(KeyboardTheme.allCases.contains { $0.isPlus })
    }

    func testLockedPlusFallsBackToSystem() {
        lockPlus()
        let s = ThemeSettings(theme: .mint, wallpaper: true)
        XCTAssertEqual(s.effectiveTheme, .system)
        XCTAssertFalse(s.wallpaperActive(fileExists: true))
        XCTAssertEqual(ThemeSettings(theme: .contrast).effectiveTheme, .contrast)
    }

    // MARK: lưu/đọc

    func testSettingsRoundTrip() {
        let suite = "themetest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ThemeSettings.load(d), ThemeSettings())   // mặc định khi trống
        let s = ThemeSettings(theme: .lavender, wallpaper: true, dim: 55, blur: 7, version: 123.5,
                              keyboardTransparency: 35, labelTransparency: 60)
        s.save(d)
        XCTAssertEqual(ThemeSettings.load(d), s)
    }

    func testLoadClampsAndIgnoresGarbage() {
        let suite = "themetest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("neon-pink-unknown", forKey: ThemeSettings.themeKey)
        d.set(500, forKey: ThemeSettings.dimKey)
        d.set(-3, forKey: ThemeSettings.blurKey)
        d.set(180, forKey: KeyboardTransparency.keyboardKey)
        d.set(-9, forKey: KeyboardTransparency.labelKey)
        let s = ThemeSettings.load(d)
        XCTAssertEqual(s.keyboardTransparency, 100)
        XCTAssertEqual(s.labelTransparency, 0)
        XCTAssertEqual(s.theme, .system)
        XCTAssertEqual(s.dim, 80)
        XCTAssertEqual(s.blur, 0)
    }

    // MARK: độ trong suốt

    private func allPalettes() -> [(KeyboardPalette, Bool, Bool)] {
        var out: [(KeyboardPalette, Bool, Bool)] = []
        for t in KeyboardTheme.allCases {
            for dark in [false, true] {
                let p = t.palette(systemDark: dark)
                out.append((p, dark, false)); out.append((p.overWallpaper(), dark, true))
            }
        }
        return out
    }

    func testTransparencyZeroIsIdentity() {
        for (p, dark, wp) in allPalettes() {
            XCTAssertEqual(p.withTransparency(keyboard: 0, labels: 0, systemDark: dark, wallpaper: wp), p)
            XCTAssertEqual(p.withTransparency(keyboard: -30, labels: -1, systemDark: dark, wallpaper: wp), p)
        }
    }

    func testTransparencyMapping() {
        XCTAssertEqual(KeyboardTransparency.alpha(0), 1)
        XCTAssertEqual(KeyboardTransparency.alpha(40), 0.6, accuracy: 1e-9)
        XCTAssertEqual(KeyboardTransparency.alpha(100), 0)
        XCTAssertEqual(KeyboardTransparency.alpha(250), 0)      // kẹp
        XCTAssertEqual(KeyboardTransparency.alpha(-5), 1)

        let peach = KeyboardTheme.peach.palette(systemDark: false)
        let half = peach.withTransparency(keyboard: 50, labels: 0, systemDark: false, wallpaper: false)
        XCTAssertEqual(half.background?.a ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.keyFill.a, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.specialFill.a, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.accent.a, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.surfaceAlpha, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.keyInk.a, 1)                        // chữ không mờ theo phím

        let glass = KeyboardTheme.glass.palette(systemDark: false)
        let g = glass.withTransparency(keyboard: 50, labels: 0, systemDark: false, wallpaper: false)
        XCTAssertEqual(g.keyBorder?.a ?? -1, (glass.keyBorder?.a ?? 0) * 0.5, accuracy: 1e-9)
        XCTAssertNil(g.background)                              // nền trong suốt vẫn nil

        // 100% phím: nền/phím/viền/bóng biến mất hẳn, chữ còn nguyên.
        for (p, dark, wp) in allPalettes() {
            let z = p.withTransparency(keyboard: 100, labels: 0, systemDark: dark, wallpaper: wp)
            XCTAssertEqual(z.keyFill.a, 0); XCTAssertEqual(z.specialFill.a, 0); XCTAssertEqual(z.accent.a, 0)
            XCTAssertEqual(z.background?.a ?? 0, 0); XCTAssertEqual(z.keyBorder?.a ?? 0, 0)
            XCTAssertEqual(z.surfaceAlpha, 0)
            XCTAssertEqual(z.keyInk.a, 1)
        }
    }

    func testLabelTransparencyIndependentAndSparesBalloon() {
        for (p, dark, wp) in allPalettes() {
            let z = p.withTransparency(keyboard: 0, labels: 100, systemDark: dark, wallpaper: wp)
            XCTAssertEqual(z.keyInk.a, 0); XCTAssertEqual(z.accentInk.a, 0)
            XCTAssertEqual(z.keyFill, p.keyFill); XCTAssertEqual(z.background, p.background)
            XCTAssertEqual(z.ink, p.ink); XCTAssertEqual(z.balloon, p.balloon)   // balloon rõ nguyên
            let h = p.withTransparency(keyboard: 0, labels: 30, systemDark: dark, wallpaper: wp)
            XCTAssertEqual(h.keyInk, p.ink.alpha(0.7))
        }
    }

    /// Nền trong suốt lộ backdrop khác tông → chữ tự đổi đen/trắng cho đọc được;
    /// mức nhỏ không được lật màu (không đổi hình người đang dùng).
    func testLabelsStayReadableWhenBackgroundGoesClear() {
        let peachDark = KeyboardTheme.peach.palette(systemDark: true)
            .withTransparency(keyboard: 100, labels: 0, systemDark: true, wallpaper: false)
        XCTAssertEqual(peachDark.keyInk, .white)
        XCTAssertTrue(peachDark.isDark)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(peachDark.barInk,
                                                  KeyboardTransparency.systemBackdrop(dark: true)), 4.5)
        let peachLight = KeyboardTheme.peach.palette(systemDark: false)
        XCTAssertEqual(peachLight.withTransparency(keyboard: 100, labels: 0, systemDark: false,
                                                   wallpaper: false).keyInk, peachLight.ink)
        for (p, dark, wp) in allPalettes() {
            let small = p.withTransparency(keyboard: 10, labels: 0, systemDark: dark, wallpaper: wp)
            XCTAssertEqual(small.keyInk, p.ink); XCTAssertEqual(small.barInk, p.barInk)
            XCTAssertEqual(small.accentInk, p.accentInk); XCTAssertEqual(small.isDark, p.isDark)
        }
    }

    func testSettingsApplyTransparency() {
        let s = ThemeSettings(theme: .mint, keyboardTransparency: 100, labelTransparency: 100)
        let p = s.palette(systemDark: false, wallpaperActive: false)
        XCTAssertEqual(p.keyFill.a, 0); XCTAssertEqual(p.keyInk.a, 0)
    }

    func testResetToDefaults() {
        XCTAssertTrue(ThemeSettings().isDefault)
        let s = ThemeSettings(theme: .sky, wallpaper: true, dim: 60, blur: 9, version: 77,
                              keyboardTransparency: 40, labelTransparency: 25)
        XCTAssertFalse(s.isDefault)
        let r = s.resetToDefaults()
        XCTAssertTrue(r.isDefault)
        XCTAssertEqual(r.theme, .system); XCTAssertFalse(r.wallpaper)
        XCTAssertEqual(r.dim, 30); XCTAssertEqual(r.blur, 0)
        XCTAssertEqual(r.keyboardTransparency, 0); XCTAssertEqual(r.labelTransparency, 0)
        XCTAssertEqual(r.version, 77)                          // ảnh nền giữ nguyên, không vứt cache
        XCTAssertFalse(ThemeSettings(labelTransparency: 5).isDefault)
    }

    func testWallpaperNeedsFile() {
        let s = ThemeSettings(theme: .sky, wallpaper: true)
        XCTAssertFalse(s.wallpaperActive(fileExists: false))
        XCTAssertTrue(s.wallpaperActive(fileExists: true))
        XCTAssertFalse(ThemeSettings(wallpaper: false).wallpaperActive(fileExists: true))
    }

    // MARK: ảnh nền

    nonisolated(unsafe) private static var jpegCache: [String: Data] = [:]
    private func makeJPEG(width: Int, height: Int) -> Data {
        let k = "\(width)x\(height)"
        if let d = Self.jpegCache[k] { return d }
        let d = renderJPEG(width: width, height: height)
        Self.jpegCache[k] = d
        return d
    }

    private func renderJPEG(width: Int, height: Int) -> Data {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            // Nhiễu màu → JPEG khó nén (trường hợp xấu cho giới hạn dung lượng).
            var seed: UInt32 = 12345
            let step = 16
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    seed = seed &* 1664525 &+ 1013904223
                    UIColor(red: CGFloat(seed & 0xFF) / 255, green: CGFloat((seed >> 8) & 0xFF) / 255,
                            blue: CGFloat((seed >> 16) & 0xFF) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: step, height: step))
                }
            }
        }
        return img.jpegData(compressionQuality: 0.95)!
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
    }

    func testPrepareDownsamplesAndCompresses() {
        let original = makeJPEG(width: 4032, height: 3024)     // ảnh camera 12MP
        let out = Wallpaper.prepare(original: original, blur: 0)!
        let (w, h) = pixelSize(out)
        XCTAssertLessThanOrEqual(max(w, h), Wallpaper.maxEdge)
        XCTAssertEqual(max(w, h), Wallpaper.maxEdge)
        XCTAssertEqual(Double(w) / Double(h), 4032.0 / 3024.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(out.count, Wallpaper.maxBytes)
    }

    func testPreparePortraitAndBlur() {
        let original = makeJPEG(width: 1500, height: 3000)
        let out = Wallpaper.prepare(original: original, blur: 10)!
        let (w, h) = pixelSize(out)
        XCTAssertEqual(h, Wallpaper.maxEdge)
        XCTAssertEqual(w, 540)
        XCTAssertLessThanOrEqual(out.count, Wallpaper.maxBytes)
    }

    func testSmallImageNotUpscaled() {
        let out = Wallpaper.prepare(original: makeJPEG(width: 600, height: 400), blur: 0)!
        let (w, h) = pixelSize(out)
        XCTAssertLessThanOrEqual(w, 600)
        XCTAssertLessThanOrEqual(h, 400)
    }

    /// Cỡ giải trong extension: đủ phủ view (aspect-fill) nhưng không vượt bản lưu.
    func testDisplayMaxPixel() {
        // iPhone dọc 393×300pt @3x = 1179×900px; ảnh 4:3 ngang → cần rộng 1200 → kẹp 1080.
        XCTAssertEqual(Wallpaper.displayMaxPixel(viewSize: CGSize(width: 393, height: 300),
                                                 scale: 3, imageAspect: 4.0 / 3), 1080)
        // @2x view 320×216 = 640×432, ảnh vuông → cần 640×640.
        XCTAssertEqual(Wallpaper.displayMaxPixel(viewSize: CGSize(width: 320, height: 216),
                                                 scale: 2, imageAspect: 1), 640)
        // Ảnh dọc 1:2 phủ view ngang 640×432: rộng 640 → cao 1280 → kẹp 1080.
        XCTAssertEqual(Wallpaper.displayMaxPixel(viewSize: CGSize(width: 320, height: 216),
                                                 scale: 2, imageAspect: 0.5), 1080)
        XCTAssertEqual(Wallpaper.displayMaxPixel(viewSize: .zero, scale: 3, imageAspect: 1), 1080)
    }

    func testKeyboardDecodeRespectsLimit() {
        let data = Wallpaper.prepare(original: makeJPEG(width: 4032, height: 3024), blur: 0)!
        let cg = Wallpaper.downsample(data: data, maxPixel: 640)!
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 640)
    }

    /// RAM: giải ảnh nền cỡ bàn phím iPhone 3x — đo phys_footprint tăng thêm.
    func testKeyboardDecodeMemoryFootprint() throws {
        try SlowTests.require()
        let data = Wallpaper.prepare(original: makeJPEG(width: 4032, height: 3024), blur: 0)!
        let px = Wallpaper.displayMaxPixel(viewSize: CGSize(width: 430, height: 300), scale: 3,
                                           imageAspect: 4.0 / 3)
        let before = Self.footprint()
        var images: [CGImage] = []
        autoreleasepool {
            images.append(Wallpaper.downsample(data: data, maxPixel: px)!)
        }
        let delta = Double(Self.footprint() - before) / 1_048_576
        let bitmapMB = Double(images[0].bytesPerRow * images[0].height) / 1_048_576
        print("THEME-RAM wallpaper decode \(images[0].width)x\(images[0].height): bitmap \(String(format: "%.1f", bitmapMB))MB, footprint +\(String(format: "%.1f", delta))MB")
        XCTAssertLessThanOrEqual(bitmapMB, 5, "bitmap ảnh nền phải ≤5MB (ngân sách extension ~48MB)")
        XCTAssertLessThan(delta, 12)
    }

    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

/// Ảnh nền + "Tuỳ chỉnh nâng cao" (Plus): độ trong suốt phím không làm mất ảnh nền, bo góc,
/// kẹp cỡ chữ, phông/độ đậm không cắt dấu chồng, lưu/đọc, cổng Plus, sao lưu.
final class KeyStyleTests: XCTestCase {
    private var savedDefaults: UserDefaults!
    private var savedPaywall = false
    private var suite = ""

    override func setUp() {
        super.setUp()
        savedDefaults = PlusGate.defaults
        savedPaywall = PlusGate.paywallEnabled
        PlusGate.paywallEnabled = false
        suite = "keystyle-\(UUID().uuidString)"
        PlusGate.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        PlusGate.defaults.removePersistentDomain(forName: suite)
        PlusGate.defaults = savedDefaults
        PlusGate.paywallEnabled = savedPaywall
        KeyboardView.labelFonts = KeyLabelFonts(style: .default, compact: nil)
        KeyboardView.cornerPercent = nil
        super.tearDown()
    }

    private func lockPlus() {
        PlusGate.paywallEnabled = true
        PlusGate.setPurchased(false)
        PlusGate.debugOverride = false
    }

    private static let custom = KeyStyle(labelColor: 0xFF2D55, fillColor: 0x102030, corner: 100,
                                         fontScale: 150, font: .mono, weight: .heavy)

    // MARK: bug — độ trong suốt phím 100% làm mất ảnh nền

    func testKeyTransparency100KeepsWallpaper() {
        for t in KeyboardTheme.allCases {
            for dark in [false, true] {
                for dim in [0, 30, 80] {
                    let s = ThemeSettings(theme: t, wallpaper: true, dim: dim, keyboardTransparency: 100)
                    let p = s.palette(systemDark: dark, wallpaperActive: true)
                    let wl = p.wallpaperLayer(dim: dim)
                    XCTAssertEqual(wl.imageAlpha, 1, "\(t) \(dark): ảnh nền phải còn nguyên")
                    XCTAssertEqual(wl.overlay.a, Double(dim) / 100, accuracy: 1e-9, "lớp phủ theo độ tối, không theo độ trong suốt")
                    XCTAssertEqual(p.keyFill.a, 0)          // phím thì trong suốt hẳn
                    XCTAssertEqual(p.keyInk.a, 1)
                }
            }
        }
    }

    /// Bàn phím thật: alpha UIImageView ảnh nền + lớp phủ không theo độ trong suốt phím.
    @MainActor func testKeyboardViewWallpaperIgnoresKeyTransparency() {
        let d = UserDefaultsProvider.shared
        let keys = [KeyboardTransparency.keyboardKey, ThemeSettings.dimKey]
        let saved = keys.map { d?.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d?.set(v, forKey: k) } }
        d?.set(100, forKey: KeyboardTransparency.keyboardKey)
        d?.set(40, forKey: ThemeSettings.dimKey)
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        kb.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        kb.applyAppearance(.light, style: .light)
        XCTAssertEqual(kb.debugWallpaperLayer.alpha, 1)
        var a: CGFloat = 0
        kb.debugWallpaperLayer.overlay?.getRed(nil, green: nil, blue: nil, alpha: &a)
        XCTAssertEqual(a, 0.4, accuracy: 0.01)
    }

    // MARK: bo góc

    func testCornerRadiusMapping() {
        let sq = CGSize(width: 30, height: 42), wide = CGSize(width: 200, height: 42)
        XCTAssertEqual(KeyStyle.cornerRadius(percent: nil, size: sq, fallback: 8), 8)     // mặc định
        XCTAssertEqual(KeyStyle.cornerRadius(percent: 0, size: sq, fallback: 8), 0)       // chữ nhật
        XCTAssertEqual(KeyStyle.cornerRadius(percent: 100, size: sq, fallback: 8), 15)    // tròn trọn cạnh ngắn
        XCTAssertEqual(KeyStyle.cornerRadius(percent: 100, size: wide, fallback: 8), 21)  // viên thuốc
        XCTAssertEqual(KeyStyle.cornerRadius(percent: 50, size: wide, fallback: 8), 10.5)
        XCTAssertEqual(KeyStyle.cornerRadius(percent: 400, size: sq, fallback: 8), 15)    // kẹp
    }

    // MARK: phông / cỡ chữ

    private static func styles() -> [KeyStyle] {
        KeyLabelFont.allCases.flatMap { f in
            KeyLabelWeight.allCases.map { KeyStyle(fontScale: 150, font: f, weight: $0) }
        }
    }

    func testFontSizeCapOnNarrowKeys() {
        let keyW: CGFloat = 26, keyH: CGFloat = 40   // phím chữ hẹp (một tay / máy nhỏ)
        for st in Self.styles() {
            let lf = KeyLabelFonts(style: st, compact: nil)
            let want = KeyGeometry.Typography.lowercaseSize * lf.scale
            let em = lf.em(KeyLabelEm.keySample)
            let size = KeyLabelFit.size(want: want, em: em, keyWidth: keyW, keyHeight: keyH)
            XCTAssertLessThan(size, want, "\(st.font) \(st.weight): 150% phải bị kẹp trên phím hẹp")
            let f = lf.font(size: size)
            for g in ["W", "M", "Ư", "Đ"] {
                let w = (g as NSString).size(withAttributes: [.font: f]).width
                XCTAssertLessThanOrEqual(w, keyW - 2 * KeyLabelFit.sidePad + 0.5, "\(st.font) \(st.weight) \(g)")
            }
            let m = KeyLabelEm.measure(f, sample: KeyLabelEm.keySample)
            XCTAssertLessThanOrEqual(m.inkHeight * size, keyH, "\(st.font) \(st.weight)")
            let base = KeyLabelFit.baseline(preferred: 28 * keyH / 43, size: size, em: em, keyHeight: keyH)
            XCTAssertGreaterThanOrEqual(base - em.ascent * size, 0)            // mực không vượt đỉnh phím
            XCTAssertLessThanOrEqual(base + em.descent * size, keyH)           // không vượt đáy
        }
        // Phím rộng, cỡ vừa ⇒ không đụng tới.
        let lf = KeyLabelFonts(style: KeyStyle(font: .serif), compact: nil)
        XCTAssertEqual(KeyLabelFit.size(want: 24.5, em: lf.em(KeyLabelEm.keySample), keyWidth: 60, keyHeight: 60), 24.5)
    }

    /// Dấu chồng (Ễ, Ỗ…) và phần dưới dòng (ỵ) trong ô phóng to / popup không bị UILabel cắt,
    /// ở MỌI phông + độ đậm.
    func testStackedDiacriticsFitCenteredLabels() {
        for st in Self.styles() {
            let lf = KeyLabelFonts(style: st, compact: nil)
            for h in [CGFloat(30), 38, 46] {
                let size = KeyLabelFit.centeredSize(want: 34, em: lf.em(KeyLabelEm.stackedSample), height: h)
                let f = lf.font(size: size.rounded(.down))
                let s = f.pointSize
                let lineH = f.ascender - f.descender
                for g in ["Ễ", "Ỗ", "Ẫ", "Ữ", "ỵ", "Ỹ"] {
                    let ink = CTLineGetBoundsWithOptions(
                        CTLineCreateWithAttributedString(NSAttributedString(string: g, attributes: [.font: f])),
                        .useGlyphPathBounds)
                    let baseline = h / 2 - lineH / 2 + f.ascender      // UILabel căn giữa hộp dòng
                    XCTAssertGreaterThanOrEqual(baseline - ink.maxY, -0.5, "\(st.font) \(st.weight) \(g) h\(h) s\(s)")
                    XCTAssertLessThanOrEqual(baseline - ink.minY, h + 0.5, "\(st.font) \(st.weight) \(g) h\(h) s\(s)")
                }
            }
        }
    }

    /// Bàn phím thật: chữ 150% phông đơn cách rất đậm trên máy hẹp — phím chữ vừa phím, bo tròn.
    @MainActor func testKeyboardViewAppliesStyleAtLayout() {
        let d = UserDefaultsProvider.shared
        let keys = [KeyStyle.labelColorKey, KeyStyle.fillColorKey, KeyStyle.cornerKey, KeyStyle.fontScaleKey,
                    KeyStyle.fontKey, KeyStyle.weightKey]
        let saved = keys.map { d?.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d?.set(v, forKey: k) } }
        Self.custom.save(d)
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        kb.applyAppearance(.light, style: .light)
        kb.configureInputKind(.normal)
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        let st = try? XCTUnwrap(kb.debugLetterStyle("w"))
        guard let st, let f = st.font, st.size.width > 0 else { return XCTFail("không thấy phím w") }
        XCTAssertEqual(st.radius, min(st.size.width, st.size.height) / 2, accuracy: 0.01)   // 100% = tròn
        let w = ("W" as NSString).size(withAttributes: [.font: f]).width
        XCTAssertLessThanOrEqual(w, st.size.width - 2 * KeyLabelFit.sidePad + 0.5)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) || f.fontName.lowercased().contains("mono"),
                      f.fontName)
        // Ô phóng to: dấu chồng nằm trọn trong khung chữ.
        if let b = kb.debugBalloon(letter: "e", text: "Ễ") {
            let lf = KeyboardView.labelFonts
            let em = lf.em(KeyLabelEm.stackedSample)
            XCTAssertLessThanOrEqual(b.fontSize, KeyLabelFit.centeredSize(want: 34, em: em, height: b.label.height) + 0.5)
        }
    }

    // MARK: lưu / đọc / mặc định

    func testSettingsParsingAndDefaults() {
        let suite = "keystyle-rt-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyStyle.load(d), KeyStyle())                 // trống ⇒ mặc định
        XCTAssertTrue(KeyStyle().isDefault)
        XCTAssertFalse(KeyStyle().customizesLabels)
        Self.custom.save(d)
        XCTAssertEqual(KeyStyle.load(d), Self.custom)
        KeyStyle().save(d)                                            // giá trị canh ⇒ mặc định
        XCTAssertEqual(d.integer(forKey: KeyStyle.labelColorKey), -1)
        XCTAssertEqual(d.integer(forKey: KeyStyle.fontScaleKey), 0)
        XCTAssertEqual(KeyStyle.load(d), KeyStyle())
        // Rác / ngoài phạm vi.
        d.set(0x1000000, forKey: KeyStyle.labelColorKey)
        d.set(-7, forKey: KeyStyle.fillColorKey)
        d.set(300, forKey: KeyStyle.cornerKey)
        d.set(30, forKey: KeyStyle.fontScaleKey)
        d.set("comic-sans", forKey: KeyStyle.fontKey)
        d.set("ultra", forKey: KeyStyle.weightKey)
        let g = KeyStyle.load(d)
        XCTAssertNil(g.labelColor); XCTAssertNil(g.fillColor)
        XCTAssertEqual(g.corner, 100); XCTAssertEqual(g.fontScale, 80)
        XCTAssertEqual(g.font, .standard); XCTAssertEqual(g.weight, .regular)
        d.set(999, forKey: KeyStyle.fontScaleKey)
        XCTAssertEqual(KeyStyle.load(d).fontScale, 150)
        // Thuộc ThemeSettings: lưu cùng, "Khôi phục giao diện gốc" xoá.
        var s = ThemeSettings(theme: .mint)
        s.keyStyle = Self.custom
        s.save(d)
        XCTAssertEqual(ThemeSettings.load(d).keyStyle, Self.custom)
        XCTAssertFalse(s.isDefault)
        XCTAssertEqual(s.resetToDefaults().keyStyle, KeyStyle())
    }

    // MARK: cổng Plus

    func testPlusGatingStoredButInactiveRendersDefaults() {
        var s = ThemeSettings(theme: .oled)
        s.keyStyle = Self.custom
        var plain = s; plain.keyStyle = KeyStyle()
        lockPlus()
        XCTAssertFalse(ThemeGate.allowsAdvanced)
        XCTAssertEqual(s.effectiveKeyStyle, KeyStyle())
        XCTAssertEqual(s.palette(systemDark: true, wallpaperActive: false),
                       plain.palette(systemDark: true, wallpaperActive: false))
        XCTAssertEqual(s.keyStyle, Self.custom)                        // giá trị lưu giữ nguyên
        PlusGate.setPurchased(true)
        XCTAssertTrue(ThemeGate.allowsAdvanced)
        XCTAssertEqual(s.effectiveKeyStyle, Self.custom)
        let p = s.palette(systemDark: true, wallpaperActive: false)
        XCTAssertEqual(p.keyFill, RGBA(hex: 0x102030))
        XCTAssertEqual(p.keyInk, RGBA(hex: 0xFF2D55))
    }

    // MARK: màu

    func testCustomColors() {
        // Chỉ đổi nền: chữ theme tự đổi đen/trắng cho đọc được.
        for t in KeyboardTheme.allCases {
            for dark in [false, true] {
                for fill: UInt32 in [0x000000, 0xFFFFFF, 0xFFD60A, 0x203040] {
                    var s = ThemeSettings(theme: t)
                    s.keyStyle = KeyStyle(fillColor: fill)
                    let p = s.palette(systemDark: dark, wallpaperActive: false)
                    XCTAssertGreaterThanOrEqual(RGBA.contrast(p.keyInk, p.keyFill), KeyboardTransparency.minLabelContrast,
                                                "\(t) \(dark) \(String(fill, radix: 16))")
                    XCTAssertGreaterThanOrEqual(RGBA.contrast(p.ink, p.balloon), KeyboardTransparency.minLabelContrast)
                }
            }
        }
        // Chữ người dùng chọn: độ trong suốt phím 100% không lật sang đen/trắng.
        var s = ThemeSettings(theme: .peach, keyboardTransparency: 100)
        s.keyStyle = KeyStyle(labelColor: 0x3366FF)
        XCTAssertEqual(s.palette(systemDark: true, wallpaperActive: false).keyInk, RGBA(hex: 0x3366FF))
        // Không tuỳ chỉnh ⇒ palette y như cũ.
        let base = KeyboardTheme.mint.palette(systemDark: false)
        XCTAssertEqual(KeyStyle().applyColors(to: base), base)
    }

    // MARK: sao lưu

    func testBackupIncludesKeyStyle() {
        let specs = BackupSettings.byKey
        XCTAssertEqual(specs[KeyStyle.labelColorKey]?.kind, .int(-1, -1...0xFFFFFF))
        XCTAssertEqual(specs[KeyStyle.fillColorKey]?.kind, .int(-1, -1...0xFFFFFF))
        XCTAssertEqual(specs[KeyStyle.cornerKey]?.kind, .int(-1, -1...100))
        XCTAssertEqual(specs[KeyStyle.fontScaleKey]?.kind, .int(0, 0...150))
        XCTAssertEqual(specs[KeyStyle.fontKey]?.kind, .string("default", ["default", "rounded", "serif", "mono", "condensed"]))
        XCTAssertEqual(specs[KeyStyle.weightKey]?.kind, .string("regular", ["light", "regular", "medium", "bold", "heavy"]))

        let a = "keystyle-bk-a-\(UUID().uuidString)", b = "keystyle-bk-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: a)!, db = UserDefaults(suiteName: b)!
        defer { da.removePersistentDomain(forName: a); db.removePersistentDomain(forName: b) }
        Self.custom.save(da)
        let exported = BackupStore(defaults: da, containerURL: nil).settings()
        XCTAssertEqual(exported[KeyStyle.fillColorKey], .int(0x102030))
        XCTAssertEqual(exported[KeyStyle.fontKey], .string("mono"))
        BackupStore(defaults: db, containerURL: nil).setSettings(exported)
        XCTAssertEqual(KeyStyle.load(db), Self.custom)
        // Máy chưa từng chỉnh: xuất giá trị canh = mặc định.
        let fresh = BackupStore(defaults: UserDefaults(suiteName: "keystyle-empty-\(UUID().uuidString)")!,
                                containerURL: nil).settings()
        XCTAssertEqual(fresh[KeyStyle.labelColorKey], .int(-1))
        XCTAssertEqual(fresh[KeyStyle.fontScaleKey], .int(0))
    }
}
