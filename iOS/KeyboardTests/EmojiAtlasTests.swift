import XCTest
import UIKit

/// Atlas emoji vẽ sẵn (Shared/EmojiAtlas.swift, App/EmojiAtlasBuilder.swift, RAM-AUDIT.md §4b):
/// index, manifest cũ/mới, dựng vài emoji, tra + rơi về chữ, lưới dùng ảnh, đo RAM (bộ chậm).
final class EmojiAtlasTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-\(UUID().uuidString)")
        EmojiAtlasStore.release()
    }

    override func tearDown() {
        EmojiAtlasStore.release()
        EmojiAtlas.rootOverride = nil
        EmojiData.dropCaches()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private var phoneKey: EmojiAtlasManifest.Key {
        EmojiAtlas.expectedKey(scale: UIScreen.main.scale, pad: false)
    }

    // MARK: index

    func testIndexRoundTripAndMiss() {
        // Tiền tố nhau ("☺" / "☺️"), tông da, ZWJ, cờ — tra đúng từng chuỗi.
        let list = ["😀", "☺", "☺️", "👍", "👍🏽", "👩‍❤️‍👨", "🇻🇳", "a"]
        let entries = list.enumerated().map { EmojiAtlasIndex.Entry(emoji: $1, page: $0 / 3, slot: $0 % 3) }
        let idx = EmojiAtlasIndex(data: EmojiAtlasIndex.encode(entries + [.init(emoji: "😀", page: 9, slot: 9)]))!
        XCTAssertEqual(idx.count, list.count, "trùng chuỗi giữ một")
        for (i, e) in list.enumerated() {
            let loc = idx.locate(e)
            XCTAssertEqual(loc?.page, i / 3, e)
            XCTAssertEqual(loc?.slot, i % 3, e)
        }
        for miss in ["", "🦖", "👍🏿", "☺️☺️", "b", "😀😀"] { XCTAssertNil(idx.locate(miss), miss) }
        XCTAssertNil(EmojiAtlasIndex(data: Data("VTA1".utf8)), "cụt")
        XCTAssertNil(EmojiAtlasIndex(data: Data(repeating: 0, count: 64)), "sai magic")
        var cut = EmojiAtlasIndex.encode(entries); cut.removeLast()
        XCTAssertNil(EmojiAtlasIndex(data: cut), "thiếu byte cuối")
        XCTAssertNil(EmojiAtlasIndex(data: EmojiAtlasIndex.encode([]))?.locate("😀"))
    }

    // MARK: manifest

    func testManifestStaleness() {
        let k = EmojiAtlasManifest.Key(format: EmojiAtlas.format, os: "Version 27.0 (Build X)", scale: 3,
                                       pointSize: 34, dataHash: "abc")
        let m = EmojiAtlasManifest(format: k.format, os: k.os, scale: 3, pointSize: 34, dataHash: "abc",
                                   slotPx: 102, cols: 8, pageFiles: ["a-0.png"], pageRows: [1], count: 3)
        XCTAssertNil(EmojiAtlasManifest.staleReason(m, expected: k))
        XCTAssertEqual(EmojiAtlasManifest.staleReason(nil, expected: k), "missing")
        var x = m; x.os = "Version 27.1 (Build Y)"
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "os", "cập nhật iOS ⇒ dựng lại")
        x = m; x.scale = 2
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "scale")
        x = m; x.pointSize = 52
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "size")
        x = m; x.dataHash = "def"
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "data", "đổi emoji.bin ⇒ dựng lại")
        x = m; x.format = 0
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "format")
        x = m; x.pageRows = []
        XCTAssertEqual(EmojiAtlasManifest.staleReason(x, expected: k), "corrupt")
        // JSON khứ hồi
        let d = try! JSONEncoder().encode(m)
        XCTAssertEqual(try! JSONDecoder().decode(EmojiAtlasManifest.self, from: d), m)
    }

    func testDataHashStableAndKeyedOnEmojiTable() {
        XCTAssertFalse(EmojiData.dataHash.isEmpty)
        XCTAssertEqual(EmojiAtlas.expectedKey(scale: 3, pad: false).dataHash, EmojiData.dataHash)
        XCTAssertEqual(EmojiAtlas.expectedKey(scale: 3, pad: false).pointSize, 34)
        XCTAssertEqual(EmojiAtlas.expectedKey(scale: 2, pad: true).pointSize, 52)
    }

    /// Atlas vẽ ở glyph LỚN NHẤT lưới dùng (EmojiGridMetrics) — lưới chỉ thu nhỏ ảnh.
    func testPointSizeMatchesGridMetrics() {
        let phone = [EmojiGridMetrics.phonePortrait, EmojiGridMetrics.phoneLandscape].map(\.font).max()!
        let pad = [EmojiGridMetrics.padPortrait, EmojiGridMetrics.padLandscape].map(\.font).max()!
        XCTAssertEqual(EmojiAtlas.pointSize(pad: false), phone)
        XCTAssertEqual(EmojiAtlas.pointSize(pad: true), pad)
    }

    // MARK: dựng + tra

    /// Số pixel có alpha > 0 trong ảnh.
    static func opaquePixels(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: buf.count, by: 4).reduce(0) { $0 + (buf[$1] > 0 ? 1 : 0) }
    }

    func testBuildFewEmojiRendersAndLooksUp() throws {
        let groups = [("smileys", ["😀", "❤️", "🇻🇳", "👩‍💻"]), ("tones", ["👍🏽", "👍🏿"])]
        let m = try EmojiAtlasBuilder.build(groups: groups, root: tmp, key: phoneKey)
        XCTAssertEqual(m.count, 6)
        XCTAssertEqual(m.pageFiles, ["smileys-0.png", "tones-0.png"])
        XCTAssertEqual(m.slotPx, EmojiAtlas.slotPx(pointSize: 34, scale: UIScreen.main.scale))
        let store = try XCTUnwrap(EmojiAtlasStore.load(root: tmp, expected: phoneKey))
        let side = m.slotPx
        var pixels: [String: Int] = [:]
        for e in groups.flatMap(\.1) {
            let t = try XCTUnwrap(store.tile(e), e)
            XCTAssertEqual(t.width, side); XCTAssertEqual(t.height, side)
            let n = Self.opaquePixels(t)
            pixels[e] = n
            // glyph bbox ≈ 0,92 cỡ chữ ⇒ phần lớn ô có màu
            XCTAssertGreaterThan(n, side * side / 4, "\(e) gần như rỗng")
        }
        // Hai tông khác nhau ⇒ ảnh khác (không lệch ô)
        let a = store.tile("👍🏽")!, b = store.tile("👍🏿")!
        XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
        // Thiếu ⇒ nil (ô đó vẽ chữ)
        XCTAssertNil(store.tile("🦖"))
        XCTAssertFalse(store.contains("🦖"))
        XCTAssertTrue(store.contains("👩‍💻"))
        XCTAssertEqual(store.cachedPageCount, 2)
        store.dropPages()
        XCTAssertEqual(store.cachedPageCount, 0)
        XCTAssertNotNil(store.tile("😀"), "giải mã lại sau khi nhả")
    }

    func testStoreRejectsMissingStaleAndSwapsBuilds() throws {
        XCTAssertNil(EmojiAtlasStore.load(root: tmp, expected: phoneKey), "chưa dựng")
        try EmojiAtlasBuilder.build(groups: [("smileys", ["😀"])], root: tmp, key: phoneKey)
        var other = phoneKey; other.os = "Version 99.0 (Build Z)"
        XCTAssertNil(EmojiAtlasStore(root: tmp, expected: other), "iOS khác ⇒ bỏ qua")
        let first = try XCTUnwrap(EmojiAtlasStore.load(root: tmp, expected: phoneKey))
        XCTAssertTrue(EmojiAtlasStore.load(root: tmp, expected: phoneKey) === first, "dùng lại bản đã mở")
        let oldDir = first.dir
        // Dựng lại: thư mục mới, bản cũ bị xoá — store cũ trả nil (vẽ chữ), không ảnh sai.
        try EmojiAtlasBuilder.build(groups: [("smileys", ["🐶", "😀"])], root: tmp, key: phoneKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        first.dropPages()
        XCTAssertNil(first.tile("😀"))
        EmojiAtlasStore.release()
        let second = try XCTUnwrap(EmojiAtlasStore.load(root: tmp, expected: phoneKey))
        XCTAssertNotEqual(second.dir, oldDir)
        XCTAssertNotNil(second.tile("🐶"))
        // Con trỏ hỏng ⇒ nil
        try Data("../evil".utf8).write(to: tmp.appendingPathComponent("current"))
        XCTAssertNil(EmojiAtlasStore(root: tmp, expected: phoneKey))
    }

    func testBuilderGroupsCoverGridAndTones() {
        let g = EmojiAtlasBuilder.groups()
        XCTAssertEqual(g.map(\.name), EmojiData.categories.map(\.name) + ["tones"])
        let all = Set(g.flatMap(\.items))
        for cat in EmojiData.categories { for id in cat.ids { XCTAssertTrue(all.contains(EmojiData.emoji(Int(id)))) } }
        XCTAssertTrue(all.contains("👍🏽"))
        XCTAssertTrue(all.contains(EmojiData.toneVariants(of: "👍")![5]))
        XCTAssertGreaterThan(g.last!.items.count, 1000)
        XCTAssertEqual(EmojiPlane.toneVariants(of: "👍"), EmojiData.toneVariants(of: "👍"))
        XCTAssertNil(EmojiData.toneVariants(of: "😀"))
    }

    /// Atlas đã mở: emoji mới hơn mức OS tin cậy mà KHÔNG có trong atlas ⇒ coi như không vẽ được
    /// (app đã kiểm glyph trên chính bản iOS này) — khỏi nạp font chỉ để kiểm.
    func testIsSupportedConsultsOpenAtlas() throws {
        guard let newer = (0..<EmojiData.count).first(where: { EmojiData.version($0) > EmojiData.trustedVersion })
        else { throw XCTSkip("không có emoji mới hơn mức tin cậy") }
        try EmojiAtlasBuilder.build(groups: [("smileys", ["😀"])], root: tmp, key: phoneKey)
        EmojiData.dropCaches()
        XCTAssertNotNil(EmojiAtlasStore.load(root: tmp, expected: phoneKey))
        XCTAssertFalse(EmojiData.isSupported(newer))
        XCTAssertTrue(EmojiData.isSupported(0), "emoji cũ luôn tin")
        EmojiData.dropCaches()
        XCTAssertNil(EmojiAtlasStore.current, "dropCaches nhả atlas")
    }

    // MARK: lưới

    @MainActor func testPlaneDrawsAtlasCellsAndFallsBackToText() throws {
        UserDefaults.standard.removeObject(forKey: "emojiRecents")
        EmojiAtlas.rootOverride = tmp
        EmojiData.dropCaches()
        let smileys = EmojiData.categories.first { $0.name == "smileys" }!.ids.map { EmojiData.emoji(Int($0)) }
        // Chỉ 10 emoji đầu có ảnh ⇒ phần còn lại của màn hình rơi về chữ.
        try EmojiAtlasBuilder.build(groups: [("smileys", Array(smileys.prefix(10)))], root: tmp, key: phoneKey)
        EmojiData.dropCaches()
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        win.isHidden = false
        let plane = EmojiPlane(dark: false, pad: false)
        XCTAssertNotNil(plane.atlas)
        plane.frame = CGRect(x: 0, y: 500, width: 402, height: 290)
        win.addSubview(plane)
        plane.layoutIfNeeded()
        plane.layoutIfNeeded()
        let modes = plane.debugVisibleCellModes
        XCTAssertEqual(modes.image, 10)
        XCTAssertGreaterThan(modes.text, 0)
        XCTAssertTrue(plane.debugVisibleCellLabels.allSatisfy { !($0 ?? "").isEmpty }, "VoiceOver cần nhãn")
        plane.removeFromSuperview()

        // Không atlas ⇒ toàn chữ như cũ.
        EmojiData.dropCaches()
        EmojiAtlas.rootOverride = tmp.appendingPathComponent("none")
        let p2 = EmojiPlane(dark: false, pad: false)
        XCTAssertNil(p2.atlas)
        p2.frame = plane.frame
        win.addSubview(p2)
        p2.layoutIfNeeded(); p2.layoutIfNeeded()
        XCTAssertEqual(p2.debugVisibleCellModes.image, 0)
        XCTAssertGreaterThan(p2.debugVisibleCellModes.text, 0)
        p2.removeFromSuperview()
        win.isHidden = true
    }

    // MARK: đo (bộ chậm)

    /// RAM: vẽ một category bằng chữ (cache glyph CoreText, không nhả) vs từ atlas (giải mã trang,
    /// mỗi ô một bản sao; nhả khi rời). Hai category KHÁC nhau vì dựng atlas trong cùng process đã
    /// nạp glyph của category đó vào cache. Chạy riêng:
    /// TEST_RUNNER_VT_SLOW_TESTS=1 xcodebuild … -only-testing:VietTelexKeyboardTests/EmojiAtlasTests/testMemoryTextVsAtlas test
    @MainActor func testMemoryTextVsAtlas() throws {
        try SlowTests.require()
        let cats = EmojiData.categories
        func items(_ n: String) -> [String] { cats.first { $0.name == n }!.ids.map { EmojiData.emoji(Int($0)) } }
        let atlasCat = items("smileys"), textCat = items("objects")
        // Làm nóng font emoji (1,8 MB một lần) bằng category thứ ba.
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = UIFont.systemFont(ofSize: 34)
        func drawText(_ list: [String]) {
            autoreleasepool {
                for e in list {
                    ctx.textPosition = CGPoint(x: 10, y: 10)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font])), ctx)
                }
            }
        }
        drawText(Array(items("flags").prefix(5)))
        let t0 = Date()
        try EmojiAtlasBuilder.build(groups: [("smileys", atlasCat)], root: tmp, key: phoneKey)
        let buildSec = Date().timeIntervalSince(t0)
        RamBreakdownTests.spin(0.3)

        // Atlas: lướt cả category, giữ cửa sổ 60 ô gần nhất (≈ ô lưới đang sống) + LRU trang.
        var f0 = KeyboardBenchTests.footprintMB(), h0 = RamBreakdownTests.heapBytes()
        var peakF = f0, peakH = h0
        let ta = Date()
        autoreleasepool {
            let store = EmojiAtlasStore.load(root: tmp, expected: phoneKey)!
            var live: [CGImage] = []
            for e in atlasCat {
                if let t = store.tile(e) { live.append(t) }
                if live.count > 60 { live.removeFirst() }
                peakF = max(peakF, KeyboardBenchTests.footprintMB()); peakH = max(peakH, RamBreakdownTests.heapBytes())
            }
            print(String(format: "ATLASMEM decodes=%d", store.pageDecodes))
            live.removeAll()
            EmojiAtlasStore.release()
        }
        let atlasMs = Date().timeIntervalSince(ta) * 1000
        RamBreakdownTests.spin(0.3)
        let fa = KeyboardBenchTests.footprintMB(), ha = RamBreakdownTests.heapBytes()
        print(String(format: "ATLASMEM atlas %d emoji: peak foot %+.1fMB heap %+.1fMB | sau khi nhả foot %+.1fMB heap %+.2fMB | %.0f ms (%.2f ms/emoji) | build %.2fs",
                     atlasCat.count, peakF - f0, Double(peakH - h0) / 1_048_576, fa - f0,
                     Double(ha - h0) / 1_048_576, atlasMs, atlasMs / Double(atlasCat.count), buildSec))
        let atlasRetained = ha - h0

        // Chữ: cùng số emoji của category khác.
        f0 = KeyboardBenchTests.footprintMB(); h0 = RamBreakdownTests.heapBytes()
        let tt = Date()
        drawText(textCat)
        let textMs = Date().timeIntervalSince(tt) * 1000
        RamBreakdownTests.spin(0.3)
        let ft = KeyboardBenchTests.footprintMB(), ht = RamBreakdownTests.heapBytes()
        print(String(format: "ATLASMEM text %d emoji: foot %+.1fMB heap %+.1fMB (%.1f KB/emoji, không nhả được) | %.0f ms",
                     textCat.count, ft - f0, Double(ht - h0) / 1_048_576,
                     Double(ht - h0) / 1024 / Double(textCat.count), textMs))
        XCTAssertLessThan(atlasRetained, (ht - h0) / 4, "atlas phải nhả gần hết khi rời")
    }

    /// Lưới thật (EmojiPlane trong cửa sổ): mở, lướt HẾT mọi category, rời — phys_footprint. Hai
    /// biến thể chạy ở HAI process riêng (cache glyph không xả được nên không so trong một process):
    ///   -only-testing:…/EmojiAtlasTests/testPlaneScrollMemoryText
    ///   -only-testing:…/EmojiAtlasTests/testPlaneScrollMemoryAtlas
    @MainActor func testPlaneScrollMemoryText() throws { try planeScrollMemory(atlas: false) }
    @MainActor func testPlaneScrollMemoryAtlas() throws { try planeScrollMemory(atlas: true) }

    @MainActor private func planeScrollMemory(atlas: Bool) throws {
        try SlowTests.require()
        UserDefaults.standard.removeObject(forKey: "emojiRecents")
        EmojiAtlas.rootOverride = tmp
        if atlas {
            // Dựng trong process test (nạp cache glyph của MỌI emoji — thành nền, trước f0).
            try EmojiAtlasBuilder.build(groups: EmojiAtlasBuilder.groups(), root: tmp, key: phoneKey)
        } else {
            _ = EmojiData.canRender("😀")     // nạp font như biến thể atlas (dựng atlas đã nạp)
        }
        EmojiData.dropCaches()
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        win.isHidden = false
        RamBreakdownTests.spin(0.5)
        let f0 = KeyboardBenchTests.footprintMB()
        var plane: EmojiPlane? = EmojiPlane(dark: false, pad: false)
        XCTAssertEqual(plane!.atlas != nil, atlas)
        plane!.frame = CGRect(x: 0, y: 500, width: 402, height: 290)
        win.addSubview(plane!)
        plane!.layoutIfNeeded()
        RamBreakdownTests.spin(0.3)
        let fOpen = KeyboardBenchTests.footprintMB()
        let cv = RamBreakdownTests.find(UICollectionView.self, in: plane!)!
        var peak = fOpen
        var x: CGFloat = 0
        let t0 = Date()
        while x < cv.contentSize.width {
            x += cv.bounds.width
            cv.contentOffset.x = min(x, max(cv.contentSize.width - cv.bounds.width, 0))
            cv.layoutIfNeeded()
            RamBreakdownTests.spin(0.01)
            peak = max(peak, KeyboardBenchTests.footprintMB())
        }
        let scrollMs = Date().timeIntervalSince(t0) * 1000
        RamBreakdownTests.spin(0.3)
        let fEnd = KeyboardBenchTests.footprintMB()
        plane!.removeFromSuperview()
        plane = nil
        EmojiData.dropCaches()
        RamBreakdownTests.spin(0.5)
        let fLeft = KeyboardBenchTests.footprintMB()
        print(String(format: "ATLASPLANE %@: mở %+.1f | lướt hết (cuối) %+.1f, đỉnh %+.1f | rời %+.1f MB | lướt %.0f ms",
                     atlas ? "atlas" : "text", fOpen - f0, fEnd - f0, peak - f0, fLeft - f0, scrollMs))
        win.isHidden = true
    }

    /// Dung lượng đĩa + thời gian dựng TOÀN BỘ atlas (PNG vs HEIC) trên simulator.
    func testFullAtlasDiskSize() throws {
        try SlowTests.require()
        let groups = EmojiAtlasBuilder.groups()
        func size(_ dir: URL) -> Int {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])!
            return e.reduce(0) { $0 + ((try? ($1 as! URL).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) ?? 0 }
        }
        for fmt in [EmojiAtlasBuilder.Format.png, .heic] {
            let root = tmp.appendingPathComponent(fmt.ext)
            let t0 = Date()
            do {
                let m = try EmojiAtlasBuilder.build(groups: groups, root: root, key: phoneKey, format: fmt)
                let sec = Date().timeIntervalSince(t0)
                // Giải mã một trang: thời gian
                let store = EmojiAtlasStore(root: root, expected: phoneKey)!
                let td = Date()
                for p in 0..<min(20, m.pageFiles.count) { _ = store.pageImage(p); store.dropPages() }
                let decMs = Date().timeIntervalSince(td) * 1000 / Double(min(20, m.pageFiles.count))
                // Mẫu để xem bằng mắt: <tmp>/atlas-sample.<fmt>
                let sample = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-sample.\(fmt.ext)")
                try? FileManager.default.removeItem(at: sample)
                try? FileManager.default.copyItem(at: store.dir.appendingPathComponent(m.pageFiles[0]), to: sample)
                print("ATLASDISK sample \(sample.path)")
                print(String(format: "ATLASDISK %@: %d emoji, %d trang, %.2f MB, dựng %.1fs, giải mã %.2f ms/trang (%dx%d)",
                             fmt.ext, m.count, m.pageFiles.count, Double(size(root)) / 1_048_576, sec, decMs,
                             m.slotPx * m.cols, m.slotPx * EmojiAtlas.rowsPerPage))
            } catch {
                print("ATLASDISK \(fmt.ext): lỗi \(error)")
            }
        }
    }
}
