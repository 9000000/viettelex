import XCTest
import UIKit

/// Tuỳ chọn "Hàng số cao bằng hàng chữ" (13/10/2026, mặc định TẮT): bật ⇒ phím số = phím
/// chữ (tỉ lệ 1), bàn phím cao thêm đúng một hàng chữ; chỉnh ±hàng và "Nâng bàn phím" vẫn áp.
/// Tắt ⇒ y hệt trước (phím số 0.8× — NumberRowTests).
final class NumberRowFullHeightTests: XCTestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func testRatioAndRowHeight() {
        XCTAssertEqual(KeyGeometry.numberKeyRatio(fullHeight: false), 0.8)
        XCTAssertEqual(KeyGeometry.numberKeyRatio(fullHeight: true), 1)
        for unit: CGFloat in [36, 40.5, 54, 60, 70] {
            for gap: CGFloat in [10, 11] {
                XCTAssertEqual(KeyGeometry.numberRowHeight(unit: unit, gap: gap, fullHeight: true), unit,
                               accuracy: 0.001, "unit=\(unit) gap=\(gap)")
                XCTAssertEqual(KeyGeometry.numberRowHeight(unit: unit, gap: gap),
                               gap + 0.8 * (unit - gap), accuracy: 0.001)
            }
        }
        XCTAssertEqual(KeyLayout.numberRowMultiplier(fullHeight: true), 1)
        XCTAssertEqual(KeyLayout.numberRowConstant(fullHeight: true), 0)
        XCTAssertEqual(KeyLayout.numberRowMultiplier(fullHeight: false), KeyLayout.numberRowMultiplier)
        XCTAssertEqual(KeyLayout.numberRowConstant(fullHeight: false), KeyLayout.numberRowConstant)
    }

    /// keyAreaHeight = 5 hàng chữ; rowUnit là nghịch đảo (iPad / máy gập / ngang / chỉnh hàng).
    func testKeyAreaHeightAndRowUnitFullHeight() {
        XCTAssertEqual(KeyLayout.keyAreaHeight(base: 216, adjust: 0, numberRow: true, fullHeight: true), 270)
        XCTAssertEqual(KeyLayout.keyAreaHeight(base: 240, adjust: 5, numberRow: true, fullHeight: true), 325)
        // Hàng số tắt: công tắc vô nghĩa.
        XCTAssertEqual(KeyLayout.keyAreaHeight(base: 216, adjust: 0, numberRow: false, fullHeight: true), 216)
        for base: CGFloat in [162, 208, 216, 240, 300] {
            for adj: CGFloat in [-10, 0, 10] {
                for full in [false, true] {
                    let area = KeyLayout.keyAreaHeight(base: base, adjust: adj, numberRow: true, fullHeight: full)
                    XCTAssertEqual(KeyLayout.rowUnit(keyArea: area, numberRow: true, fullHeight: full),
                                   (base + 4 * adj) / 4, accuracy: 0.001, "base=\(base) adj=\(adj) full=\(full)")
                }
            }
        }
    }

    /// RowSpec (iPhone theo số đo stock, iPad, ngang, chỉnh ±): bật ⇒ vùng phím = 5 bước hàng − trim;
    /// tắt ⇒ giữ công thức 0.8 cũ.
    func testRowSpecKeyArea() {
        let cases: [(pad: Bool, landscape: Bool, w: CGFloat, base: CGFloat)] = [
            (false, false, 375, 216), (false, false, 402, 216), (false, false, 440, 216),
            (false, true, 874, 162), (true, false, 834, 240), (true, true, 1194, 300),
        ]
        for c in cases {
            for a: CGFloat in [-3, 0, 5] {
                let s = KeyGeometry.rowSpec(pad: c.pad, landscape: c.landscape, unfolded: false, width: c.w,
                                            base: c.base, adjust: a)
                let what = "\(c) adj=\(a)"
                XCTAssertEqual(s.keyArea(numberRow: true, fullHeight: true), 5 * s.unit - s.bottomTrim,
                               accuracy: 0.001, what)
                XCTAssertEqual(s.keyArea(numberRow: true),
                               4 * s.unit + s.gap + 0.8 * (s.unit - s.gap) - s.bottomTrim, accuracy: 0.001, what)
                XCTAssertEqual(s.keyArea(numberRow: true, fullHeight: false), s.keyArea(numberRow: true), what)
                XCTAssertEqual(s.keyArea(numberRow: false, fullHeight: true), s.keyArea(numberRow: false), what)
                XCTAssertEqual(s.numberRowConstant(fullHeight: true), 0, what)
                XCTAssertEqual(s.numberRowConstant(fullHeight: false), s.numberRowConstant, what)
            }
        }
    }

    /// Ảnh nền trong app phủ đúng chiều cao mới.
    func testWallpaperSizeGrows() {
        let screen = CGSize(width: 402, height: 874)
        let off = Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false, rowHeightAdjust: 2,
                                         numberRow: true, suggestions: true, raise: 8)
        let on = Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false, rowHeightAdjust: 2,
                                        numberRow: true, suggestions: true, raise: 8, numberRowFullHeight: true)
        let s = KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: 402, base: 216, adjust: 2)
        XCTAssertEqual(on.height - off.height, 0.2 * s.letterKeyHeight, accuracy: 0.001)
        let noRow = Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false, rowHeightAdjust: 2,
                                           numberRow: false, suggestions: true, numberRowFullHeight: true)
        XCTAssertEqual(noRow, Wallpaper.keyboardSize(screenSize: screen, pad: false, landscape: false,
                                                     rowHeightAdjust: 2, numberRow: false, suggestions: true))
    }

    // MARK: KeyboardView

    @MainActor private func make(width: CGFloat, full: Bool, adjust: Int = 0, raise: Int = 0) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        kb.configureInputKind(.normal)
        kb.numberRowEnabled = true
        kb.numberRowFullHeight = full
        kb.layoutIfNeeded()
        kb.debugSetRowAdjust(adjust)
        kb.debugSetRaise(raise)
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor func testOffByDefault() {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        XCTAssertFalse(kb.numberRowFullHeight)
    }

    /// Bật: hàng số cao bằng hàng chữ, phím "1" cao bằng phím q; tổng xin thêm đúng 0.2 phím chữ
    /// so với khi tắt (kể cả chỉnh ±hàng, nâng bàn phím).
    @MainActor func testNumberRowMatchesLetterRow() throws {
        let widths: [CGFloat] = isPad ? [834] : [375, 402, 440]
        for w in widths {
            for (adj, raise) in [(0, 0), (3, 0), (-2, 12)] {
                let what = "w=\(w) adj=\(adj) raise=\(raise)"
                let (off, h0) = make(width: w, full: false, adjust: adj, raise: raise)
                let (on, h1) = make(width: w, full: true, adjust: adj, raise: raise)
                let rows = on.debugRowFrames()
                XCTAssertEqual(rows.count, 5, what)
                guard rows.count == 5 else { continue }
                XCTAssertEqual(rows[0].height, rows[1].height, accuracy: 0.5, what)
                let q = try XCTUnwrap(on.debugLetterFrame("q"), what)
                let one = try XCTUnwrap(on.debugKeyButton("1"), what)
                XCTAssertEqual(on.convert(one.bounds, from: one).height, q.height, accuracy: 0.5, what)
                // Phím chữ giữ nguyên cỡ — chỉ hàng số cao lên.
                let q0 = try XCTUnwrap(off.debugLetterFrame("q"), what)
                XCTAssertEqual(q.height, q0.height, accuracy: 0.5, what)
                XCTAssertEqual(on.debugRequestedHeight - off.debugRequestedHeight,
                               0.2 * on.rowSpec.letterKeyHeight, accuracy: 0.5, what)
                withExtendedLifetime((h0, h1)) {}
            }
        }
    }

    /// Đổi công tắc lúc đang hiện ⇒ dựng lại (vứt planeCache), tắt lại về 0.8×.
    @MainActor func testToggleRebuilds() throws {
        let (kb, host) = make(width: isPad ? 834 : 402, full: true)
        kb.numberRowFullHeight = false
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        let rows = kb.debugRowFrames()
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].height, KeyGeometry.numberRowHeight(unit: rows[1].height, gap: kb.rowSpec.gap),
                       accuracy: 0.5)
        withExtendedLifetime(host) {}
    }
}
