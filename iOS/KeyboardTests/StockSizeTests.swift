import XCTest
import UIKit

/// Issue #119 (iPhone 16 Pro Max, iOS 27): phím/bàn phím lệch bàn phím gốc ⇒ gõ nhầm; "+4 mỗi
/// hàng vẫn lệch". Preset "Kích thước như bàn phím iPhone" (KeyGeometry.StockSize) + dải trống
/// phía trên phím khi đã tắt gợi ý và các phụ trợ.
///
/// Số đo stock (simulator iOS 27.0, 12/10/2026, XCUITest + ảnh @3x): dọc máy < 420pt bước hàng
/// 54 phím 43; máy ≥ 420 (Air/Plus/Pro Max) bước 56 phím 45; ngang bước 40 phím 32, lề 4.33,
/// khe ngang 6.67; thanh dự đoán: mép kính → đỉnh phím 40 (dọc).
final class StockSizeTests: XCTestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    typealias SS = KeyGeometry.StockSize

    // MARK: thuần

    func testStockMetricsByWidth() {
        for w: CGFloat in [375, 390, 393, 402] {
            let m = SS.metrics(width: w, landscape: false)
            XCTAssertEqual(m?.pitch, 54, "\(w)"); XCTAssertEqual(m?.keyHeight, 43, "\(w)")
        }
        for w: CGFloat in [420, 430, 440] {
            let m = SS.metrics(width: w, landscape: false)
            XCTAssertEqual(m?.pitch, 56, "\(w)"); XCTAssertEqual(m?.keyHeight, 45, "\(w)")
        }
        for w: CGFloat in [694, 722, 874] {
            let m = SS.metrics(width: w, landscape: true)
            XCTAssertEqual(m?.pitch, 40); XCTAssertEqual(m?.keyHeight, 32)
            XCTAssertEqual(m?.sideMargin, 4.33); XCTAssertEqual(m?.keyGap, 6.67)
        }
        // SE (nút Home): phím 42, bàn phím sát đáy màn hình ⇒ đệm dưới 4.
        let se = SS.metrics(width: 375, landscape: false, homeButton: true)
        XCTAssertEqual(se?.keyHeight, 42); XCTAssertEqual(se?.pitch, 54); XCTAssertEqual(se?.bottomTrim, -4)
        // Đáy view extension (đo VietTelex trên simulator): dọc 75, ngang 20 trên đáy màn hình.
        XCTAssertEqual(SS.standardPortrait.bottomTrim, 75 - 71)
        XCTAssertEqual(SS.largePortrait.bottomTrim, 75 - 82)
        XCTAssertEqual(SS.landscape.bottomTrim, 20 - 22)
        // Chưa layout (0): đoán dọc máy thường — cùng khe/lề với máy lớn (không phải dựng lại).
        let g = SS.metrics(width: 0, landscape: false)
        XCTAssertEqual(g?.rowGap, SS.largePortrait.rowGap)
        XCTAssertEqual(g?.keyGap, SS.largePortrait.keyGap)
        XCTAssertEqual(g?.sideMargin, SS.largePortrait.sideMargin)
    }

    /// Bố cục mặc định KHÔNG đổi (người dùng cũ giữ thói quen): dọc 54/khe 10/cắt 4/đáy 7,
    /// ngang 162, iPad 240/300, máy gập mở 208.
    func testDefaultRowSpecUnchanged() {
        let p = KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: 440,
                                    base: 216, adjust: 0, stock: false)
        XCTAssertEqual(p, KeyGeometry.RowSpec(unit: 54, gap: 10, bottomTrim: 4, bottomTop: 7,
                                              sideMargin: 6.5, keyGap: 6))
        XCTAssertEqual(p.keyArea(numberRow: false), 212)
        XCTAssertEqual(p.keyArea(numberRow: true), KeyLayout.keyAreaHeight(base: 216, adjust: 0, numberRow: true) - 4,
                       accuracy: 0.001)
        XCTAssertEqual(p.letterKeyHeight, 44); XCTAssertEqual(p.bottomKeyHeight, 43)
        // chỉnh tay +4/hàng vẫn áp như cũ (hàng 58).
        let adj = KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: 440,
                                      base: 216, adjust: 4, stock: false)
        XCTAssertEqual(adj.unit, 58); XCTAssertEqual(adj.bottomTop, 7)
        let l = KeyGeometry.rowSpec(pad: false, landscape: true, unfolded: false, width: 722,
                                    base: 162, adjust: 0, stock: false)
        XCTAssertEqual(l.unit, 40.5); XCTAssertEqual(l.bottomTrim, 0); XCTAssertEqual(l.bottomTop, 10)
        let pad = KeyGeometry.rowSpec(pad: true, landscape: false, unfolded: false, width: 834,
                                      base: 240, adjust: 0, stock: true)
        XCTAssertFalse(pad.stock, "iPad không có preset")
        XCTAssertEqual(pad.unit, 60); XCTAssertEqual(pad.sideMargin, 3); XCTAssertEqual(pad.keyGap, 10)
        let duo = KeyGeometry.rowSpec(pad: false, landscape: true, unfolded: true, width: 801,
                                      base: 208, adjust: 0, stock: true)
        XCTAssertFalse(duo.stock, "máy gập mở: chưa có số đo stock ⇒ giữ bố cục đã đo (208)")
        XCTAssertEqual(duo.unit, 52)
    }

    func testStockRowSpecMatchesStockAndIgnoresAdjust() {
        for (w, pitch, key): (CGFloat, CGFloat, CGFloat) in [(390, 54, 43), (402, 54, 43), (440, 56, 45), (430, 56, 45)] {
            let s = KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: w,
                                        base: 216, adjust: 4, stock: true)
            XCTAssertTrue(s.stock)
            XCTAssertEqual(s.unit, pitch, "\(w)")
            XCTAssertEqual(s.letterKeyHeight, key, "\(w)")
            XCTAssertEqual(s.bottomKeyHeight, key, "\(w): phím đáy cao như phím chữ (stock)")
            XCTAssertEqual(s.bottomTop + s.bottomKeyHeight + s.bottomPad, s.bottomRowHeight)
            XCTAssertEqual(s.sideMargin, 6.67); XCTAssertEqual(s.keyGap, 6)
            XCTAssertEqual(s.keyArea(numberRow: false), 4 * pitch - s.bottomTrim, "\(w)")
            XCTAssertEqual(s, KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: w,
                                                  base: 216, adjust: -7, stock: true), "chỉnh tay bị bỏ qua")
        }
        let l = KeyGeometry.rowSpec(pad: false, landscape: true, unfolded: false, width: 722,
                                    base: 162, adjust: 3, stock: true)
        XCTAssertEqual(l.unit, 40); XCTAssertEqual(l.letterKeyHeight, 32); XCTAssertEqual(l.bottomKeyHeight, 32)
        XCTAssertEqual(l.keyArea(numberRow: false), 162, "4 × 40 + đệm dưới 2")
        XCTAssertEqual(l.bottomPad, 2)
        // Hàng số: phím số = 0.8 × phím chữ (không tính khe) — giữ quy tắc mới với khe stock.
        let p = KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: 440,
                                    base: 216, adjust: 0, stock: true)
        XCTAssertEqual(KeyGeometry.numberRowHeight(unit: p.unit, gap: p.gap) - p.gap, 0.8 * 45, accuracy: 0.001)
    }

    /// Strip gợi ý preset = mép trên → đỉnh phím như thanh dự đoán stock (≈ 40 dọc).
    func testStockOpenStrip() {
        for w: CGFloat in [390, 402, 440] {
            let strip = SS.openStrip(width: w, landscape: false)!
            let m = SS.metrics(width: w, landscape: false)!
            XCTAssertEqual(strip, 29, "\(w)")
            XCTAssertEqual(strip + m.rowGap, m.predictiveTopPad, accuracy: 1, "\(w)")
        }
        XCTAssertEqual(SS.openStrip(width: 722, landscape: true), SS.defaultOpenStrip, "ngang không cao thêm")
    }

    /// Cài mới bật preset, người dùng cũ (đã có cài đặt / mẫu câu / bàn phím từng chạy) thì tắt;
    /// ghi một lần, không ghi đè lựa chọn của người dùng.
    func testSeedForNewInstallsOnly() throws {
        XCTAssertTrue(SS.initialValue(existingKeys: []))
        XCTAssertTrue(SS.initialValue(existingKeys: ["AppleLanguages", "NSInterfaceStyle"]))
        XCTAssertFalse(SS.initialValue(existingKeys: ["rowHeightAdjust"]))
        XCTAssertFalse(SS.initialValue(existingKeys: ["kbLastSeen"]))
        XCTAssertFalse(SS.initialValue(existingKeys: ["autoCorrect"], stateKeys: ["autoCorrect"]))

        let fresh = try XCTUnwrap(UserDefaults(suiteName: "vt.stock.\(UUID().uuidString)"))
        XCTAssertFalse(SS.setting(fresh), "không có khoá = tắt (bàn phím chưa thấy app chạy)")
        XCTAssertTrue(SS.seedIfNeeded(fresh))
        XCTAssertTrue(SS.setting(fresh))
        fresh.set(false, forKey: SS.settingKey)                 // người dùng tắt
        XCTAssertFalse(SS.seedIfNeeded(fresh), "không ghi đè")

        let old = try XCTUnwrap(UserDefaults(suiteName: "vt.stock.\(UUID().uuidString)"))
        old.set(true, forKey: "templatesEnabled")
        XCTAssertFalse(SS.seedIfNeeded(old))
        XCTAssertEqual(old.object(forKey: SS.settingKey) as? Bool, false)
    }

    /// Ảnh nền (app) cắt đúng tỉ lệ bàn phím preset.
    func testWallpaperSizeFollowsPreset() {
        let screen = CGSize(width: 440, height: 956)
        let d = Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false, rowHeightAdjust: 4,
                                       numberRow: false, suggestions: true)
        XCTAssertEqual(d.height, 58 * 4 - 4 + 34)
        let s = Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false, rowHeightAdjust: 4,
                                       numberRow: false, suggestions: true, stockSize: true)
        XCTAssertEqual(s.height, 56 * 4 + 7 + 29)
    }

    // MARK: Dải trống phía trên phím (#119 "thừa khoảng trắng khi đã tắt hết phụ trợ")

    func testHeadroomOnlyWhenSomethingDrawsAboveKeys() {
        XCTAssertEqual(KeyLayout.headroom(needsBalloon: true), KeyLayout.balloonHeadroom)
        XCTAssertEqual(KeyLayout.headroom(needsBalloon: false), KeyLayout.minimalHeadroom)
        let off = KeyLayout.chrome(keyArea: 212, strip: 0, mode: .keys, headroom: KeyLayout.minimalHeadroom)
        XCTAssertEqual(off.rowsTop, 2); XCTAssertEqual(off.total, 214); XCTAssertEqual(off.minTop, 2)
        // Strip mở không bị headroom ảnh hưởng.
        XCTAssertEqual(KeyLayout.chrome(keyArea: 212, strip: 34, mode: .keys, headroom: 2).rowsTop, 34)
        // Mặc định (headroom balloon) giữ như cũ.
        XCTAssertEqual(KeyLayout.chrome(keyArea: 212, strip: 0, mode: .keys).rowsTop, KeyLayout.balloonHeadroom)
    }

    // MARK: View thật

    @MainActor private func make(width: CGFloat, stock: Bool, suggestions: Bool = true,
                                 numberRow: Bool = false) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        kb.configureInputKind(.normal)
        kb.numberRowEnabled = numberRow
        kb.setSuggestionsEnabled(suggestions)
        kb.layoutIfNeeded()
        kb.debugSetStockSize(stock)
        settle(kb)
        return (kb, host)
    }
    /// Host cấp đúng mức xin.
    @MainActor private func settle(_ kb: KeyboardView) {
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
    }
    private func frame(_ kb: KeyboardView, _ v: UIView) -> CGRect { kb.convert(v.bounds, from: v) }

    @MainActor func testPortraitMatchesStockPerWidth() throws {
        try XCTSkipIf(isPad)
        for (w, pitch, key): (CGFloat, CGFloat, CGFloat) in [(390, 54, 43), (402, 54, 43),
                                                              (420, 56, 45), (430, 56, 45), (440, 56, 45)] {
            let (kb, host) = make(width: w, stock: true)
            let q = try XCTUnwrap(kb.debugLetterFrame("q")), a = try XCTUnwrap(kb.debugLetterFrame("a"))
            let z = try XCTUnwrap(kb.debugLetterFrame("z")), p = try XCTUnwrap(kb.debugLetterFrame("p"))
            XCTAssertEqual(q.height, key, accuracy: 0.5, "\(w) phím chữ")
            XCTAssertEqual(a.minY - q.minY, pitch, accuracy: 0.5, "\(w) bước hàng")
            XCTAssertEqual(z.minY - a.minY, pitch, accuracy: 0.5, "\(w) bước hàng")
            // Ngang như stock: lề 6.67, khe 6.
            XCTAssertEqual(q.minX, 6.67, accuracy: 0.5, "\(w)")
            XCTAssertEqual(p.maxX, w - 6.67, accuracy: 0.5, "\(w)")
            XCTAssertEqual(q.width, (w - 2 * 6.67 - 9 * 6) / 10, accuracy: 0.5, "\(w)")
            let m = try XCTUnwrap(SS.metrics(width: w, landscape: false))
            let num = frame(kb, try XCTUnwrap(kb.debugControl("Số")))
            XCTAssertEqual(num.height, key, accuracy: 0.5, "\(w) phím đáy")
            // Hàng đáy cùng bước stock; máy thường phím đáy stock nằm thấp hơn đáy view 4pt (vùng
            // 🌐/mic hệ thống) ⇒ phím đáy mình cao hơn stock đúng phần đó, 3 hàng chữ vẫn trùng.
            XCTAssertEqual(num.minY - z.minY, pitch - max(m.bottomTrim, 0), accuracy: 0.5, "\(w) hàng đáy")
            // Đỉnh phím hàng 1 cách mép trên đúng như thanh dự đoán stock (~40).
            XCTAssertEqual(q.minY, m.predictiveTopPad, accuracy: 1, "\(w) mép trên → phím")
            XCTAssertEqual(kb.debugRequestedHeight, 29 + 4 * pitch - m.bottomTrim, accuracy: 0.5, "\(w) tổng")
            // Vị trí tính từ ĐÁY view (= 75pt trên đáy màn hình): hàng Q trùng stock. 440: stock
            // đỉnh Q cách đáy màn hình 295 ⇒ cách đáy view 220; 402: 276 ⇒ 201.
            let h = kb.bounds.height
            XCTAssertEqual(h - q.minY, 4 * pitch - m.rowGap - m.bottomTrim, accuracy: 0.5, "\(w) Q từ đáy")
            XCTAssertEqual(h - q.minY, w >= 420 ? 220 : 201, accuracy: 0.5, "\(w)")
            XCTAssertEqual(h - num.maxY, max(-m.bottomTrim, 0), accuracy: 0.5, "\(w) đệm dưới phím đáy")
            withExtendedLifetime(host) {}
        }
    }

    /// SE (nút Home — bàn phím có 🌐 riêng): phím 42, đệm dưới 4 như stock sát đáy màn hình.
    @MainActor func testHomeButtonPhone() throws {
        try XCTSkipIf(isPad)
        let kb = KeyboardView(needsGlobe: true, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 500))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: 375, height: 320)
        kb.configureInputKind(.normal)
        kb.setSuggestionsEnabled(true)
        kb.layoutIfNeeded()
        kb.debugSetStockSize(true)
        settle(kb)
        let q = try XCTUnwrap(kb.debugLetterFrame("q")), a = try XCTUnwrap(kb.debugLetterFrame("a"))
        XCTAssertEqual(q.height, 42, accuracy: 0.5)
        XCTAssertEqual(a.minY - q.minY, 54, accuracy: 0.5)
        let num = frame(kb, try XCTUnwrap(kb.debugControl("Số")))
        XCTAssertEqual(num.height, 42, accuracy: 0.5)
        XCTAssertEqual(kb.bounds.height - num.maxY, 4, accuracy: 0.5)
        XCTAssertEqual(q.minX, 6.5, accuracy: 0.5)
        withExtendedLifetime(host) {}
    }

    /// Bố cục mặc định giữ nguyên khi preset tắt (q 44, bước 54) — cả trên máy lớn.
    @MainActor func testOffKeepsDefaultLayout() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = make(width: 440, stock: false)
        let q = try XCTUnwrap(kb.debugLetterFrame("q")), a = try XCTUnwrap(kb.debugLetterFrame("a"))
        XCTAssertEqual(q.height, 44, accuracy: 0.5)
        XCTAssertEqual(a.minY - q.minY, 54, accuracy: 0.5)
        XCTAssertEqual(q.minX, 6.5, accuracy: 0.5)
        XCTAssertEqual(kb.debugRequestedHeight, 34 + 212, accuracy: 0.5)
        // Bật rồi tắt lại: về đúng bố cục cũ.
        kb.debugSetStockSize(true); settle(kb)
        XCTAssertEqual(try XCTUnwrap(kb.debugLetterFrame("q")).height, 45, accuracy: 0.5)
        kb.debugSetStockSize(false); settle(kb)
        XCTAssertEqual(try XCTUnwrap(kb.debugLetterFrame("q")).height, 44, accuracy: 0.5)
        XCTAssertEqual(kb.debugRequestedHeight, 34 + 212, accuracy: 0.5)
        withExtendedLifetime(host) {}
    }

    @MainActor func testLandscapeMatchesStock() throws {
        try XCTSkipIf(isPad)
        for w: CGFloat in [694, 722] {
            let (kb, host) = make(width: w, stock: true)
            let q = try XCTUnwrap(kb.debugLetterFrame("q")), a = try XCTUnwrap(kb.debugLetterFrame("a"))
            let p = try XCTUnwrap(kb.debugLetterFrame("p")), w2 = try XCTUnwrap(kb.debugLetterFrame("w"))
            XCTAssertEqual(q.height, 32, accuracy: 0.5)
            XCTAssertEqual(a.minY - q.minY, 40, accuracy: 0.5)
            XCTAssertEqual(q.minX, 4.33, accuracy: 0.5)
            XCTAssertEqual(p.maxX, w - 4.33, accuracy: 0.5)
            XCTAssertEqual(w2.minX - q.maxX, 6.67, accuracy: 0.5, "khe ngang stock")
            XCTAssertEqual(frame(kb, try XCTUnwrap(kb.debugControl("Số"))).height, 32, accuracy: 0.5)
            withExtendedLifetime(host) {}
        }
    }

    /// Xoay khi preset bật: khe/lề dọc ↔ ngang khác nhau ⇒ dựng lại, không giữ khe cũ.
    @MainActor func testRotationRebuildsStockGeometry() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = make(width: 440, stock: true)
        XCTAssertEqual(try XCTUnwrap(kb.debugLetterFrame("q")).minX, 6.67, accuracy: 0.5)
        host.frame.size.width = 722; kb.frame.size.width = 722
        settle(kb)
        let q = try XCTUnwrap(kb.debugLetterFrame("q")), w2 = try XCTUnwrap(kb.debugLetterFrame("w"))
        XCTAssertEqual(q.minX, 4.33, accuracy: 0.5)
        XCTAssertEqual(w2.minX - q.maxX, 6.67, accuracy: 0.5)
        XCTAssertEqual(q.height, 32, accuracy: 0.5)
        host.frame.size.width = 440; kb.frame.size.width = 440
        settle(kb)
        let q2 = try XCTUnwrap(kb.debugLetterFrame("q"))
        XCTAssertEqual(q2.minX, 6.67, accuracy: 0.5)
        XCTAssertEqual(q2.height, 45, accuracy: 0.5)
        withExtendedLifetime(host) {}
    }

    /// Hàng số + preset: phím số 0.8× phím chữ, hàng chữ vẫn bước stock.
    @MainActor func testNumberRowWithPreset() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = make(width: 440, stock: true, numberRow: true)
        let q = try XCTUnwrap(kb.debugLetterFrame("q")), a = try XCTUnwrap(kb.debugLetterFrame("a"))
        let one = frame(kb, try XCTUnwrap(kb.debugKeyButton("1")))
        XCTAssertEqual(q.height, 45, accuracy: 0.5)
        XCTAssertEqual(a.minY - q.minY, 56, accuracy: 0.5)
        XCTAssertEqual(one.height, 0.8 * 45, accuracy: 0.75)
        XCTAssertEqual(q.minY - one.maxY, 11, accuracy: 0.5, "khe stock giữa hàng số và hàng chữ")
        withExtendedLifetime(host) {}
    }

    /// Một tay + preset: thu hẹp như cũ, chiều cao phím theo preset.
    @MainActor func testOneHandWithPreset() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = make(width: 440, stock: true)
        kb.configureOneHand(.right)
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        let i = OneHand.insets(width: 440, side: .right)
        let q = try XCTUnwrap(kb.debugLetterFrame("q")), p = try XCTUnwrap(kb.debugLetterFrame("p"))
        XCTAssertEqual(q.minX, i.left + 6.67, accuracy: 0.5)
        XCTAssertEqual(p.maxX, 440 - i.right - 6.67, accuracy: 0.5)
        XCTAssertEqual(q.height, 45, accuracy: 0.5)
        withExtendedLifetime(host) {}
    }

    /// Tách đôi (ngang) + preset: vẫn tách, phím cao 32 như stock ngang.
    @MainActor func testSplitWithPreset() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = make(width: 874, stock: true)
        kb.debugSetSplit(true); settle(kb)
        XCTAssertTrue(kb.debugIsSplit)
        XCTAssertEqual(try XCTUnwrap(kb.debugLetterFrame("q")).height, 32, accuracy: 0.5)
        let rows = kb.debugRowFrames()
        for r in rows.dropLast() { XCTAssertEqual(r.height, 40, accuracy: 0.5) }
        XCTAssertEqual(rows.last?.height ?? 0, 42, accuracy: 0.5, "hàng đáy + đệm dưới 2 (stock ngang)")
        withExtendedLifetime(host) {}
    }

    /// Mọi tổ hợp phụ trợ: gợi ý (tắt / bật / thu gọn không áp ở đây), ô phóng to, giữ phím ra
    /// ký tự phụ, mẫu câu, preset. Dải trên phím = strip khi gợi ý bật; tắt gợi ý thì chỉ
    /// headroom balloon khi CÓ thứ vẽ lên trên phím, còn không thì 2pt (khe + 2 ≈ stock 12–13).
    @MainActor func testBlankBandAllHelperCombos() throws {
        try XCTSkipIf(isPad)
        for stock in [false, true] {
            for suggestions in [false, true] {
                for preview in [false, true] {
                    for alts in [false, true] {
                        let (kb, host) = make(width: 440, stock: stock, suggestions: suggestions)
                        kb.debugSetKeyPreview(preview)
                        kb.configureKeyAlternates(numbers: alts, symbols: false)
                        kb.debugRefreshChrome(); settle(kb)
                        let what = "stock \(stock) gợi ý \(suggestions) phóng to \(preview) ký tự phụ \(alts)"
                        let strip: CGFloat = suggestions ? (stock ? 29 : 34) : 0
                        let head: CGFloat = (preview || alts) ? KeyLayout.balloonHeadroom : KeyLayout.minimalHeadroom
                        XCTAssertEqual(kb.debugRowsTop, max(strip, head), what)
                        let q = try XCTUnwrap(kb.debugLetterFrame("q"))
                        XCTAssertEqual(q.minY, max(strip, head) + (stock ? 11 : 10), accuracy: 0.5, what)
                        if !suggestions && !preview && !alts {
                            // Tắt hết: đỉnh phím cách mép trên ≈ stock không thanh dự đoán (12–13).
                            XCTAssertLessThanOrEqual(q.minY, 13.5, what)
                        }
                        if preview || alts {
                            // Balloon hàng đầu vẫn nằm trọn trong view.
                            let b = try XCTUnwrap(kb.debugBalloon(letter: "e", text: "3"), what)
                            XCTAssertGreaterThanOrEqual(b.frame.minY, -0.5, what)
                            XCTAssertGreaterThanOrEqual(b.label.minY, -0.5, what)
                        }
                        withExtendedLifetime(host) {}
                    }
                }
            }
        }
    }
}
