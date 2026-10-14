// EmojiData.swift — loader cho Resources/emoji.bin (GENERATED bởi
// Scripts/gen-emoji-data.py từ emoji-test.txt + CLDR vi — KHÔNG sửa tay dữ liệu).
// Blob mmap từ bundle (.alwaysMapped): trang sạch, không copy ra heap. Layout: xem
// docstring của script. Emoji theo 8 category chuẩn Apple (thứ tự stock); Recents
// là category động (EmojiPlane). Emoji mới hơn mức OS chắc chắn vẽ được thì kiểm
// glyph CoreText một lần mỗi process — máy không vẽ được thì ẩn khỏi lưới + tìm kiếm.
import CoreText
import Foundation

enum EmojiData {
    // MARK: blob

    static let blob: Data = {
        final class BundleToken {}
        // App chủ (dựng EmojiAtlas) không chép emoji.bin — đọc bản trong VietTelexKeyboard.appex.
        guard let url = VTBundleResource.url("emoji", "bin", anchor: BundleToken.self),
              let d = try? Data(contentsOf: url, options: .alwaysMapped)
        else { fatalError("emoji.bin missing from bundle") }
        precondition(d.count > 64 && d.prefix(4).elementsEqual("VTE1".utf8), "emoji.bin hỏng")
        return d
    }()

    static func u32(_ off: Int) -> Int {
        Int(UInt32(littleEndian: blob.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)
        }))
    }

    static func u16(_ off: Int) -> Int {
        Int(UInt16(littleEndian: blob.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: off, as: UInt16.self)
        }))
    }

    static func string(_ off: Int, _ len: Int) -> String {
        blob.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[off..<(off + len)]), as: UTF8.self)
        }
    }

    /// Offset tuyệt đối của section `tag` (header: "VTE1" | n | n × (tag, off, len)).
    static func section(_ tag: String) -> Int {
        let n = u32(4)
        let t = Array(tag.utf8)
        for i in 0..<n {
            let h = 8 + i * 12
            if blob[h..<(h + 4)].elementsEqual(t) { return u32(h + 4) }
        }
        fatalError("emoji.bin thiếu section \(tag)")
    }

    private static let emojBase = section("EMOJ")

    /// Hash FNV-1a 64 của section EMOJ (tập chuỗi emoji) — khoá atlas: đổi bảng emoji ⇒ dựng
    /// lại atlas. Chỉ EMOJ: khoá tìm (SKEY) đổi không ảnh hưởng ảnh.
    static let dataHash: String = {
        let n = u32(4)
        var len = 0
        for i in 0..<n where blob[(8 + i * 12)..<(8 + i * 12 + 4)].elementsEqual("EMOJ".utf8) {
            len = u32(8 + i * 12 + 8)
        }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        blob.withUnsafeBytes { raw in
            for b in raw[emojBase..<(emojBase + len)] { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        }
        return String(h, radix: 16)
    }()
    private static let verBase = section("EVER")

    /// Số emoji trong bảng (id 0..<count).
    static let count = u32(emojBase)

    static func emoji(_ id: Int) -> String {
        let o = emojBase + 4 + id * 4
        let start = u32(o), end = u32(o + 4)
        return string(emojBase + 4 + (count + 1) * 4 + start, end - start)
    }

    /// Phiên bản Emoji ×10 (E15.1 → 151).
    static func version(_ id: Int) -> Int {
        Int(blob[verBase + id])
    }

    // MARK: category

    /// (tên, id đầu, số lượng) — thứ tự stock smileys → flags, chưa lọc glyph.
    static let rawCategories: [(name: String, start: Int, count: Int)] = {
        let b = section("ECAT")
        let k = u32(b)
        let namesBase = b + 4 + k * 16
        return (0..<k).map { i in
            let r = b + 4 + i * 16
            return (string(namesBase + u32(r), u32(r + 4)), u32(r + 8), u32(r + 12))
        }
    }()

    /// (tên, id) — đúng thứ tự stock; chỉ emoji máy này vẽ được. Giữ id `UInt16` (chuỗi đọc
    /// lười từ blob mmap qua `emoji(_:)`) thay vì ~3.800 `String` trên heap (−1,7 MB,
    /// RAM-AUDIT.md §4). Cache nhả được: `dropCaches()` khi rời plane emoji / thiếu RAM.
    static var categories: [(name: String, ids: [UInt16])] {
        if let c = cachedCategories { return c }
        let c = rawCategories.map { cat in
            (cat.name, (cat.start..<(cat.start + cat.count)).compactMap { id -> UInt16? in
                isSupported(id) ? UInt16(id) : nil
            })
        }
        cachedCategories = c
        return c
    }
    nonisolated(unsafe) private static var cachedCategories: [(name: String, ids: [UInt16])]?
    static var hasCachedCategories: Bool { cachedCategories != nil }

    /// Rời bảng emoji / cảnh báo bộ nhớ: bỏ bảng category + cache kiểm glyph (dựng lại lười,
    /// kiểm glyph chỉ chạm emoji mới hơn `trustedVersion` — rẻ, testGlyphCheckCost).
    static func dropCaches() {
        cachedCategories = nil
        glyphCache = [:]
        EmojiAtlasStore.release()
    }

    // MARK: lọc glyph

    /// Mức Emoji OS chắc chắn có (×10): dưới/bằng mức này khỏi kiểm glyph.
    /// iOS 16.0 = Emoji 14.0; 16.4 = 15.0; 17.4 = 15.1; 18.4 = 16.0.
    static var trustedVersion: Int {
        if #available(iOS 18.4, *) { return 160 }
        if #available(iOS 17.4, *) { return 151 }
        if #available(iOS 16.4, *) { return 150 }
        return 140
    }

    /// id vẽ được trên máy này (kiểm lười, cache một lần mỗi process).
    /// Atlas hợp lệ đã mở (bảng emoji đang hiện): app chủ đã kiểm glyph trên CHÍNH bản iOS này
    /// (khoá manifest gồm build iOS) và chỉ đưa emoji vẽ được vào atlas ⇒ hỏi atlas, khỏi nạp
    /// font Apple Color Emoji (~1,8 MB) chỉ để kiểm glyph.
    static func isSupported(_ id: Int) -> Bool {
        if version(id) <= trustedVersion { return true }
        if let v = glyphCache[id] { return v }
        let v = EmojiAtlasStore.current?.contains(emoji(id)) ?? canRender(emoji(id))
        glyphCache[id] = v
        return v
    }
    nonisolated(unsafe) private static var glyphCache: [Int: Bool] = [:]

    /// CoreText: chuỗi vẽ bằng ĐÚNG MỘT glyph Apple Color Emoji (không rơi sang font
    /// khác/LastResort, không tách ZWJ/cờ thành nhiều hình).
    static func canRender(_ e: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let attr = NSAttributedString(string: e, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        var visible = 0
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String] as! CTFont
            let name = CTFontCopyPostScriptName(runFont) as String
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var adv = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
            for i in 0..<n where adv[i].width > 0.01 {
                if glyphs[i] == 0 || name != "AppleColorEmoji" { return false }
                visible += 1
            }
        }
        return visible == 1
    }

    // MARK: tông da

    /// [gốc + 5 tông da] nếu emoji có scalar là modifier base; nil nếu không.
    /// Tông áp cho MỌI base trong chuỗi ZWJ (chọn 1 tông cho cả nhóm — như
    /// lựa chọn nhanh của stock; chưa nhớ tông riêng từng emoji). Popup giữ lâu (EmojiPlane)
    /// và atlas (app dựng sẵn ảnh các biến thể) dùng chung.
    static func toneVariants(of e: String) -> [String]? {
        guard e.unicodeScalars.contains(where: { $0.properties.isEmojiModifierBase })
        else { return nil }
        var out = [e]
        for t in 0x1F3FB...0x1F3FF {
            var v = String.UnicodeScalarView()
            for sc in e.unicodeScalars {
                if (0x1F3FB...0x1F3FF).contains(sc.value) { continue }  // bỏ tông cũ
                v.append(sc)
                if sc.properties.isEmojiModifierBase { v.append(Unicode.Scalar(UInt32(t))!) }
            }
            out.append(String(v))
        }
        return out
    }

    // MARK: kaomoji

    /// Nhóm kaomoji / ký tự đặc biệt: (tên nhóm, các mục) — chạm để chèn nguyên văn.
    static let kaomoji: [(name: String, items: [String])] = {
        let b = section("KAOM")
        let g = u32(b)
        let itemsHead = b + 4 + g * 16
        let n = u32(itemsHead)
        let offBase = itemsHead + 4
        let strBase = offBase + (n + 1) * 4
        // chuỗi: tên nhóm trước, rồi item (item offset tính sau khối tên)
        var namesLen = 0
        for i in 0..<g { namesLen += u32(b + 4 + i * 16 + 4) }
        let itemBase = strBase + namesLen
        return (0..<g).map { i in
            let r = b + 4 + i * 16
            let name = string(strBase + u32(r), u32(r + 4))
            let start = u32(r + 8), cnt = u32(r + 12)
            let items = (start..<(start + cnt)).map { j -> String in
                let s = u32(offBase + j * 4), e = u32(offBase + j * 4 + 4)
                return string(itemBase + s, e - s)
            }
            return (name, items)
        }
    }()
}
