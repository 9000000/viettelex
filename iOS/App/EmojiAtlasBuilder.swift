// EmojiAtlasBuilder — app chủ vẽ sẵn mọi emoji của bàn phím thành trang PNG trong App Group
// (Shared/EmojiAtlas.swift, RAM-AUDIT.md §4b). Chạy nền (QoS utility) lúc app mở khi manifest
// cũ / thiếu: lần đầu, đổi bản iOS, đổi scale/cỡ, đổi bảng emoji (emoji.bin). Cache glyph
// CoreText (~8,5 KB/emoji) giờ nằm ở APP — app không có trần jetsam chặt như bàn phím.
import CoreText
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum EmojiAtlasBuilder {
    /// Nhóm emoji cần vẽ: 8 category (đúng thứ tự lưới, chỉ emoji máy này vẽ được) + "tones"
    /// (biến thể tông da của popup giữ lâu — Recents/tìm kiếm chỉ chứa emoji trong hai tập này).
    static func groups() -> [(name: String, items: [String])] {
        EmojiData.dropCaches()      // không bao giờ lọc theo atlas cũ
        var out: [(String, [String])] = []
        var tones: [String] = []
        for cat in EmojiData.categories {
            var items: [String] = []
            for id in cat.ids {
                let e = EmojiData.emoji(Int(id))
                items.append(e)
                guard let vs = EmojiData.toneVariants(of: e) else { continue }
                // Biến thể của emoji mới hơn mức OS chắc chắn có: kiểm glyph từng cái.
                let check = EmojiData.version(Int(id)) > EmojiData.trustedVersion
                tones += vs.dropFirst().filter { !check || EmojiData.canRender($0) }
            }
            out.append((cat.name, items))
        }
        out.append(("tones", tones))
        EmojiData.dropCaches()
        return out
    }

    enum Format { case png, heic
        var type: UTType { self == .png ? .png : .heic }
        var ext: String { self == .png ? "png" : "heic" }
    }

    struct BuildError: Error { let what: String }

    /// Dựng bản mới vào `root/b<uuid>/`, chuyển con trỏ `current`, xoá bản cũ.
    @discardableResult
    static func build(groups: [(name: String, items: [String])], root: URL, key: EmojiAtlasManifest.Key,
                      format: Format = .png) throws -> EmojiAtlasManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true      // dựng lại được
        var r = root; try? r.setResourceValues(rv)
        let name = "b" + UUID().uuidString
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let scale = CGFloat(key.scale), pt = CGFloat(key.pointSize)
            let slot = EmojiAtlas.slotPx(pointSize: pt, scale: scale)
            let per = EmojiAtlas.cols * EmojiAtlas.rowsPerPage
            var files: [String] = [], rows: [Int] = [], entries: [EmojiAtlasIndex.Entry] = []
            for g in groups where !g.items.isEmpty {
                var start = 0, n = 0
                while start < g.items.count {
                    let chunk = Array(g.items[start..<min(start + per, g.items.count)])
                    let page = files.count
                    let img = try autoreleasepool {
                        try renderPage(chunk, pointSize: pt, scale: scale, slotPx: slot, cols: EmojiAtlas.cols)
                    }
                    let file = "\(g.name)-\(n).\(format.ext)"
                    try write(img, to: dir.appendingPathComponent(file), format: format)
                    files.append(file)
                    rows.append((chunk.count + EmojiAtlas.cols - 1) / EmojiAtlas.cols)
                    for (i, e) in chunk.enumerated() { entries.append(.init(emoji: e, page: page, slot: i)) }
                    start += per; n += 1
                }
            }
            try EmojiAtlasIndex.encode(entries).write(to: dir.appendingPathComponent("index.bin"))
            let m = EmojiAtlasManifest(format: key.format, os: key.os, scale: key.scale, pointSize: key.pointSize,
                                       dataHash: key.dataHash, slotPx: slot, cols: EmojiAtlas.cols,
                                       pageFiles: files, pageRows: rows, count: entries.count)
            try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
            try Data(name.utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
            // Bản cũ: bàn phím đang giữ thì trang thiếu ⇒ ô đó vẽ chữ (không bao giờ lệch ảnh).
            for old in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where old.hasPrefix("b") && old != name {
                try? fm.removeItem(at: root.appendingPathComponent(old))
            }
            return m
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Một trang: ô vuông `slotPx`, emoji căn giữa theo bbox ảnh glyph (như lưới stock).
    static func renderPage(_ items: [String], pointSize: CGFloat, scale: CGFloat, slotPx: Int, cols: Int) throws -> CGImage {
        let rows = (items.count + cols - 1) / cols
        guard let ctx = CGContext(data: nil, width: slotPx * cols, height: slotPx * rows, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw BuildError(what: "context") }
        ctx.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, pointSize, nil)
        let side = CGFloat(slotPx) / scale
        let h = CGFloat(rows) * side
        for (i, e) in items.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = .zero        // bbox tính theo textPosition hiện tại (CTLineDraw dời nó)
            let b = CTLineGetImageBounds(line, ctx)
            // Ô i: hàng tính từ TRÊN (toạ độ ảnh), CG gốc dưới-trái.
            let ox = CGFloat(i % cols) * side, oyTop = CGFloat(i / cols) * side
            let oy = h - oyTop - side
            ctx.textPosition = CGPoint(x: ox + (side - b.width) / 2 - b.minX,
                                       y: oy + (side - b.height) / 2 - b.minY)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: ox, y: oy, width: side, height: side))
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        guard let img = ctx.makeImage() else { throw BuildError(what: "makeImage") }
        return img
    }

    static func encode(_ img: CGImage, format: Format) throws -> Data {
        let d = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(d, format.type.identifier as CFString, 1, nil)
        else { throw BuildError(what: "destination \(format.ext)") }
        CGImageDestinationAddImage(dst, img, (format == .heic
            ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw BuildError(what: "finalize \(format.ext)") }
        return d as Data
    }

    static func write(_ img: CGImage, to url: URL, format: Format) throws {
        try encode(img, format: format).write(to: url)
    }

    // MARK: app

    nonisolated(unsafe) private static var running = false

    /// Gọi lúc app active (main thread): manifest cũ ⇒ dựng nền, không chặn UI.
    static func ensureFresh() {
        guard !running, let root = EmojiAtlas.defaultRoot else { return }
        let scale = UIScreen.main.scale
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        running = true
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { running = false } }
            let key = EmojiAtlas.expectedKey(scale: scale, pad: pad)
            let current = EmojiAtlasManifest.currentBuildDir(root: root).flatMap(EmojiAtlasManifest.read)
            guard let why = EmojiAtlasManifest.staleReason(current, expected: key) else { return }
            let t0 = Date()
            do {
                let m = try build(groups: groups(), root: root, key: key)
                NSLog("EmojiAtlas: dựng lại (%@) %ld emoji, %ld trang, %.1fs", why, m.count, m.pageFiles.count,
                      Date().timeIntervalSince(t0))
            } catch {
                NSLog("EmojiAtlas: lỗi dựng (%@): %@", why, String(describing: error))
            }
        }
    }
}
