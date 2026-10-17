// SyllableLM.swift — MÔ HÌNH NGÔN NGỮ ÂM TIẾT TRIGRAM tĩnh cho gõ vuốt (Resources/vnlm.bin,
// GENERATED bởi Scripts/gen-syllable-lm.py — nguồn/giấy phép: docs/DATA-SOURCES.md). Song
// sinh android/keyboard/src/main/kotlin/com/viettelex/keyboard/SyllableLM.kt — sửa hành vi
// ở đây thì sửa y hệt bên kia (fixture parity KeyboardTests/Fixtures/vnlm-parity.txt).
//
// Kneser-Ney nội suy bậc 3 đã cắt tỉa. Điểm s (nat) của âm tiết c sau (a, b) =
// ln(P(c|a,b) / P1(c)): > 0 = hay theo sau hơn bình thường, < 0 = hiếm. Thiếu mục ⇒ lùi:
// dòng trigram (a,b) có mà thiếu c → γ3(ab) + s2(b,c); không có dòng → s2(b,c); bigram
// thiếu → γ2(b).
//
// Cũng là nguồn BIGRAM của thanh gợi ý gõ chạm + Thêm dấu (thay vnbigram.bin cũ): `bigram`
// trả PMI ≈ ln(P(c|b) / P(c)) = s2(b, c) + uniAdj(c), uniAdj = ln(P1(c)·N / c(c)) đổi mẫu số
// từ P1 (continuation) sang tần suất thật.
//
// Định dạng v3 (LE; đặc tả đầy đủ ở docstring script + docs/DATA-SOURCES.md): header 128 byte
// (0 "VNM1" | 4 version=3 | 8 count | 12 lexHash | 16 qPerNat | 20 biEntries | 24 triContexts |
// 28 triEntries | 32 triL, 8, bits3, bitsG3, biSel, triSel (u8) | 40 payloadHash |
// 48 offset u32 ×19 của 18 phần + kết thúc). Bigram: Elias–Fano THEO DÒNG (dòng b: id c tăng
// dần, L_b = ⌊log2(count/n_b)⌋; biRow/biZero/biLowOff = chỉ số mục / số bit 0 / bit low đầu
// dòng; bit high cả bảng nối liền, mẫu select0 mỗi 2^biSel số 0). Trigram: một dãy EF toàn cục
// khoá k·count + c (k = số thứ tự ngữ cảnh = rank cờ hasTri của mục bigram (a, b)). Điểm (bội
// 1/16 nat): bigram i8 thô (đã lượng tử 64 mức); trigram / γ3 = mã bits3 / bitsG3 bit tra
// codebook i8.
//
// mmap (.alwaysMapped), đọc tại chỗ, không giải mã vào heap: RAM bẩn ≈ 0. Chỉ đọc ⇒ thread-safe.
import Foundation

final class SyllableLM {
    let count: Int
    let biEntries: Int
    let triContexts: Int
    let triEntries: Int
    private let blob: Data
    private let qPerNat: Float
    private let bits3: Int, bitsG: Int
    private let g2Base: Int, adjBase: Int, cb3Base: Int, cbgBase: Int
    private let biRow: Int, biZero: Int, biLowOff: Int, biLow: Int
    private let biScore: Int, hasTri: Int, triRank: Int, g3Base: Int, triScore: Int
    /// bi: chỉ dùng high/sel/words/selShift (low theo dòng); tri: đủ.
    private let bi: EF, tri: EF
    let byteCount: Int

    static let version = 3
    static let headerSize = 128
    private static let sectionCount = 18
    /// Dòng ngắn hơn ⇒ quét tuần tự thay vì select0.
    private static let shortRow = 8
    /// Dòng trigram dài hơn ⇒ `Context.explicitAll` tìm từng id thay vì duyệt cả dòng.
    fileprivate static let longTriRow = 48

    /// Một dãy khoá tăng ngặt mã hoá Elias–Fano (đọc tại chỗ).
    fileprivate struct EF {
        let n: Int, l: Int, low: Int, high: Int, sel: Int, words: Int, selShift: Int
        var mask: Int { (1 &<< l) &- 1 }
    }

    private init(blob: Data, off: [Int]) {
        self.blob = blob
        count = Self.u32(blob, 8)
        qPerNat = Float(Self.u32(blob, 16))
        biEntries = Self.u32(blob, 20)
        triContexts = Self.u32(blob, 24)
        triEntries = Self.u32(blob, 28)
        let b = { (i: Int) in Int(blob[blob.startIndex + i]) }
        bits3 = b(34); bitsG = b(35)
        g2Base = off[0]; adjBase = off[1]; cb3Base = off[2]; cbgBase = off[3]
        biRow = off[4]; biZero = off[5]; biLowOff = off[6]; biLow = off[7]
        bi = EF(n: biEntries, l: 0, low: off[7], high: off[8], sel: off[9], words: (off[9] - off[8]) / 8,
                selShift: b(36))
        biScore = off[10]; hasTri = off[11]; triRank = off[12]; g3Base = off[13]
        tri = EF(n: triEntries, l: b(32), low: off[14], high: off[15], sel: off[16],
                 words: (off[16] - off[15]) / 8, selShift: b(37))
        triScore = off[17]
        byteCount = off[18]
    }

    private static func u32(_ d: Data, _ off: Int) -> Int {
        Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
    }

    // MARK: bit thô

    @inline(__always) private static func u64(_ raw: UnsafeRawBufferPointer, _ base: Int, _ wi: Int) -> UInt64 {
        UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + wi << 3, as: UInt64.self))
    }

    @inline(__always) private static func u32(_ raw: UnsafeRawBufferPointer, _ base: Int, _ i: Int) -> Int {
        Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + i << 2, as: UInt32.self)))
    }

    /// `width` (≤ 32) bit tại vị trí bit `pos` của mảng bắt đầu ở `base`.
    @inline(__always) private static func bits(_ raw: UnsafeRawBufferPointer, _ base: Int, _ pos: Int, _ width: Int) -> Int {
        let wi = pos >> 6, sh = pos & 63
        var v = u64(raw, base, wi) &>> UInt64(sh)
        if sh + width > 64 { v |= u64(raw, base, wi + 1) &<< UInt64(64 - sh) }
        return Int(v & ((1 &<< UInt64(width)) &- 1))
    }

    @inline(__always) private static func bit(_ raw: UnsafeRawBufferPointer, _ base: Int, _ p: Int) -> Bool {
        (raw[base + p >> 3] &>> UInt8(p & 7)) & 1 != 0
    }

    /// Phần thấp của phần tử m (trigram).
    @inline(__always) private static func low(_ raw: UnsafeRawBufferPointer, _ e: EF, _ m: Int) -> Int {
        bits(raw, e.low, m * e.l, e.l)
    }

    /// ⌊log2(u/n)⌋ (0 nếu n = 0 hoặc u < n) — số bit thấp EF.
    @inline(__always) private static func efL(_ n: Int, _ u: Int) -> Int {
        n > 0 && u >= n ? Int.bitWidth - 1 - (u / n).leadingZeroBitCount : 0
    }

    /// Giá trị codebook (i8, đơn vị 1/16 nat) của mã thứ i (w bit) trong mảng `base`.
    @inline(__always) private func cbValue(_ raw: UnsafeRawBufferPointer, _ cb: Int, _ base: Int, _ i: Int, _ w: Int) -> Int {
        Int(Int8(bitPattern: raw[cb + Self.bits(raw, base, i * w, w)]))
    }

    @inline(__always) private func q(_ v: Int) -> Float { Float(v) / qPerNat }

    // MARK: Elias–Fano

    /// Vị trí bit 1 thứ `r` (từ 0) trong từ `w` (đủ bit 1).
    /// Broadword (Vigna): tổng dồn popcount từng byte bằng một phép nhân, tìm byte chứa bit
    /// thứ r không rẽ nhánh, rồi ≤ 7 bước trong byte.
    @inline(__always) private static func selectInWord(_ x: UInt64, _ r: Int) -> Int {
        var s = x &- ((x &>> 1) & 0x5555_5555_5555_5555)
        s = (s & 0x3333_3333_3333_3333) &+ ((s &>> 2) & 0x3333_3333_3333_3333)
        s = (s &+ (s &>> 4)) & 0x0F0F_0F0F_0F0F_0F0F
        let sums = s &* 0x0101_0101_0101_0101                     // byte i = số bit 1 của byte 0...i
        let le = ((UInt64(r) &* 0x0101_0101_0101_0101 | 0x8080_8080_8080_8080) &- sums) & 0x8080_8080_8080_8080
        let place = (~le & 0x8080_8080_8080_8080).trailingZeroBitCount - 7    // byte đầu có tổng > r
        let k = r - Int(((sums &<< 8) &>> UInt64(place)) & 0xFF)
        return place + Int(selectInByte[Int((x &>> UInt64(place)) & 0xFF) << 3 | k])
    }

    /// selectInByte[b·8 + k] = vị trí bit 1 thứ k của byte b (2 KB, dựng một lần).
    private static let selectInByte: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 2048)
        for b in 0..<256 {
            var x = b, k = 0
            while x != 0 { t[b << 3 | k] = UInt8(x.trailingZeroBitCount); x &= x - 1; k += 1 }
        }
        return t
    }()

    /// Vị trí số 0 thứ `r` (từ 0) trong mảng high.
    private static func select0(_ raw: UnsafeRawBufferPointer, _ e: EF, _ r: Int) -> Int {
        let t = r &>> e.selShift
        let p = u32(raw, e.sel, t)
        var k = r - t &<< e.selShift
        if k == 0 { return p }
        var wi = (p + 1) >> 6
        if wi >= e.words { return e.words << 6 }                  // file hỏng: không đọc tràn
        var w = ~u64(raw, e.high, wi) & (~0 &<< UInt64((p + 1) & 63))
        while true {
            let c = w.nonzeroBitCount
            if c >= k { break }
            k -= c; wi += 1
            if wi >= e.words { return e.words << 6 }       // file hỏng: không đọc tràn
            w = ~u64(raw, e.high, wi)
        }
        return wi << 6 + selectInWord(w, k - 1)
    }

    /// (vị trí bit, chỉ số) của phần tử đầu tiên có phần cao ≥ h.
    @inline(__always) private static func bucket(_ raw: UnsafeRawBufferPointer, _ e: EF, _ h: Int) -> (Int, Int) {
        if h == 0 { return (0, 0) }
        let z = select0(raw, e, h - 1)
        return (z + 1, z + 1 - h)
    }

    /// Số bit 1 liên tiếp từ `pos` (= cỡ phần còn lại của xô).
    @inline(__always) private static func runLength(_ raw: UnsafeRawBufferPointer, _ e: EF, _ pos: Int) -> Int {
        var wi = pos >> 6, sh = pos & 63, n = 0
        while wi < e.words {
            let ones = (~(u64(raw, e.high, wi) &>> UInt64(sh))).trailingZeroBitCount
            if ones < 64 - sh { return n + ones }
            n += 64 - sh; wi += 1; sh = 0
        }
        return n
    }

    /// Chỉ số của khoá `x`, -1 nếu không có (select0 + tìm nhị phân trong xô).
    private static func find(_ raw: UnsafeRawBufferPointer, _ e: EF, _ x: Int) -> Int {
        let (pos, idx) = bucket(raw, e, x &>> e.l)
        let t = x & e.mask
        var lo = idx, hi = idx + runLength(raw, e, pos)
        while lo < hi {
            let m = (lo + hi) >> 1
            let v = low(raw, e, m)
            if v < t { lo = m + 1 } else if v > t { hi = m } else { return m }
        }
        return -1
    }

    /// (chỉ số, vị trí bit để duyệt tiếp) của khoá đầu tiên ≥ x.
    private static func lowerBound(_ raw: UnsafeRawBufferPointer, _ e: EF, _ x: Int) -> (Int, Int) {
        let (pos, idx) = bucket(raw, e, x &>> e.l)
        let t = x & e.mask
        var lo = idx, hi = idx + runLength(raw, e, pos)
        while lo < hi {
            let m = (lo + hi) >> 1
            if low(raw, e, m) < t { lo = m + 1 } else { hi = m }
        }
        return (lo, pos + lo - idx)
    }

    /// Tìm khoá `x` bằng quét tuần tự từ phần tử `lo` (bit high ở `pos`, không có phần tử nào
    /// giữa `pos` và nó) tối đa `shortRow` phần tử; quá thì `find`. Dòng ngắn khỏi select0.
    @inline(__always) private static func scanFind(_ raw: UnsafeRawBufferPointer, _ e: EF, _ lo: Int, _ pos: Int,
                                                   _ x: Int) -> Int {
        var wi = pos >> 6
        var w = u64(raw, e.high, wi) & (~0 &<< UInt64(pos & 63))
        var m = lo
        let end = min(e.n, lo + shortRow)
        while m < end {
            while w == 0 { wi += 1; if wi >= e.words { return -1 }; w = u64(raw, e.high, wi) }
            let k = (wi << 6 + w.trailingZeroBitCount - m) &<< e.l | low(raw, e, m)
            if k >= x { return k == x ? m : -1 }
            w &= w &- 1; m += 1
        }
        return m < e.n ? find(raw, e, x) : -1
    }

    /// Duyệt tuần tự `n` phần tử từ `lo` (bit high từ `pos`): body(chỉ số, khoá).
    @inline(__always) private static func scan(_ raw: UnsafeRawBufferPointer, _ e: EF, _ lo: Int, _ pos: Int, _ n: Int,
                                               _ body: (_ idx: Int, _ key: Int) -> Void) {
        guard n > 0 else { return }
        var wi = pos >> 6
        var w = u64(raw, e.high, wi) & (~0 &<< UInt64(pos & 63))
        for m in lo..<lo + n {
            while w == 0 { wi += 1; if wi >= e.words { return }; w = u64(raw, e.high, wi) }
            body(m, (wi << 6 + w.trailingZeroBitCount - m) &<< e.l | low(raw, e, m))
            w &= w &- 1
        }
    }

    /// Một dòng bigram (EF riêng): chỉ số [lo, hi), L bit thấp, số bit 0 trước dòng `zero`
    /// (bit high đầu dòng = lo + zero), bit low đầu dòng `lowOff`.
    fileprivate struct BiRow {
        let lo: Int, hi: Int, l: Int, zero: Int, lowOff: Int
        var start: Int { lo + zero }
        static let empty = BiRow(lo: 0, hi: 0, l: 0, zero: 0, lowOff: 0)
    }

    @inline(__always) private func biRowAt(_ raw: UnsafeRawBufferPointer, _ b: Int) -> BiRow {
        let lo = Self.u32(raw, biRow, b), hi = Self.u32(raw, biRow, b + 1)
        return BiRow(lo: lo, hi: hi, l: Self.efL(hi - lo, count), zero: Self.u32(raw, biZero, b),
                     lowOff: Self.u32(raw, biLowOff, b))
    }

    @inline(__always) private func biLowAt(_ raw: UnsafeRawBufferPointer, _ r: BiRow, _ m: Int) -> Int {
        Self.bits(raw, biLow, r.lowOff + (m - r.lo) * r.l, r.l)
    }

    /// Duyệt tuần tự dòng bigram: body(chỉ số mục, id âm tiết sau).
    @inline(__always) private func biScan(_ raw: UnsafeRawBufferPointer, _ r: BiRow,
                                          _ body: (_ idx: Int, _ c: Int) -> Void) {
        guard r.lo < r.hi else { return }
        let start = r.start
        var wi = start >> 6
        var w = Self.u64(raw, bi.high, wi) & (~0 &<< UInt64(start & 63))
        // bit thấp đọc tuần tự: đệm 64 bit `lb` còn `la` bit
        let l = r.l, mask: UInt64 = (1 &<< UInt64(l)) &- 1
        var li = r.lowOff >> 6
        var lb = Self.u64(raw, biLow, li) &>> UInt64(r.lowOff & 63), la = 64 - r.lowOff & 63
        for m in r.lo..<r.hi {
            while w == 0 { wi += 1; if wi >= bi.words { return }; w = Self.u64(raw, bi.high, wi) }
            var v: UInt64
            if la >= l { v = lb & mask; lb = lb &>> UInt64(l); la -= l } else {
                li += 1
                let nx = Self.u64(raw, biLow, li)
                v = (lb | nx &<< UInt64(la)) & mask
                lb = nx &>> UInt64(l - la); la += 64 - l
            }
            body(m, (wi << 6 + w.trailingZeroBitCount - start - (m - r.lo)) &<< l | Int(v))
            w &= w &- 1
        }
    }

    /// Chỉ số mục (b, c) trong dòng `r`, -1 nếu không có. Dòng ngắn: quét tuần tự; dài:
    /// select0(zero + h − 1) mở xô h = c >> L rồi tìm nhị phân phần thấp trong xô.
    private func biFind(_ raw: UnsafeRawBufferPointer, _ r: BiRow, _ c: Int) -> Int {
        let n = r.hi - r.lo
        if n == 0 { return -1 }
        if n <= Self.shortRow {
            let start = r.start
            var wi = start >> 6
            var w = Self.u64(raw, bi.high, wi) & (~0 &<< UInt64(start & 63))
            for m in r.lo..<r.hi {
                while w == 0 { wi += 1; if wi >= bi.words { return -1 }; w = Self.u64(raw, bi.high, wi) }
                let k = (wi << 6 + w.trailingZeroBitCount - start - (m - r.lo)) &<< r.l | biLowAt(raw, r, m)
                if k >= c { return k == c ? m : -1 }
                w &= w &- 1
            }
            return -1
        }
        let h = c &>> r.l, t = c & ((1 &<< r.l) &- 1)
        var pos = r.start, idx = r.lo
        if h > 0 {
            let z = r.zero + h - 1
            pos = Self.select0(raw, bi, z) + 1
            idx = pos - z - 1
        }
        // xô thường 0–2 phần tử (L theo dòng ⇒ bit 1 ≈ bit 0): quét tuần tự các bit 1 liền nhau
        guard pos >> 6 < bi.words else { return -1 }
        var w = Self.u64(raw, bi.high, pos >> 6) &>> UInt64(pos & 63)
        while w & 1 != 0 {
            let v = biLowAt(raw, r, idx)
            if v >= t { return v == t ? idx : -1 }
            pos += 1; idx += 1
            if pos & 63 == 0 { if pos >> 6 >= bi.words { return -1 }; w = Self.u64(raw, bi.high, pos >> 6) } else { w &>>= 1 }
        }
        return -1
    }

    /// Số thứ tự ngữ cảnh trigram của mục bigram j (rank cờ hasTri), -1 nếu không có dòng.
    private func context(_ raw: UnsafeRawBufferPointer, bigramIndex j: Int) -> Int {
        guard Self.bit(raw, hasTri, j) else { return -1 }
        return Self.u32(raw, triRank, j >> 6)
            + (Self.u64(raw, hasTri, j >> 6) & ((1 &<< UInt64(j & 63)) &- 1)).nonzeroBitCount
    }

    @inline(__always) private func biScoreAt(_ raw: UnsafeRawBufferPointer, _ j: Int) -> Float {
        q(Int(Int8(bitPattern: raw[biScore + j])))
    }

    @inline(__always) private func adj(_ raw: UnsafeRawBufferPointer, _ w: Int) -> Float {
        q(Int(Int8(bitPattern: raw[adjBase + w])))
    }

    // MARK: API

    /// Ngữ cảnh đã tra sẵn cho một vị trí (1–2 âm tiết trước): dòng trigram (prev2, prev1)
    /// định vị một lần; mỗi `score` chỉ còn tìm trong dòng + tìm bigram.
    struct Context {
        fileprivate let lm: SyllableLM
        fileprivate let g2: Float
        fileprivate let bi: BiRow
        /// Khoá đầu dòng trigram (k·count); < 0 ⇒ không có dòng trigram cho (prev2, prev1).
        fileprivate let triBase: Int
        fileprivate let triLo: Int, triPos: Int
        fileprivate let g3: Float

        /// s (nat) của âm tiết id `w`.
        func score(_ w: Int) -> Float {
            guard w >= 0, w < lm.count else { return 0 }
            return lm.blob.withUnsafeBytes { raw -> Float in
                if triBase >= 0 {
                    let t = SyllableLM.scanFind(raw, lm.tri, triLo, triPos, triBase + w)
                    if t >= 0 { return lm.q(lm.cbValue(raw, lm.cb3Base, lm.triScore, t, lm.bits3)) }
                }
                let j = lm.biFind(raw, bi, w)
                let s2 = j >= 0 ? lm.biScoreAt(raw, j) : g2
                return triBase >= 0 ? g3 + s2 : s2
            }
        }

        /// Có dòng trigram cho (prev2, prev1) không.
        var hasTrigram: Bool { triBase >= 0 }

        /// Số mục dòng bigram prev1 (0 ⇒ không biết gì về prev1 — như `Bigram.size`).
        var bigramSize: Int { bi.hi - bi.lo }

        /// PMI của mục TƯỜNG MINH (thanh gợi ý chấm ứng viên đang gõ): có mục trigram → s3 + uniAdj;
        /// không thì mục bigram → s2 + uniAdj (không cộng γ3 — đo trên dev: cộng γ3 kém hơn);
        /// thiếu cả hai → 0. Không dòng trigram ⇒ = `Bigram.explicit`.
        func explicit(_ w: Int) -> Float {
            guard w >= 0, w < lm.count else { return 0 }
            return lm.blob.withUnsafeBytes { raw -> Float in
                if triBase >= 0 {
                    let t = SyllableLM.scanFind(raw, lm.tri, triLo, triPos, triBase + w)
                    if t >= 0 { return lm.q(lm.cbValue(raw, lm.cb3Base, lm.triScore, t, lm.bits3)) + lm.adj(raw, w) }
                }
                let j = lm.biFind(raw, bi, w)
                return j >= 0 ? lm.biScoreAt(raw, j) + lm.adj(raw, w) : 0
            }
        }

        /// `explicit` cho nhiều id một lượt (pool ứng viên đang gõ; id < 0 ⇒ 0): xếp id tăng dần
        /// (chèn, pool ≤ 24) rồi đi song song với dòng trigram — mỗi mục dòng đọc MỘT lần, dừng ở
        /// id lớn nhất (dòng trung vị 1 mục); dòng dài quá `longTriRow` mục thì phần còn lại tìm
        /// từng id.
        func explicitAll(_ ids: [Int]) -> [Float] {
            let n = ids.count
            if n > 64 { return ids.map { explicit($0) } }       // khoá gói chỉ số 6 bit
            var out = [Float](repeating: 0, count: n)
            guard n > 0 else { return out }
            let count = lm.count
            // khoá id·64 + chỉ số (pool ≤ 64), id không hợp lệ ⇒ bỏ
            var ord = [Int](repeating: 0, count: n)
            var k = 0
            lm.blob.withUnsafeBytes { raw in
                var i = 0
                while i < n {
                    let w = ids[i]
                    if w >= 0 && w < count {
                        let j = lm.biFind(raw, bi, w)
                        if j >= 0 { out[i] = lm.biScoreAt(raw, j) + lm.adj(raw, w) }
                        let key = w &<< 6 | i
                        var p = k
                        while p > 0 && ord[p - 1] > key { ord[p] = ord[p - 1]; p -= 1 }
                        ord[p] = key; k += 1
                    }
                    i += 1
                }
                guard triBase >= 0, k > 0 else { return }
                var t = lm.triStart(raw, lo: triLo, pos: triPos, base: triBase)
                var q = 0, steps = 0
                while q < k && t.c != Int.max {
                    let w = ord[q] &>> 6
                    if t.c < w {
                        steps += 1
                        if steps > SyllableLM.longTriRow {
                            while q < k {
                                let w2 = ord[q] &>> 6
                                let m = SyllableLM.find(raw, lm.tri, triBase + w2)
                                if m >= 0 { out[ord[q] & 63] = lm.q(lm.cbValue(raw, lm.cb3Base, lm.triScore, m, lm.bits3)) + lm.adj(raw, w2) }
                                q += 1
                            }
                            return
                        }
                        lm.triNext(raw, &t)
                    } else {
                        if t.c == w { out[ord[q] & 63] = t.v + lm.adj(raw, w) }
                        q += 1
                    }
                }
            }
            return out
        }

        /// Duyệt CHỈ các mục trigram tường minh của (prev2, prev1) theo id tăng dần: body(id, pmi),
        /// pmi = s3 + uniAdj. Trả số mục (0 nếu không có dòng trigram).
        @discardableResult
        func forEachTrigram(_ body: (_ next: Int, _ pmi: Float) -> Void) -> Int {
            guard triBase >= 0 else { return 0 }
            return lm.blob.withUnsafeBytes { raw -> Int in
                var t = lm.triStart(raw, lo: triLo, pos: triPos, base: triBase)
                var n = 0
                while t.c != Int.max { body(t.c, t.v + lm.adj(raw, t.c)); n += 1; lm.triNext(raw, &t) }
                return n
            }
        }

        /// Duyệt mọi âm tiết sau có mục TƯỜNG MINH — dòng bigram prev1 ∪ dòng trigram (prev2, prev1)
        /// — theo id tăng dần: body(id, pmi), pmi = `score` + uniAdj ≈ ln(P(c | prev2, prev1) / P(c))
        /// (mục chỉ có ở bigram lùi γ3 + s2 như `score`). Không dòng trigram ⇒ y hệt
        /// `Bigram.forEach`. Trộn hai dãy tăng dần tại chỗ (dòng trigram duyệt tuần tự, không
        /// select0 lại), không cấp phát. Song sinh Kotlin `Context.forEachNext`.
        func forEachNext(_ body: (_ next: Int, _ pmi: Float) -> Void) {
            lm.blob.withUnsafeBytes { raw in
                var t = triBase >= 0 ? lm.triStart(raw, lo: triLo, pos: triPos, base: triBase)
                    : TriCursor(m: 0, base: 0, end: 0)
                let back: Float = triBase >= 0 ? g3 : 0
                lm.biScan(raw, bi) { m, c in
                    while t.c < c { body(t.c, t.v + lm.adj(raw, t.c)); lm.triNext(raw, &t) }
                    if t.c == c { body(c, t.v + lm.adj(raw, c)); lm.triNext(raw, &t) }
                    else { body(c, back + lm.biScoreAt(raw, m) + lm.adj(raw, c)) }
                }
                while t.c != Int.max { body(t.c, t.v + lm.adj(raw, t.c)); lm.triNext(raw, &t) }
            }
        }
    }

    /// Con trỏ duyệt tuần tự một dòng trigram (khoá `base` ≤ k < `end`): phần tử `m`, từ bit high
    /// `wi`/`w`; `c` = id âm tiết kế (Int.max = hết dòng), `v` = s3 của nó.
    fileprivate struct TriCursor {
        var m: Int
        let base: Int, end: Int
        var wi = 0, w: UInt64 = 0
        var c = Int.max
        var v: Float = 0
        init(m: Int, base: Int, end: Int) { self.m = m; self.base = base; self.end = end }
    }

    /// Dòng trigram có khoá đầu `base` (phần tử `lo`, bit high `pos` — từ lowerBound).
    fileprivate func triStart(_ raw: UnsafeRawBufferPointer, lo: Int, pos: Int, base: Int) -> TriCursor {
        var t = TriCursor(m: lo, base: base, end: base + count)
        t.wi = pos >> 6
        guard t.wi < tri.words else { return t }
        t.w = Self.u64(raw, tri.high, t.wi) & (~0 &<< UInt64(pos & 63))
        triNext(raw, &t)
        return t
    }

    @inline(__always) fileprivate func triNext(_ raw: UnsafeRawBufferPointer, _ t: inout TriCursor) {
        t.c = Int.max
        guard t.m < tri.n else { return }
        while t.w == 0 { t.wi += 1; if t.wi >= tri.words { return }; t.w = Self.u64(raw, tri.high, t.wi) }
        let k = (t.wi << 6 + t.w.trailingZeroBitCount - t.m) &<< tri.l | Self.low(raw, tri, t.m)
        guard k < t.end else { return }
        t.c = k - t.base; t.v = q(cbValue(raw, cb3Base, triScore, t.m, bits3))
        t.w &= t.w &- 1; t.m += 1
    }

    /// Ngữ cảnh sau (`prev2`, `prev1`) — id vnlexicon, -1 = không có. nil nếu prev1 không
    /// hợp lệ (không có ngữ cảnh ⇒ caller chấm như không có LM).
    func context(prev2: Int, prev1: Int) -> Context? {
        guard prev1 >= 0, prev1 < count else { return nil }
        return blob.withUnsafeBytes { raw -> Context in
            let g2 = q(Int(Int8(bitPattern: raw[g2Base + prev1])))
            var k = -1
            if prev2 >= 0, prev2 < count {
                let j = biFind(raw, biRowAt(raw, prev2), prev1)
                if j >= 0 { k = context(raw, bigramIndex: j) }
            }
            let row = biRowAt(raw, prev1)
            guard k >= 0 else {
                return Context(lm: self, g2: g2, bi: row, triBase: -1, triLo: 0, triPos: 0, g3: 0)
            }
            let (lo, pos) = Self.lowerBound(raw, tri, k * count)
            return Context(lm: self, g2: g2, bi: row, triBase: k * count, triLo: lo, triPos: pos,
                           g3: q(cbValue(raw, cbgBase, g3Base, k, bitsG)))
        }
    }

    /// Thêm dấu (Viterbi bậc 2): duyệt MỌI mục trigram tường minh (prev2, b, c) với b trong dải
    /// id [bLo, bHi) và c trong [cLo, cHi) — ứng viên của một dạng không dấu là một dải id liền
    /// nhau: body(b, c, s3 + uniAdj). Một lần withUnsafeBytes cho cả dải b (mỗi b: biFind trong
    /// dòng prev2 + một lowerBound trong dòng trigram) thay vì một `context` cho từng cặp.
    func forEachTrigram(prev2 a: Int, prev1 bLo: Int, _ bHi: Int, next cLo: Int, _ cHi: Int,
                        _ body: (_ prev1: Int, _ next: Int, _ pmi: Float) -> Void) {
        let lo = max(0, bLo), hi = min(bHi, count)
        guard a >= 0, a < count, lo < hi, cLo < cHi else { return }
        blob.withUnsafeBytes { raw in
            let row = biRowAt(raw, a)
            guard row.hi > row.lo else { return }
            for b in lo..<hi {
                let j = biFind(raw, row, b)
                guard j >= 0 else { continue }
                let k = context(raw, bigramIndex: j)
                guard k >= 0 else { continue }
                let base = k * count
                let (m, pos) = Self.lowerBound(raw, tri, base + max(0, cLo))
                var t = triStart(raw, lo: m, pos: pos, base: base)
                while t.c < cHi { body(b, t.c, t.v + adj(raw, t.c)); triNext(raw, &t) }
            }
        }
    }

    /// s (nat) của `w` sau (`prev2`, `prev1`); 0 nếu không có ngữ cảnh.
    func score(prev2: Int, prev1: Int, _ w: Int) -> Float {
        context(prev2: prev2, prev1: prev1)?.score(w) ?? 0
    }

    /// ln(P1(c)·N / c(c)) — đổi s2 (so với P1) thành PMI (so với tần suất thật).
    func uniAdj(_ w: Int) -> Float {
        guard w >= 0, w < count else { return 0 }
        return blob.withUnsafeBytes { adj($0, w) }
    }

    /// Dải bigram của âm tiết trước — thanh gợi ý gõ chạm + Thêm dấu (thay vnbigram.bin).
    /// `size` = 0 ⇒ âm tiết trước không có mục nào (không biết gì về nó).
    struct Bigram {
        fileprivate let lm: SyllableLM?
        fileprivate let g2: Float
        fileprivate let row: BiRow
        var size: Int { row.hi - row.lo }

        /// PMI (nat) của âm tiết sau id `next`; thiếu mục ⇒ lùi γ2(prev) + uniAdj; dải rỗng ⇒ 0.
        func pmi(_ next: Int) -> Float {
            guard let lm, size > 0, next >= 0, next < lm.count else { return 0 }
            return lm.blob.withUnsafeBytes { raw -> Float in
                let j = lm.biFind(raw, row, next)
                return (j >= 0 ? lm.biScoreAt(raw, j) : g2) + lm.adj(raw, next)
            }
        }

        /// PMI của mục tường minh; 0 nếu thiếu.
        func explicit(_ next: Int) -> Float {
            guard let lm, size > 0, next >= 0, next < lm.count else { return 0 }
            return lm.blob.withUnsafeBytes { raw -> Float in
                let j = lm.biFind(raw, row, next)
                return j >= 0 ? lm.biScoreAt(raw, j) + lm.adj(raw, next) : 0
            }
        }

        /// Duyệt mọi mục tường minh (id âm tiết sau, PMI) theo id tăng dần — thanh gợi ý lấy
        /// top từ kế tiếp. Giải mã tuần tự, không cấp phát.
        func forEach(_ body: (_ next: Int, _ pmi: Float) -> Void) {
            guard let lm, size > 0 else { return }
            lm.blob.withUnsafeBytes { raw in
                lm.biScan(raw, row) { m, c in body(c, lm.biScoreAt(raw, m) + lm.adj(raw, c)) }
            }
        }
    }

    /// Dải bigram của âm tiết trước id `prev` (id vnlexicon) — O(1) qua biRow.
    func bigram(_ prev: Int) -> Bigram {
        guard prev >= 0, prev < count else { return Bigram(lm: nil, g2: 0, row: .empty) }
        return blob.withUnsafeBytes { raw in
            Bigram(lm: self, g2: q(Int(Int8(bitPattern: raw[g2Base + prev]))), row: biRowAt(raw, prev))
        }
    }

    /// FNV-1a trên toàn bộ mô hình theo thứ tự giải mã (= CHECKSUM của vnlm-parity.txt, script
    /// tính từ dict): mỗi mục bigram (khoá u32, điểm i8, cờ trigram u8), γ3 mỗi ngữ cảnh, mỗi
    /// mục trigram (khoá u32, điểm i8). Chỉ cho test (duyệt cả file).
    func modelChecksum() -> UInt32 {
        blob.withUnsafeBytes { raw in
            var h: UInt32 = 0x811C9DC5
            func mix(_ b: Int) { h = (h ^ UInt32(UInt8(truncatingIfNeeded: b))) &* 0x01000193 }
            func mix32(_ v: Int) { for s in stride(from: 0, to: 32, by: 8) { mix(v >> s) } }
            for b in 0..<count {
                biScan(raw, biRowAt(raw, b)) { j, c in
                    mix32(b * count + c); mix(Int(raw[biScore + j]))
                    mix(Self.bit(raw, hasTri, j) ? 1 : 0)
                }
            }
            for k in 0..<triContexts { mix(cbValue(raw, cbgBase, g3Base, k, bitsG)) }
            Self.scan(raw, tri, 0, 0, triEntries) { t, key in
                mix32(key); mix(cbValue(raw, cb3Base, triScore, t, bits3))
            }
            return h
        }
    }

    /// FNV-1a phần thân (sau header) — phải bằng payloadHash ghi ở header 40.
    func payloadHashOK() -> Bool {
        UInt32(Self.u32(blob, 40)) == Self.fnv1a(blob.dropFirst(Self.headerSize))
    }

    /// Kiểm tra header + khớp lexicon + bảng phần (cỡ từng phần phải đúng như tính từ header);
    /// nil nếu hỏng/lệch (chạy không LM). Không quét thân (nạp ~0 chi phí); mọi vòng quét có
    /// chặn biên nên file hỏng nội dung cũng không đọc tràn.
    static func load(_ d: Data, lexiconHash: UInt32, lexiconCount: Int) -> SyllableLM? {
        guard d.count >= headerSize, d.prefix(4).elementsEqual("VNM1".utf8),
              u32(d, 4) == version, u32(d, 8) == lexiconCount, UInt32(u32(d, 12)) == lexiconHash,
              u32(d, 16) > 0 else { return nil }
        let off = (0...sectionCount).map { u32(d, 48 + $0 * 4) }
        let byte = { (i: Int) in Int(d[d.startIndex + i]) }
        let n = lexiconCount, nb = u32(d, 20), nk = u32(d, 24), nt = u32(d, 28)
        let tL = byte(32), b3 = byte(34), bg = byte(35), bs = byte(36), ts = byte(37)
        guard tL < 32, byte(33) == 8, [b3, bg].allSatisfy({ (1...8).contains($0) }), [bs, ts].allSatisfy({ (1...16).contains($0) }),
              tL == efL(nt, nk * n), off[sectionCount] == d.count, off[0] == headerSize,
              zip(off, off.dropFirst()).allSatisfy({ $0 <= $1 }), off[7] - off[4] >= 3 * (n + 1) * 4 else { return nil }
        // tổng ở cuối 3 bảng dòng bigram ⇒ cỡ các phần bigram
        let rowEnd = u32(d, off[4] + n * 4), zeroEnd = u32(d, off[5] + n * 4), lowEnd = u32(d, off[6] + n * 4)
        func pad(_ bytes: Int) -> Int { (bytes + 7) & ~7 + 8 }
        func sel(_ zeros: Int, _ s: Int) -> Int { pad(zeros > 0 ? (((zeros - 1) >> s) + 1) * 4 : 0) }
        let tz = ((nk * n) >> tL) + 1
        let want = [pad(n), pad(n), pad(1 << b3), pad(1 << bg),
                    pad((n + 1) * 4), pad((n + 1) * 4), pad((n + 1) * 4),
                    pad((lowEnd + 7) / 8), pad((nb + zeroEnd + 7) / 8), sel(zeroEnd, bs),
                    pad(nb), pad((nb + 7) / 8), pad(((nb >> 6) + 1) * 4), pad((nk * bg + 7) / 8),
                    pad((nt * tL + 7) / 8), pad((nt + tz + 7) / 8), sel(tz, ts), pad((nt * b3 + 7) / 8)]
        guard rowEnd == nb else { return nil }
        for i in 0..<sectionCount where off[i + 1] - off[i] != want[i] { return nil }
        return SyllableLM(blob: d, off: off)
    }

    /// Mô hình dùng chung (gõ vuốt + thanh gợi ý + Thêm dấu — một lần map) — map lần đầu cần,
    /// nên chạm lần đầu ở hàng đợi nền (hash vnlexicon ~150KB). nil nếu thiếu/hỏng/lệch.
    static let shared: SyllableLM? = {
        #if VIETTELEX_CLI   // công cụ văn bản Linux (linux/engine-capi: viettelex-text-tool)
        let url = VTDataFile.url("vnlm.bin")
        #else
        final class BundleToken {}
        let url = Bundle(for: BundleToken.self).url(forResource: "vnlm", withExtension: "bin")
        #endif
        guard let url, let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return load(d, lexiconHash: fnv1a(VNLexicon2Data.blob), lexiconCount: VNLexicon2Data.count)
    }()

    static func fnv1a(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { raw in
            var h: UInt32 = 0x811C9DC5
            for b in raw { h = (h ^ UInt32(b)) &* 0x01000193 }
            return h
        }
    }

    private static let oldStyle: [String: String] = [
        "oà": "òa", "oá": "óa", "oả": "ỏa", "oã": "õa", "oạ": "ọa",
        "oè": "òe", "oé": "óe", "oẻ": "ỏe", "oẽ": "õe", "oẹ": "ọe",
        "uỳ": "ùy", "uý": "úy", "uỷ": "ủy", "uỹ": "ũy", "uỵ": "ụy",
    ]

    /// NFC, chữ thường, kiểu dấu CŨ như vnlexicon (hoà → hòa; quý giữ nguyên).
    static func normalize(_ w: String) -> String {
        let s = w.lowercased().precomposedStringWithCanonicalMapping
        guard s.count >= 2 else { return s }
        let pair = String(s.suffix(2))
        guard let rep = oldStyle[pair] else { return s }
        if pair.first == "u", s.count >= 3, s.dropLast(2).last == "q" { return s }
        return String(s.dropLast(2)) + rep
    }

    /// id vnlexicon của âm tiết `word` (đã normalize), nil nếu không có.
    static func id(of word: String) -> Int? {
        let w = normalize(word)
        guard let f = SwipeLexicon.index(of: SwipeLexicon.fold(w)) else { return nil }
        let forms = SwipeLexicon.forms
        for id in Int(forms.idStart[f])..<Int(forms.idStart[f + 1]) where VNSuggest.display(id) == w {
            return id
        }
        return nil
    }
}
