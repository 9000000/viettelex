import XCTest
import ImageIO


/// Khung cắt ảnh nền (trình chỉnh kéo/zoom): toán chuẩn hoá ↔ px, ràng buộc phủ kín,
/// suy khung ngang, mặc định ảnh cũ, bàn phím giải đúng vùng cắt, RAM ≤ trước.
/// Cùng số với android/keyboard WallpaperCropTests.
final class WallpaperCropTests: XCTestCase {
    private let acc = 1e-9

    // MARK: toán khung

    func testCoverLandscapePhotoTouchesTopAndBottom() {
        // Ảnh ngang 4000×3000 (1.33), khung 1.2 (hẹp hơn ảnh): phủ = chạm trên-dưới.
        let c = WallpaperCrop.cover(imageWidth: 4000, imageHeight: 3000, frameAspect: 1.2)
        XCTAssertEqual(c.h, 1, accuracy: acc)
        XCTAssertEqual(c.w, 3000 * 1.2 / 4000, accuracy: acc)
        XCTAssertEqual(c.centerX, 0.5, accuracy: acc)
        XCTAssertEqual(c.aspect(imageWidth: 4000, imageHeight: 3000), 1.2, accuracy: 1e-9)
        // Khung 1.608 (bàn phím 402×250) rộng hơn ảnh ⇒ chạm hai mép trái-phải.
        XCTAssertEqual(WallpaperCrop.cover(imageWidth: 4000, imageHeight: 3000, frameAspect: 1.608).w, 1, accuracy: acc)
    }

    func testCoverPortraitPhotoTouchesSides() {
        let c = WallpaperCrop.cover(imageWidth: 1536, imageHeight: 2048, frameAspect: 1.5)
        XCTAssertEqual(c.w, 1, accuracy: acc)
        XCTAssertEqual(c.h, 1536 / 1.5 / 2048, accuracy: acc)
        XCTAssertEqual(c.centerY, 0.5, accuracy: acc)
    }

    /// Zoom < 1 (lộ viền) bị kẹp về 1; zoom quá maxZoom bị kẹp; tâm kẹp để khung trong ảnh.
    func testCoverConstraintAndClamp() {
        let z = WallpaperCrop.make(imageWidth: 2000, imageHeight: 1000, frameAspect: 1.5,
                                   zoom: 0.3, centerX: 0.5, centerY: 0.5)
        XCTAssertEqual(z, .cover(imageWidth: 2000, imageHeight: 1000, frameAspect: 1.5))
        let far = WallpaperCrop.make(imageWidth: 2000, imageHeight: 1000, frameAspect: 1.5,
                                     zoom: 2, centerX: -3, centerY: 9)
        XCTAssertEqual(far.x, 0, accuracy: acc)
        XCTAssertEqual(far.y + far.h, 1, accuracy: acc)
        let big = WallpaperCrop.make(imageWidth: 2000, imageHeight: 1000, frameAspect: 1.5,
                                     zoom: 99, centerX: 0.5, centerY: 0.5)
        XCTAssertEqual(big.zoom(imageWidth: 2000, imageHeight: 1000), WallpaperCrop.maxZoom, accuracy: 1e-9)
        for c in [z, far, big] {
            XCTAssertGreaterThanOrEqual(c.x, -acc); XCTAssertGreaterThanOrEqual(c.y, -acc)
            XCTAssertLessThanOrEqual(c.x + c.w, 1 + acc); XCTAssertLessThanOrEqual(c.y + c.h, 1 + acc)
            XCTAssertEqual(c.aspect(imageWidth: 2000, imageHeight: 1000), 1.5, accuracy: 1e-9)
        }
    }

    func testNormalizedPixelRoundTrip() {
        let c = WallpaperCrop.make(imageWidth: 2048, imageHeight: 1536, frameAspect: 1.4,
                                   zoom: 1.7, centerX: 0.3, centerY: 0.6)
        let r = c.pixelRect(imageWidth: 2048, imageHeight: 1536)
        XCTAssertEqual(r.minX, (c.x * 2048).rounded(), accuracy: 0.5)
        XCTAssertEqual(r.width / r.height, 1.4, accuracy: 0.01)
        let back = WallpaperCrop(pixelRect: r, imageWidth: 2048, imageHeight: 1536)
        XCTAssertEqual(back.x, c.x, accuracy: 1.0 / 2048)
        XCTAssertEqual(back.w, c.w, accuracy: 1.0 / 2048)
        // Khung chuẩn hoá áp lên bản gốc CỠ KHÁC (vd 1080 cũ) vẫn cùng vùng.
        let small = c.pixelRect(imageWidth: 1024, imageHeight: 768)
        XCTAssertEqual(small.minX * 2, r.minX, accuracy: 2)
        // Pixel rect luôn trong ảnh, ≥1px
        let edge = WallpaperCrop(x: 0.9999, y: 0.9999, w: 0.00001, h: 0.00001).pixelRect(imageWidth: 10, imageHeight: 10)
        XCTAssertEqual(edge, CGRect(x: 9, y: 9, width: 1, height: 1))
    }

    /// Ngang: cùng tâm, cùng bề ngang (dải giữa), nằm trong khung dọc.
    func testLandscapeDerivation() {
        let iw = 3000, ih = 2000
        let p = WallpaperCrop.make(imageWidth: iw, imageHeight: ih, frameAspect: 1.4,
                                   zoom: 1.3, centerX: 0.4, centerY: 0.45)
        let l = p.landscape(imageWidth: iw, imageHeight: ih, aspect: 4)
        XCTAssertEqual(l.centerX, p.centerX, accuracy: acc)
        XCTAssertEqual(l.centerY, p.centerY, accuracy: acc)
        XCTAssertEqual(l.w, p.w, accuracy: acc)
        XCTAssertEqual(l.aspect(imageWidth: iw, imageHeight: ih), 4, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(l.y, p.y); XCTAssertLessThanOrEqual(l.y + l.h, p.y + p.h + acc)
        // Tỉ lệ hẹp hơn khung dọc (iPad đặc biệt): giữ bề cao, lấy dải giữa theo chiều ngang.
        let narrow = p.landscape(imageWidth: iw, imageHeight: ih, aspect: 1)
        XCTAssertEqual(narrow.h, p.h, accuracy: acc)
        XCTAssertLessThan(narrow.w, p.w)
    }

    /// Bàn phím ngang cắt giữa file đã nướng (aspectFillCrop) = đúng khung `landscape`.
    func testKeyboardLandscapeCropMatchesDerivation() {
        let src = RamFixTests.bands(width: 2000, height: 2000)
        let p = WallpaperCrop.make(imageWidth: 2000, imageHeight: 2000, frameAspect: 1.4,
                                   zoom: 1, centerX: 0.5, centerY: 0.5)
        let baked = Wallpaper.render(source: src, crop: p, blur: 0)!
        let out = Wallpaper.aspectFillCrop(baked, to: CGSize(width: 800, height: 200))!
        let l = p.landscape(imageWidth: 2000, imageHeight: 2000, aspect: 4)
        let r = l.pixelRect(imageWidth: 2000, imageHeight: 2000)
        // Tỉ lệ + tỉ lệ thu nhỏ khớp: out phủ đúng vùng r của ảnh gốc
        XCTAssertEqual(Double(out.width) / Double(out.height), r.width / r.height, accuracy: 0.02)
        // Dải giữa (xanh lá: 40–60 % chiều cao) — khung ngang 4:1 cao 357/2000 nằm trọn trong đó.
        let c = RamFixTests.pixel(out, x: out.width / 2, y: out.height / 2)
        XCTAssertGreaterThan(c.g, 200); XCTAssertLessThan(c.r, 60)
    }

    func testRefitKeepsCenterAndZoom() {
        let c = WallpaperCrop.make(imageWidth: 3000, imageHeight: 2000, frameAspect: 1.4,
                                   zoom: 2, centerX: 0.35, centerY: 0.55)
        let r = c.refit(imageWidth: 3000, imageHeight: 2000, frameAspect: 1.2)
        XCTAssertEqual(r.centerX, c.centerX, accuracy: 1e-9)
        XCTAssertEqual(r.centerY, c.centerY, accuracy: 1e-9)
        XCTAssertEqual(r.zoom(imageWidth: 3000, imageHeight: 2000), 2, accuracy: 1e-9)
        XCTAssertEqual(r.aspect(imageWidth: 3000, imageHeight: 2000), 1.2, accuracy: 1e-9)
    }

    // MARK: lưu / migration

    func testSerializationRoundTripAndRejectsGarbage() {
        let c = WallpaperCrop(x: 0.125, y: 0.25, w: 0.5, h: 0.375)
        XCTAssertEqual(c.serialized, "0.12500,0.25000,0.50000,0.37500")
        XCTAssertEqual(WallpaperCrop(serialized: c.serialized), c)
        for bad in [nil, "", "1,2,3", "a,b,c,d", "0,0,0,0.5", "0.6,0,0.6,0.5", "nan,0,0.5,0.5", "-0.5,0,0.5,0.5"] {
            XCTAssertNil(WallpaperCrop(serialized: bad), bad ?? "nil")
        }
    }

    /// Ảnh chọn trước bản này: không có khóa khung ⇒ crop nil ⇒ cắt giữa như cũ;
    /// "Khôi phục giao diện gốc" giữ khung (thuộc về ảnh), Xoá ảnh thì bỏ.
    func testMigrationDefaultAndPersistence() {
        let d = UserDefaults(suiteName: "WallpaperCropTests")!
        d.removePersistentDomain(forName: "WallpaperCropTests")
        d.set(true, forKey: ThemeSettings.wallpaperKey)
        var s = ThemeSettings.load(d)
        XCTAssertNil(s.crop)
        // Không khung ⇒ nướng cả ảnh (bàn phím tự cắt giữa như trước)
        let src = RamFixTests.bands(width: 600, height: 900)
        let full = Wallpaper.render(source: src, crop: nil, blur: 0)!
        XCTAssertEqual(full.width, 600); XCTAssertEqual(full.height, 900)

        s.crop = WallpaperCrop(x: 0.1, y: 0.2, w: 0.5, h: 0.3)
        s.save(d)
        let loaded = ThemeSettings.load(d)
        XCTAssertEqual(loaded.crop!.x, 0.1, accuracy: 1e-5)
        XCTAssertEqual(loaded.resetToDefaults().crop, loaded.crop)
        XCTAssertTrue(loaded.resetToDefaults().isDefault)
        s.crop = nil
        s.save(d)
        XCTAssertNil(d.string(forKey: ThemeSettings.cropKey))
        d.removePersistentDomain(forName: "WallpaperCropTests")
    }

    // MARK: bàn phím giải đúng vùng cắt

    /// Nướng khung ở dải TRÊN (đỏ) → file cho bàn phím chỉ còn vùng đó, bàn phím giải ra đỏ.
    func testKeyboardDecodeUsesCrop() throws {
        let src = RamFixTests.bands(width: 1536, height: 2048)      // đỏ 0–40 %, xanh lá 40–60 %, xanh dương 60–100 %
        // Khung 3:1 cao 25 % ảnh — lọt trong một dải màu.
        let crop = WallpaperCrop.make(imageWidth: 1536, imageHeight: 2048, frameAspect: 3,
                                      zoom: 1, centerX: 0.5, centerY: 0)     // kéo lên đỉnh
        XCTAssertEqual(crop.y, 0, accuracy: acc)
        let data = Wallpaper.prepare(source: src, crop: crop, blur: 0)!
        let cg = Wallpaper.downsample(data: data, maxPixel: 804)!
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 3, accuracy: 0.01)
        for y in [2, cg.height / 2, cg.height - 3] {
            let c = RamFixTests.pixel(cg, x: cg.width / 2, y: y)
            XCTAssertGreaterThan(c.r, 200, "y=\(y)"); XCTAssertLessThan(c.g, 60); XCTAssertLessThan(c.b, 60)
        }
        // Kéo xuống đáy ⇒ xanh dương
        let bottom = WallpaperCrop.make(imageWidth: 1536, imageHeight: 2048, frameAspect: 3,
                                        zoom: 1, centerX: 0.5, centerY: 1)
        let cg2 = Wallpaper.downsample(data: Wallpaper.prepare(source: src, crop: bottom, blur: 0)!, maxPixel: 804)!
        let c2 = RamFixTests.pixel(cg2, x: cg2.width / 2, y: cg2.height / 2)
        XCTAssertGreaterThan(c2.b, 200); XCTAssertLessThan(c2.r, 60)
    }

    /// File đã cắt ≤ maxEdge, và bitmap bàn phím giữ lại (cỡ view @2x) KHÔNG lớn hơn
    /// đường cũ (giải cả ảnh rồi cắt giữa) — đỉnh giải mã nhỏ hơn vì file đã đúng tỉ lệ.
    func testDecodeRamNotAboveBefore() {
        let src = RamFixTests.bands(width: 1536, height: 2048)
        let view = CGSize(width: 402, height: 290), scale: CGFloat = 2
        let target = CGSize(width: view.width * scale, height: view.height * scale)
        // Cũ: ảnh cả khung ≤1080, giải phủ view, cắt giữa.
        let oldData = Wallpaper.encodeJPEG(Wallpaper.render(source: src, crop: nil, blur: 0)!)!
        let oldPx = Wallpaper.displayMaxPixel(viewSize: view, scale: scale, imageAspect: 1536.0 / 2048)
        let oldDecoded = Wallpaper.downsample(data: oldData, maxPixel: oldPx)!
        let oldKept = Wallpaper.aspectFillCrop(oldDecoded, to: target) ?? oldDecoded
        // Mới: file = vùng cắt đúng tỉ lệ view.
        let crop = WallpaperCrop.cover(imageWidth: 1536, imageHeight: 2048, frameAspect: Double(view.width / view.height))
        let newData = Wallpaper.prepare(source: src, crop: crop, blur: 0)!
        let newSrc = CGImageSourceCreateWithData(newData as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(newSrc, 0, nil) as! [CFString: Any]
        let nw = props[kCGImagePropertyPixelWidth] as! Int, nh = props[kCGImagePropertyPixelHeight] as! Int
        XCTAssertLessThanOrEqual(max(nw, nh), Wallpaper.maxEdge)
        let newPx = Wallpaper.displayMaxPixel(viewSize: view, scale: scale, imageAspect: CGFloat(nw) / CGFloat(nh))
        let newDecoded = Wallpaper.downsample(data: newData, maxPixel: newPx)!
        let newKept = Wallpaper.aspectFillCrop(newDecoded, to: target) ?? newDecoded
        func bytes(_ i: CGImage) -> Int { i.bytesPerRow * i.height }
        XCTAssertLessThanOrEqual(bytes(newDecoded), bytes(oldDecoded), "đỉnh giải mã không tăng")
        XCTAssertLessThanOrEqual(bytes(newKept), bytes(oldKept) + bytes(oldKept) / 50, "bitmap giữ lại không tăng")
    }

    // MARK: cỡ khung bàn phím (app)

    func testKeyboardSizeMatchesKeyboardView() {
        // iPhone 402pt dọc = bàn phím gốc (bước 54, cắt 4), gợi ý bật (strip stock 29): 212 + 29.
        let s = Wallpaper.keyboardSize(screenSize: CGSize(width: 402, height: 874), pad: false, landscape: false,
                                       rowHeightAdjust: 0, numberRow: false, suggestions: true)
        XCTAssertEqual(s, CGSize(width: 402, height: 241))
        // Hàng số (khe 11 + phím 0.8×45) + mỗi hàng +2pt, tắt gợi ý: 224 + 47 − 4 = 267.
        let n = Wallpaper.keyboardSize(screenSize: CGSize(width: 874, height: 402), pad: false, landscape: false,
                                       rowHeightAdjust: 2, numberRow: true, suggestions: false)
        XCTAssertEqual(n.width, 402); XCTAssertEqual(n.height, 267, accuracy: 1e-9)
        // Khớp đúng hình học bàn phím thật (KeyGeometry.rowSpec) — ảnh nền không lệch.
        XCTAssertEqual(n.height, KeyGeometry.rowSpec(pad: false, landscape: false, unfolded: false, width: 402,
                                                     base: 216, adjust: 2).keyArea(numberRow: true), accuracy: 1e-9)
        // Ngang: bước 40 + đệm 2, strip 34.
        let l = Wallpaper.keyboardSize(screenSize: CGSize(width: 402, height: 874), pad: false, landscape: true,
                                       rowHeightAdjust: 0, numberRow: false, suggestions: true)
        XCTAssertEqual(l, CGSize(width: 874, height: 196))
        // Nâng bàn phím: ảnh nền phủ cả đệm dưới.
        let r = Wallpaper.keyboardSize(screenSize: CGSize(width: 402, height: 874), pad: false, landscape: false,
                                       rowHeightAdjust: 0, numberRow: false, suggestions: true, raise: 20)
        XCTAssertEqual(r, CGSize(width: 402, height: 261))
        // iPad: bố cục cũ (240 + 4·adjust), strip 34.
        let p = Wallpaper.keyboardSize(screenSize: CGSize(width: 834, height: 1194), pad: true, landscape: false,
                                       rowHeightAdjust: 1, numberRow: false, suggestions: true)
        XCTAssertEqual(p, CGSize(width: 834, height: 244 + 34))
    }
}
