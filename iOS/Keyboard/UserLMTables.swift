// UserLMTables — bảng n-gram gọn + định dạng file VTL2 của UserLangModel (tách khỏi
// UserLangModel.swift 16/10/2026 để macOS/Linux dùng CHUNG đúng mã này cho "Học từ bạn gõ"
// trên máy tính — App/Sources/LearnedModel.swift — mà không kéo theo phần di trú plist/JSON,
// sao lưu, từ điển cá nhân của iOS). Chỉ phụ thuộc Foundation (Date/Data); Linux biên dịch
// với FoundationEssentials. Ngữ nghĩa không đổi so với bản từng nằm trong UserLangModel.swift.
import Foundation

// MARK: - Bảng gọn

/// Bảng n-gram gọn: từ intern thành id (`words`/`ids`), count UInt32.
/// - uni: `uniC[id]` (0 = không có mục).
/// - bi: `biB[prev id]` = mảng (next id << 32 | count) sắp tăng theo next id — duyệt bucket cho
///   nextWords, tra một cặp bằng binary search.
/// - tri: `triIdx[(p2 << 32) | p1]` → slot; `triB[slot]` như bi. Slot rỗng giữ tới lần compact.
/// Giá trị (value type): snapshot để lưu nền chỉ tăng refcount (COW).
struct UserLMTables {
    /// Ngăn cách khoá trigram dạng dict "p2␁p1" (= UserLangModel.sep).
    static let sep = "\u{1}"
    var words: [String] = []
    var ids: [String: Int32] = [:]
    var uniC: [UInt32] = []
    var biB: [ContiguousArray<UInt64>] = []
    var triIdx: [UInt64: Int32] = [:]
    var triCtx: [UInt64] = []
    var triB: [ContiguousArray<UInt64>] = []
    private(set) var uniN = 0, biN = 0, triN = 0
    /// Σ uni — incremental, không reduce mỗi phím.
    private(set) var uniTotal = 0

    init() {}

    @inline(__always) static func pack(_ id: UInt32, _ c: UInt32) -> UInt64 { UInt64(id) << 32 | UInt64(c) }
    @inline(__always) static func nid(_ e: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: e >> 32) }
    @inline(__always) static func cnt(_ e: UInt64) -> Int { Int(UInt32(truncatingIfNeeded: e)) }
    @inline(__always) static func ctx(_ p2: Int32, _ p1: Int32) -> UInt64 {
        pack(UInt32(bitPattern: p2), UInt32(bitPattern: p1))
    }
    @inline(__always) static func clamp(_ c: Int) -> UInt32 { UInt32(clamping: c) }

    /// Vị trí của `id` trong bucket (hoặc chỗ chèn).
    @inline(__always) static func search(_ b: ContiguousArray<UInt64>, _ id: UInt32) -> (found: Bool, at: Int) {
        var lo = 0, hi = b.count
        while lo < hi {
            let m = (lo + hi) >> 1
            if nid(b[m]) < id { lo = m + 1 } else { hi = m }
        }
        return (lo < b.count && nid(b[lo]) == id, lo)
    }

    mutating func intern(_ w: String) -> Int32 {
        if let i = ids[w] { return i }
        let i = Int32(words.count)
        words.append(w); ids[w] = i; uniC.append(0); biB.append([])
        return i
    }

    @inline(__always) func uni(_ id: Int32) -> Int { Int(uniC[Int(id)]) }
    @inline(__always) func uni(_ w: String) -> Int {
        guard let i = ids[w] else { return 0 }
        return Int(uniC[Int(i)])
    }

    mutating func setUni(_ id: Int32, _ c: Int) {
        let old = uniC[Int(id)], v = Self.clamp(max(c, 0))
        if old == 0 && v > 0 { uniN += 1 } else if old > 0 && v == 0 { uniN -= 1 }
        uniTotal += Int(v) - Int(old)
        uniC[Int(id)] = v
    }

    func biCount(_ p: Int32, _ n: Int32) -> Int {
        let b = biB[Int(p)]
        let (f, at) = Self.search(b, UInt32(bitPattern: n))
        return f ? Self.cnt(b[at]) : 0
    }

    /// Cộng dồn; true nếu mục mới.
    @discardableResult
    private static func add(_ b: inout ContiguousArray<UInt64>, _ n: Int32, _ by: Int, set: Bool) -> Bool {
        let id = UInt32(bitPattern: n)
        let (f, at) = search(b, id)
        if f {
            b[at] = pack(id, clamp(set ? by : cnt(b[at]) + by))
            return false
        }
        b.insert(pack(id, clamp(by)), at: at)
        return true
    }

    /// Trừ; true nếu mục bị bỏ hẳn.
    private static func dec(_ b: inout ContiguousArray<UInt64>, _ n: Int32, _ by: Int) -> Bool {
        let id = UInt32(bitPattern: n)
        let (f, at) = search(b, id)
        guard f else { return false }
        let c = cnt(b[at])
        if c > by { b[at] = pack(id, clamp(c - by)); return false }
        b.remove(at: at)
        return true
    }

    mutating func addBi(_ p: Int32, _ n: Int32, _ by: Int) {
        if Self.add(&biB[Int(p)], n, by, set: false) { biN += 1 }
    }
    mutating func setBi(_ p: Int32, _ n: Int32, _ c: Int) {
        if Self.add(&biB[Int(p)], n, c, set: true) { biN += 1 }
    }
    mutating func decBi(_ p: Int32, _ n: Int32, _ by: Int) {
        if Self.dec(&biB[Int(p)], n, by) { biN -= 1 }
    }

    private mutating func triSlot(_ c: UInt64) -> Int {
        if let s = triIdx[c] { return Int(s) }
        let s = triB.count
        triIdx[c] = Int32(s); triCtx.append(c); triB.append([])
        return s
    }
    func triCount(_ slot: Int, _ n: Int32) -> Int {
        let b = triB[slot]
        let (f, at) = Self.search(b, UInt32(bitPattern: n))
        return f ? Self.cnt(b[at]) : 0
    }
    mutating func addTri(_ c: UInt64, _ n: Int32, _ by: Int) {
        let s = triSlot(c)
        if Self.add(&triB[s], n, by, set: false) { triN += 1 }
    }
    mutating func setTri(_ c: UInt64, _ n: Int32, _ v: Int) {
        let s = triSlot(c)
        if Self.add(&triB[s], n, v, set: true) { triN += 1 }
    }
    mutating func decTri(_ c: UInt64, _ n: Int32, _ by: Int) {
        guard let s = triIdx[c] else { return }
        if Self.dec(&triB[Int(s)], n, by) { triN -= 1 }
    }

    /// Bỏ `id` khỏi uni + mọi bi/tri có nó (trước hay sau). true nếu có gì bị xoá.
    mutating func removeWord(_ id: Int32) -> Bool {
        var changed = false
        if uniC[Int(id)] > 0 { setUni(id, 0); changed = true }
        if !biB[Int(id)].isEmpty { biN -= biB[Int(id)].count; biB[Int(id)] = []; changed = true }
        for p in biB.indices where Self.dec(&biB[p], id, Int.max) { biN -= 1; changed = true }
        let me = UInt32(bitPattern: id)
        for s in triB.indices where !triB[s].isEmpty {
            let c = triCtx[s]
            if Self.nid(c) == me || UInt32(truncatingIfNeeded: c) == me {
                triN -= triB[s].count; triB[s] = []; changed = true
            } else if Self.dec(&triB[s], id, Int.max) {
                triN -= 1; changed = true
            }
        }
        return changed
    }

    /// Áp `f` lên mọi count của các bảng được chọn; count ≤ 0 bị bỏ.
    mutating func mapCounts(uni: Bool, bi: Bool, tri: Bool, _ f: (Int) -> Int) {
        if uni {
            uniN = 0; uniTotal = 0
            for i in uniC.indices where uniC[i] > 0 {
                let v = Self.clamp(max(f(Int(uniC[i])), 0))
                uniC[i] = v
                if v > 0 { uniN += 1; uniTotal += Int(v) }
            }
        }
        func mapB(_ bs: inout [ContiguousArray<UInt64>]) -> Int {
            var n = 0
            for i in bs.indices where !bs[i].isEmpty {
                var out = ContiguousArray<UInt64>()
                out.reserveCapacity(bs[i].count)
                for e in bs[i] {
                    let v = f(Self.cnt(e))
                    if v > 0 { out.append(Self.pack(Self.nid(e), Self.clamp(v))) }
                }
                bs[i] = out; n += out.count
            }
            return n
        }
        if bi { biN = mapB(&biB) }
        if tri { triN = mapB(&triB) }
    }

    /// Bỏ từ mồ côi (không còn ở uni/bi/tri) + slot tri rỗng, cấp lại id liền nhau. Thứ tự id cũ
    /// được giữ ⇒ bucket vẫn sắp. Chỉ chạy lúc prune/decay/xoá từ (hiếm), O(tổng mục).
    mutating func compact() {
        var live = uniC.map { $0 > 0 }
        for p in biB.indices where !biB[p].isEmpty {
            live[p] = true
            for e in biB[p] { live[Int(Self.nid(e))] = true }
        }
        for s in triB.indices where !triB[s].isEmpty {
            live[Int(Self.nid(triCtx[s]))] = true
            live[Int(UInt32(truncatingIfNeeded: triCtx[s]))] = true
            for e in triB[s] { live[Int(Self.nid(e))] = true }
        }
        let liveTri = triB.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
        let nLive = live.reduce(0) { $0 + ($1 ? 1 : 0) }
        if nLive == words.count && liveTri == triB.count { return }
        var remap = [UInt32](repeating: .max, count: words.count)
        var nw: [String] = [], nu: [UInt32] = [], nb: [ContiguousArray<UInt64>] = []
        nw.reserveCapacity(nLive); nu.reserveCapacity(nLive); nb.reserveCapacity(nLive)
        var nids: [String: Int32] = [:]
        nids.reserveCapacity(nLive)
        for i in words.indices where live[i] {
            remap[i] = UInt32(nw.count)
            nids[words[i]] = Int32(nw.count)
            nw.append(words[i]); nu.append(uniC[i])
        }
        @inline(__always) func re(_ b: ContiguousArray<UInt64>) -> ContiguousArray<UInt64> {
            var o = ContiguousArray<UInt64>()
            o.reserveCapacity(b.count)
            for e in b { o.append(Self.pack(remap[Int(Self.nid(e))], UInt32(truncatingIfNeeded: e))) }
            return o
        }
        for i in words.indices where live[i] { nb.append(biB[i].isEmpty ? [] : re(biB[i])) }
        var tIdx: [UInt64: Int32] = [:], tCtx: [UInt64] = [], tB: [ContiguousArray<UInt64>] = []
        tIdx.reserveCapacity(liveTri); tCtx.reserveCapacity(liveTri); tB.reserveCapacity(liveTri)
        for s in triB.indices where !triB[s].isEmpty {
            let c = Self.pack(remap[Int(Self.nid(triCtx[s]))], remap[Int(UInt32(truncatingIfNeeded: triCtx[s]))])
            tIdx[c] = Int32(tCtx.count); tCtx.append(c); tB.append(re(triB[s]))
        }
        words = nw; ids = nids; uniC = nu; biB = nb
        triIdx = tIdx; triCtx = tCtx; triB = tB
    }

    // MARK: ranh giới dict (bản cũ / sao lưu)

    /// Dựng từ dict kiểu cũ. Count ≤ 0 bị bỏ; khoá tri phải đúng dạng "p2␁p1".
    init(uni: [String: Int], bi: [String: [String: Int]], tri: [String: [String: Int]]) {
        for (w, c) in uni where c > 0 { setUni(intern(w), c) }
        for (p, inner) in bi {
            for (n, c) in inner where c > 0 { setBi(intern(p), intern(n), c) }
        }
        for (k, inner) in tri {
            let parts = k.split(separator: Character(UserLMTables.sep), omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            for (n, c) in inner where c > 0 {
                setTri(Self.ctx(intern(String(parts[0])), intern(String(parts[1]))), intern(n), c)
            }
        }
    }

    func uniDict() -> [String: Int] {
        var d: [String: Int] = [:]
        d.reserveCapacity(uniN)
        for (i, c) in uniC.enumerated() where c > 0 { d[words[i]] = Int(c) }
        return d
    }

    private func nested(_ b: ContiguousArray<UInt64>) -> [String: Int] {
        var inner: [String: Int] = [:]
        inner.reserveCapacity(b.count)
        for e in b { inner[words[Int(Self.nid(e))]] = Self.cnt(e) }
        return inner
    }

    func biDict() -> [String: [String: Int]] {
        var d: [String: [String: Int]] = [:]
        for (p, b) in biB.enumerated() where !b.isEmpty { d[words[p]] = nested(b) }
        return d
    }

    func triDict() -> [String: [String: Int]] {
        var d: [String: [String: Int]] = [:]
        for (s, b) in triB.enumerated() where !b.isEmpty {
            let c = triCtx[s]
            d[words[Int(Self.nid(c))] + UserLMTables.sep + words[Int(UInt32(truncatingIfNeeded: c))]] = nested(b)
        }
        return d
    }

    /// Dựng thẳng từ file đã kiểm (UserLMCodec) — bucket đã sắp, không trùng.
    fileprivate init(words: [String], ids: [String: Int32], uniC: [UInt32], biB: [ContiguousArray<UInt64>],
                     triCtx: [UInt64], triB: [ContiguousArray<UInt64>]) {
        self.words = words; self.ids = ids; self.uniC = uniC; self.biB = biB
        self.triCtx = triCtx; self.triB = triB
        triIdx.reserveCapacity(triCtx.count)
        for (s, c) in triCtx.enumerated() { triIdx[c] = Int32(s) }
        for c in uniC where c > 0 { uniN += 1; uniTotal += Int(c) }
        biN = biB.reduce(0) { $0 + $1.count }
        triN = triB.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Định dạng file VTL2 (chung iOS/Android — android/.../UserLangModel.kt)

/// Little-endian:
/// ```
/// "VTL2" | u16 version=1 | u16 flags=0 | i64 lastDecay (ms từ 1970)
/// u32 nWords | nWords × (u16 len, UTF-8)          — id = thứ tự
/// nWords × u32 uniCount                            — 0 = không có unigram
/// u32 nBi  | nBi  × (u32 prev, u32 n, n × (u32 next, u32 count))
/// u32 nTri | nTri × (u32 p2, u32 p1, u32 n, n × (u32 next, u32 count))
/// u32 nManual | nManual × (u16 len, UTF-8)        — dạng hiển thị
/// u32 CRC32 (IEEE, như zlib) của mọi byte phía trước
/// ```
/// Đọc: sai magic/version/CRC, id ngoài tầm, count 0, bucket không tăng dần, từ/ngữ cảnh trùng ⇒ nil.
enum UserLMCodec {
    static let magic: [UInt8] = Array("VTL2".utf8)
    static let version: UInt16 = 1

    static func encode(_ t: UserLMTables, lastDecay: Date, manual: [String]) -> Data {
        // Tính đúng cỡ trước, ghi thẳng vào một bộ đệm (không append từng byte).
        func slen(_ s: String) -> Int { min(s.utf8.count, Int(UInt16.max)) }
        var size = 16 + 4 + 4 * t.words.count + 4 + 4 + 4 + 4
        for w in t.words { size += 2 + slen(w) }
        for b in t.biB where !b.isEmpty { size += 8 + 8 * b.count }
        for b in t.triB where !b.isEmpty { size += 12 + 8 * b.count }
        for m in manual { size += 2 + slen(m) }
        var o = [UInt8](repeating: 0, count: size)
        o.withUnsafeMutableBytes { raw in
            var pos = 0
            @inline(__always) func u16(_ v: UInt16) { raw.storeBytes(of: v.littleEndian, toByteOffset: pos, as: UInt16.self); pos += 2 }
            @inline(__always) func u32(_ v: UInt32) { raw.storeBytes(of: v.littleEndian, toByteOffset: pos, as: UInt32.self); pos += 4 }
            func str(_ s: String) {
                let n = slen(s)
                u16(UInt16(n))
                var i = 0
                for c in s.utf8 { if i == n { break }; raw[pos + i] = c; i += 1 }
                pos += n
            }
            for c in magic { raw[pos] = c; pos += 1 }
            u16(version); u16(0)
            let ms = UInt64(bitPattern: Int64((lastDecay.timeIntervalSince1970 * 1000).rounded()))
            u32(UInt32(truncatingIfNeeded: ms)); u32(UInt32(truncatingIfNeeded: ms >> 32))
            u32(UInt32(t.words.count))
            for w in t.words { str(w) }
            for c in t.uniC { u32(c) }
            func bucket(_ b: ContiguousArray<UInt64>) {
                u32(UInt32(b.count))
                for e in b { u32(UserLMTables.nid(e)); u32(UInt32(truncatingIfNeeded: e)) }
            }
            u32(UInt32(t.biB.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }))
            for (p, b) in t.biB.enumerated() where !b.isEmpty { u32(UInt32(p)); bucket(b) }
            u32(UInt32(t.triB.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }))
            for (s, b) in t.triB.enumerated() where !b.isEmpty {
                u32(UserLMTables.nid(t.triCtx[s])); u32(UInt32(truncatingIfNeeded: t.triCtx[s])); bucket(b)
            }
            u32(UInt32(manual.count))
            for m in manual { str(m) }
            u32(crc32(UnsafeRawBufferPointer(rebasing: raw[0..<pos])))
        }
        return Data(o)
    }

    struct Decoded { let tables: UserLMTables; let lastDecay: Date; let manual: [String] }

    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count >= 36,   // tệp rỗng: đầu 16 + 4 số đếm + CRC
              Array(bytes[0..<4]) == magic else { return nil }
        let body = bytes.count - 4
        var pos = 4
        func u16() -> UInt16? {
            guard pos + 2 <= body else { return nil }
            defer { pos += 2 }
            return UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
        }
        func u32() -> UInt32? {
            guard pos + 4 <= body else { return nil }
            defer { pos += 4 }
            return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
        }
        func str() -> String? {
            guard let n = u16(), pos + Int(n) <= body else { return nil }
            defer { pos += Int(n) }
            return String(decoding: bytes[pos..<pos + Int(n)], as: UTF8.self)
        }
        let stored = UInt32(bytes[body]) | UInt32(bytes[body + 1]) << 8 | UInt32(bytes[body + 2]) << 16 | UInt32(bytes[body + 3]) << 24
        guard crc32(bytes[0..<body]) == stored else { return nil }
        guard u16() == version, u16() != nil, let lo = u32(), let hi = u32() else { return nil }
        let ms = Int64(bitPattern: UInt64(hi) << 32 | UInt64(lo))
        guard let nw32 = u32(), Int(nw32) <= body / 2 else { return nil }
        let nw = Int(nw32)
        var words: [String] = [], ids: [String: Int32] = [:]
        words.reserveCapacity(nw); ids.reserveCapacity(nw)
        for i in 0..<nw {
            guard let w = str(), ids.updateValue(Int32(i), forKey: w) == nil else { return nil }
            words.append(w)
        }
        var uniC = [UInt32](); uniC.reserveCapacity(nw)
        for _ in 0..<nw { guard let c = u32() else { return nil }; uniC.append(c) }
        func bucket() -> ContiguousArray<UInt64>? {
            guard let n = u32(), n > 0, Int(n) <= (body - pos) / 8 else { return nil }
            var b = ContiguousArray<UInt64>(); b.reserveCapacity(Int(n))
            var last: UInt32?
            for _ in 0..<n {
                guard let id = u32(), let c = u32(), Int(id) < nw, c > 0 else { return nil }
                if let l = last, id <= l { return nil }
                last = id
                b.append(UserLMTables.pack(id, c))
            }
            return b
        }
        var biB = [ContiguousArray<UInt64>](repeating: [], count: nw)
        guard let nb = u32() else { return nil }
        for _ in 0..<nb {
            guard let p = u32(), Int(p) < nw, biB[Int(p)].isEmpty, let b = bucket() else { return nil }
            biB[Int(p)] = b
        }
        guard let nt = u32(), Int(nt) <= body / 12 else { return nil }
        var triCtx: [UInt64] = [], triB: [ContiguousArray<UInt64>] = [], seen = Set<UInt64>()
        for _ in 0..<nt {
            guard let a = u32(), let b = u32(), Int(a) < nw, Int(b) < nw, let bk = bucket() else { return nil }
            let c = UserLMTables.pack(a, b)
            guard seen.insert(c).inserted else { return nil }
            triCtx.append(c); triB.append(bk)
        }
        guard let nm = u32(), Int(nm) <= body / 2 else { return nil }
        var manual: [String] = []
        for _ in 0..<nm { guard let m = str() else { return nil }; manual.append(m) }
        guard pos == body else { return nil }
        let t = UserLMTables(words: words, ids: ids, uniC: uniC, biB: biB, triCtx: triCtx, triB: triB)
        return Decoded(tables: t, lastDecay: Date(timeIntervalSince1970: Double(ms) / 1000), manual: manual)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { tb in
            for b in bytes { c = tb[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
