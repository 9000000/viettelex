// UserLangModel — datastore cá nhân hóa cho thanh gợi ý. Học từ user hay gõ
// (unigram), cặp từ (bigram) và bộ ba (trigram — tiếng Việt đơn âm tiết nên
// "cảm ơn → nhiều" chỉ trigram mới bắt được) để gợi ý từ ĐẦU CÂU và từ KẾ TIẾP.
//
// Thiết kế theo khảo cứu 2026-07-24 (Gboard/SwiftKey/Grammarly — cache n-gram
// model interpolate với static seed):
// - Ranking = linear interpolation với Bayesian shrinkage λ = n/(n+K): prev
//   mới gặp 1-2 lần thì tin seed tĩnh, gặp nhiều thì tin dữ liệu cá nhân —
//   một lần gõ nhầm không đè được seed curated.
// - "Learning vs suggesting" (Grammarly): từ NGOÀI lexicon phải đạt count ≥3
//   mới được gợi ý (vẫn đếm từ lần đầu) — chặn học typo.
// - Time decay: mỗi ≥7 ngày nhân mọi count với 0.7^tuần lúc load; kèm cap
//   cứng halve-when-full.
// - PERF: decode/encode/IO chạy trên serial queue .utility — init trả về ngay,
//   bảng swap-in trên main khi decode xong (~50ms đầu gợi ý rỗng, chấp nhận);
//   record() trong cửa sổ chờ được buffer và phát lại sau swap-in.
//
// BẢNG GỌN (09/2026, RAM-AUDIT §5 — trước đây nested [String: [String: Int]], ~1 KB/mục):
// từ intern thành id Int32 (UserLMTables), uni là mảng count theo id, bi là "prev id →
// mảng sắp xếp (next id<<32 | count)", tri là "(p2<<32|p1) → slot → mảng như bi". Lookup
// vẫn O(1)/O(log n) mỗi phím; ngữ nghĩa (cap, decay, prune, retract, thứ tự gợi ý) y hệt bản cũ
// (property test so với LegacyUserLangModel). File: nhị phân VTL2 `userlm.bin` (little-endian,
// CRC32) — chung layout với Android; bản plist cũ `userlm.plist` được chuyển một lần rồi xoá.
// Sao lưu / Từ điển cá nhân đi qua `Plain` (dict như cũ) — JSON sao lưu không đổi.
//
// PRIVACY: chỉ đếm TẦN SUẤT (không câu, không thứ tự, không timestamp per-từ);
// ô mật khẩu không đi qua đây; toggle "Học từ hay dùng" + nút xoá trong app.
import Foundation

final class UserLangModel {
    private var t = UserLMTables()
    private var lastDecay = Date()
    /// Từ user tự thêm (màn Từ điển cá nhân): key lowercase → dạng hiển thị ("VietTelex").
    private(set) var manual: [String: String] = [:] { didSet { manualIndex = nil } }
    /// Chỉ mục tiền tố cho `manualCompletions` (đường gõ, mỗi phím): (UTF-8 của fold NFC,
    /// fold, key) sắp theo byte. Dựng lười lần đầu cần sau khi `manual` đổi (thêm/xoá/nạp —
    /// hiếm) ⇒ mỗi phím chỉ fold TIỀN TỐ + tìm nhị phân, không fold cả danh sách.
    private var manualIndex: [(bytes: [UInt8], fold: String, key: String)]?

    /// Bảng dạng dict (tests / công cụ) — dựng lại mỗi lần gọi, KHÔNG dùng trên đường gõ.
    var uni: [String: Int] { t.uniDict() }
    var bi: [String: [String: Int]] { t.biDict() }
    var tri: [String: [String: Int]] { t.triDict() }
    var uniCount: Int { t.uniN }
    var biPairCount: Int { t.biN }
    var triPairCount: Int { t.triN }

    /// Lexicon tĩnh — controller nạp VNLexicon vào; từ trong lexicon được gợi ý
    /// ngay, từ lạ cần đạt ngưỡng. Mặc định false để tests kiểm soát được.
    var isKnownWord: (String) -> Bool = { _ in false } {
        didSet { knownCache.removeAll(); topCache = nil }
    }

    /// Gọi trên main sau khi bảng trên đĩa swap-in xong (controller có thể
    /// refresh thanh gợi ý). Không gọi ở chế độ in-memory (tests).
    var onReady: (() -> Void)?

    /// Đường dẫn "gốc" (userlm.plist — tên cũ, giữ cho API); file thật là `compactURL(for:)`.
    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    // Encode/decode/IO nền — mọi đọc/ghi bảng vẫn ở main thread.
    private let ioQueue = DispatchQueue(label: "com.viettelex.userlm.io", qos: .utility)
    private var isLoaded = false
    private var loadGeneration = 0    // eraseAll() giữa chừng → bỏ kết quả load cũ
    private var pendingRecords: [(word: String, prev1: String?, prev2: String?, weight: Int)] = []
    private var pendingSeed: (uni: () -> [String: Int], bi: () -> [(String, String, Int)])?
    /// Nguồn seed gần nhất — để reloadAfterExternalEdit() seed lại khi file bị app xoá.
    private var seedSource: (uni: () -> [String: Int], bi: () -> [(String, String, Int)])?

    // Memo isKnownWord (VNSuggest.contains = binary search + alloc mỗi lần) —
    // tính hợp lệ của một từ không đổi trong đời keyboard.
    private var knownCache: [String: Bool] = [:]
    // Cache topWords — invalidate khi record/decay/prune/seed thay đổi uni.
    /// `keys` = khoá chữ thường, `words` = dạng hiển thị, cùng thứ tự (count giảm, khoá tăng).
    private var topCache: (k: Int, keys: [String], words: [String])?

    private static let uniCap = 3000
    private static let biCap = 6000
    private static let triCap = 3000
    private static let unknownSuggestThreshold = 3
    private static let pendingRecordCap = 128
    static let sep = "\u{1}"
    /// Count khởi điểm của từ thêm tay: ≥ ngưỡng gợi ý, xếp trên từ học 1-2 lần.
    static let manualCount = 5
    static let manualMaxLen = 24
    static let legacyFileName = "userlm.plist"

    /// Store thật trong App Group; truyền nil cho tests (in-memory).
    init(appGroup: String? = "group.com.viettelex") {
        if let g = appGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
            fileURL = dir.appendingPathComponent(Self.legacyFileName)
        } else {
            fileURL = nil
        }
        if let url = fileURL {
            loadAsync(from: url)
        } else {
            isLoaded = true          // in-memory: sẵn sàng ngay, tests đồng bộ
        }
    }

    /// Tests: store thật ở file tuỳ ý (App Group không có trong test hostless).
    /// `synchronous`: đọc file NGAY trên thread gọi (app — màn Từ điển cá nhân).
    init(fileURL url: URL, synchronous: Bool = false) {
        fileURL = url
        if synchronous {
            finishLoad(Self.readTables(from: url))
        } else {
            loadAsync(from: url)
        }
    }

    /// Store App Group mở đồng bộ cho app chứa (màn Từ điển cá nhân); nil nếu không có App Group.
    static func openSharedForEditing(appGroup: String = "group.com.viettelex") -> UserLangModel? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        return UserLangModel(fileURL: dir.appendingPathComponent(legacyFileName), synchronous: true)
    }

    private func loadAsync(from url: URL) {
        let gen = loadGeneration
        ioQueue.async { [weak self] in
            let t = Self.readTables(from: url)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == gen else { return }
                self.finishLoad(t)
            }
        }
    }

    private func finishLoad(_ l: LoadedTables?) {
        if let l {
            t = l.tables; lastDecay = l.lastDecay
            manual = [:]
            for d in l.manual { manual[d.lowercased()] = d }
            keepManual()
        }
        isLoaded = true
        topCache = nil
        if t.uniN == 0, let seed = pendingSeed {
            applySeed(unigrams: seed.uni(), bigrams: seed.bi())
        }
        pendingSeed = nil
        let queued = pendingRecords
        pendingRecords = []
        for r in queued { record(word: r.word, after: r.prev1, prev2: r.prev2, weight: r.weight) }
        decayIfDue()
        onReady?()
    }

    // MARK: học

    /// Một từ vừa chốt. `prev1`/`prev2` = 1-2 từ đứng trước trong cùng câu.
    /// `weight`: 1 cho từ gõ thường, 2 cho suggestion được user bấm nhận
    /// (tín hiệu chất lượng cao hơn).
    /// Biên nhận một lần `record` — `retract` rút lại đúng lượt đó (vd hoàn tác tự sửa).
    struct Learned: Equatable {
        let word: String
        let prev1: String?
        let triKey: String?
        let weight: Int
    }

    @discardableResult
    func record(word: String, after prev1: String?, prev2: String? = nil, weight: Int = 1) -> Learned? {
        guard isLoaded else {
            if pendingRecords.count < Self.pendingRecordCap {
                pendingRecords.append((word, prev1, prev2, weight))
            }
            return nil
        }
        guard weight > 0, Self.learnable(word) else { return nil }
        let w = word.lowercased()
        let wid = t.intern(w)
        t.setUni(wid, t.uni(wid) + weight)
        bumpTopCache(w)
        var biKey: String?, triKey: String?
        if let p1 = prev1?.lowercased(), Self.learnable(p1) {
            let pid = t.intern(p1)
            t.addBi(pid, wid, weight)
            biKey = p1
            // trigram chỉ ghi khi cặp (p2,p1) đã có nền — giảm noise/chỗ
            if let p2 = prev2?.lowercased(), Self.learnable(p2),
               let p2id = t.ids[p2], t.biCount(p2id, pid) >= 2 {
                t.addTri(UserLMTables.ctx(p2id, pid), wid, weight)
                triKey = p2 + Self.sep + p1
            }
        }
        pruneIfNeeded()
        scheduleSave()
        return Learned(word: w, prev1: biKey, triKey: triKey, weight: weight)
    }

    /// Rút lại một lần `record`. Không âm, bỏ mục về 0. Giống Android `retract`.
    func retract(_ l: Learned) {
        guard let wid = t.ids[l.word] else { return }
        let had = t.uni(wid)
        guard had > 0 else { return }
        t.setUni(wid, had <= l.weight ? 0 : had - l.weight)
        topCache = nil
        if let k = l.prev1, let pid = t.ids[k] { t.decBi(pid, wid, l.weight) }
        if let k = l.triKey {
            let parts = k.components(separatedBy: Self.sep)
            if parts.count == 2, let a = t.ids[parts[0]], let b = t.ids[parts[1]] {
                t.decTri(UserLMTables.ctx(a, b), wid, l.weight)
            }
        }
        scheduleSave()
    }

    /// Từ của người dùng: thêm tay, hoặc đã gõ đủ nhiều để được gợi ý — tự sửa không đụng.
    func isUserWord(_ w: String) -> Bool {
        let k = w.lowercased()
        return manual[k] != nil || t.uni(k) >= Self.unknownSuggestThreshold
    }

    /// Từ "học được": chữ cái thuần, ngắn, không chuỗi lặp kiểu "heeeyyy".
    static func learnable(_ w: String) -> Bool {
        guard !w.isEmpty, w.count <= 12, w.allSatisfy({ $0.isLetter }) else { return false }
        var run = 1
        var prev: Character?
        for c in w {
            run = (c == prev) ? run + 1 : 1
            if run >= 3 { return false }
            prev = c
        }
        return true
    }

    private func cachedKnown(_ w: String) -> Bool {
        if let v = knownCache[w] { return v }
        if knownCache.count > 4096 { knownCache.removeAll() }   // chặn phình vô hạn
        let v = isKnownWord(w)
        knownCache[w] = v
        return v
    }

    /// Được phép XUẤT HIỆN trong gợi ý chưa? (learning vs suggesting)
    private func suggestable(_ w: String) -> Bool {
        cachedKnown(w) || manual[w] != nil || t.uni(w) >= Self.unknownSuggestThreshold
    }

    // MARK: từ điển cá nhân (màn quản lý trong app)

    struct Entry: Equatable {
        let word: String      // dạng hiển thị
        let count: Int
        let manual: Bool
    }

    /// Mọi từ đã học + từ thêm tay, tần suất giảm dần (hoà: theo chữ cái). `query` ≠ rỗng:
    /// chỉ từ CHỨA chuỗi tìm (bỏ dấu, không phân biệt hoa/thường — "viet" khớp "việt").
    func entries(query: String = "") -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        var out: [Entry] = []
        for (i, c) in t.uniC.enumerated() where c > 0 {
            let k = t.words[i]
            guard q.isEmpty || Self.fold(k).contains(q) else { continue }
            out.append(Entry(word: manual[k] ?? k, count: Int(c), manual: manual[k] != nil))
        }
        return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0.word.lowercased() < $1.word.lowercased() }
    }

    /// Xoá hẳn một từ: unigram, mọi bigram/trigram có từ đó (ở vị trí trước hay sau), và
    /// dấu "thêm tay". true nếu có gì bị xoá.
    @discardableResult
    func removeWord(_ word: String) -> Bool {
        let w = word.lowercased()
        var changed = manual.removeValue(forKey: w) != nil
        if let id = t.ids[w], t.removeWord(id) { changed = true }
        guard changed else { return false }
        t.compact()
        topCache = nil
        knownCache[w] = nil
        scheduleSave()
        return true
    }

    /// Thêm tay một từ (tên riêng, thuật ngữ) — được gợi ý ngay (không cần đạt ngưỡng từ
    /// lạ), hiện ở hoàn thiện từ khi gõ tiền tố, không bị decay/prune xoá. false nếu không hợp lệ.
    @discardableResult
    func addWord(_ raw: String) -> Bool {
        guard let display = Self.normalizeManual(raw) else { return false }
        let w = display.lowercased()
        manual[w] = display
        let id = t.intern(w)
        if t.uni(id) < Self.manualCount { t.setUni(id, Self.manualCount) }
        topCache = nil
        scheduleSave()
        return true
    }

    /// Từ thêm tay khớp tiền tố đang gõ (bỏ dấu, không phân biệt hoa/thường), dạng hiển thị.
    /// Gọi trên main MỖI PHÍM ⇒ dùng `manualIndex` (fold sẵn, sắp xếp) thay vì fold cả danh sách.
    func manualCompletions(_ prefix: String, limit: Int = 2) -> [String] {
        guard !manual.isEmpty, !prefix.isEmpty else { return [] }
        let f = Self.fold(prefix).precomposedStringWithCanonicalMapping
        let fb = Array(f.utf8)
        let idx = manualIndex ?? buildManualIndex()
        // Cận dưới theo byte: mọi chuỗi có tiền tố byte `fb` nằm liền một khối từ đây.
        var lo = 0, hi = idx.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if idx[mid].bytes.lexicographicallyPrecedes(fb) { lo = mid + 1 } else { hi = mid }
        }
        var hits: [String] = []
        var i = lo
        while i < idx.count, idx[i].bytes.starts(with: fb) {
            // hasPrefix theo Character (như bản cũ) — khác tiền tố byte chỉ ở dấu kết hợp lẻ.
            let e = idx[i]
            if e.fold.hasPrefix(f), let d = manual[e.key], d != prefix { hits.append(e.key) }
            i += 1
        }
        return hits
            .sorted { a, b in
                let ca = t.uni(a), cb = t.uni(b)
                return ca != cb ? ca > cb : a < b
            }
            .prefix(limit).compactMap { manual[$0] }
    }

    private func buildManualIndex() -> [(bytes: [UInt8], fold: String, key: String)] {
        let idx = manual.keys.map { k -> (bytes: [UInt8], fold: String, key: String) in
            let f = Self.fold(k).precomposedStringWithCanonicalMapping
            return (Array(f.utf8), f, k)
        }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        manualIndex = idx
        return idx
    }

    #if DEBUG
    /// Test: chỉ mục đã dựng chưa (bị bỏ khi `manual` đổi).
    var debugHasManualIndex: Bool { manualIndex != nil }
    #endif

    /// Chuẩn hoá từ nhập tay: bỏ khoảng trắng đầu/cuối, chỉ chữ cái, 1…24 ký tự. nil = không hợp lệ.
    static func normalizeManual(_ raw: String) -> String? {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !w.isEmpty, w.count <= manualMaxLen, w.allSatisfy({ $0.isLetter }) else { return nil }
        return w
    }

    /// Bỏ dấu + lowercase + đ→d.
    static func fold(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    /// Từ thêm tay luôn còn trong uni (decay/prune không được xoá).
    private func keepManual() {
        for k in manual.keys where t.uni(k) < 1 { t.setUni(t.intern(k), 1) }
    }

    // MARK: gợi ý

    /// Top từ user hay dùng nhất — cho field trống chưa gõ gì.
    /// Cached: chỉ tính lại sau record/decay/prune/seed; sort trước rồi mới
    /// chạy suggestable() (memoized) trên phần đầu bảng — không probe lexicon
    /// cho cả ~3000 từ.
    func topWords(limit: Int) -> [String] {
        if let c = topCache, c.k >= limit { return Array(c.words.prefix(limit)) }
        var ranked: [(id: Int32, c: UInt32)] = []
        ranked.reserveCapacity(t.uniN)
        for (i, c) in t.uniC.enumerated() where c > 0 { ranked.append((Int32(i), c)) }
        let words = t.words
        ranked.sort { $0.c != $1.c ? $0.c > $1.c : words[Int($0.id)] < words[Int($1.id)] }
        var keys: [String] = [], out: [String] = []
        out.reserveCapacity(limit)
        for (id, _) in ranked {
            let w = words[Int(id)]
            guard suggestable(w) else { continue }
            keys.append(w)
            out.append(manual[w] ?? w)
            if out.count >= limit { break }
        }
        topCache = (limit, keys, out)
        return out
    }

    #if DEBUG
    /// Test hook: bảng unigram (khoá chữ thường → count).
    func debugUnigrams() -> [String: Int] { t.uniDict() }
    /// Test hook: số từ trong bảng intern (kể cả từ mồ côi chờ compact).
    var debugVocabCount: Int { t.words.count }
    #endif

    /// `w` vừa tăng count: cập nhật top-K TẠI CHỖ (K ≤ ~20) thay vì bỏ cache — trước đây
    /// mỗi dấu cách sort lại tới 3000 từ trên main (topWords ở padWords sau mỗi từ).
    /// Thứ tự giống hệt sort đầy đủ: count giảm dần, hoà theo khoá tăng dần.
    private func bumpTopCache(_ w: String) {
        guard var c = topCache else { return }
        let n = t.uni(w)
        func before(_ a: String, _ ca: Int, _ b: String) -> Bool {
            let cb = t.uni(b)
            return ca != cb ? ca > cb : a < b
        }
        if let i = c.keys.firstIndex(of: w) {
            c.keys.remove(at: i); c.words.remove(at: i)
        } else if !suggestable(w) {
            return
        } else if c.keys.count >= c.k, let last = c.keys.last, !before(w, n, last) {
            return                                  // vẫn không lọt top-K
        }
        let j = c.keys.firstIndex { !before($0, t.uni($0), w) } ?? c.keys.count
        c.keys.insert(w, at: j); c.words.insert(manual[w] ?? w, at: j)
        if c.keys.count > c.k { c.keys.removeLast(); c.words.removeLast() }
        topCache = c
    }

    /// Từ kế tiếp sau (prev2, prev1): interpolation trigram ⊕ bigram ⊕ unigram
    /// ⊕ seed tĩnh, mỗi tầng có shrinkage riêng.
    func nextWords(after prev1: String, prev2: String? = nil, limit: Int) -> [String] {
        let p1 = prev1.lowercased()
        let pid = t.ids[p1]
        let biBucket = pid.map { t.biB[Int($0)] } ?? []
        var triBucket: ContiguousArray<UInt64> = []
        if let pid, let p2 = prev2, let p2id = t.ids[p2.lowercased()],
           let slot = t.triIdx[UserLMTables.ctx(p2id, pid)] {
            triBucket = t.triB[Int(slot)]
        }
        let seeds = Self.seedNext[p1] ?? []

        var biTotal = 0, triTotal = 0
        for e in biBucket { biTotal += UserLMTables.cnt(e) }
        for e in triBucket { triTotal += UserLMTables.cnt(e) }
        let uniTotal = max(t.uniTotal, 1)
        let lamTri = Double(triTotal) / (Double(triTotal) + 2)
        let lamBi = Double(biTotal) / (Double(biTotal) + 4)

        // Ứng viên = bi ∪ tri (trộn 2 mảng sắp theo id) ∪ seed; count lấy luôn khi trộn.
        var cands: [(w: String, bc: Int, tc: Int)] = []
        cands.reserveCapacity(biBucket.count + triBucket.count + seeds.count)
        var i = 0, j = 0
        while i < biBucket.count || j < triBucket.count {
            let bn = i < biBucket.count ? UserLMTables.nid(biBucket[i]) : UInt32.max
            let tn = j < triBucket.count ? UserLMTables.nid(triBucket[j]) : UInt32.max
            let id = min(bn, tn)
            var bc = 0, tc = 0
            if bn == id { bc = UserLMTables.cnt(biBucket[i]); i += 1 }
            if tn == id { tc = UserLMTables.cnt(triBucket[j]); j += 1 }
            cands.append((t.words[Int(id)], bc, tc))
        }
        for s in seeds where !cands.contains(where: { $0.w == s }) { cands.append((s, 0, 0)) }

        func score(_ c: (w: String, bc: Int, tc: Int)) -> Double {
            let pTri = triTotal > 0 ? Double(c.tc) / Double(triTotal) : 0
            let pBi = biTotal > 0 ? Double(c.bc) / Double(biTotal) : 0
            let pUni = Double(t.uni(c.w)) / Double(uniTotal)
            let pSeed: Double = seeds.firstIndex(of: c.w).map { pow(0.5, Double($0)) } ?? 0
            return lamTri * pTri
                + lamBi * pBi
                + 0.1 * pUni
                + (1 - lamBi) * 0.9 * pSeed
        }
        // score() tính MỘT lần mỗi từ rồi sort tuple.
        return cands.filter { suggestable($0.w) || seeds.contains($0.w) }
            .map { ($0.w, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit).map { manual[$0.0] ?? $0.0 }
    }

    /// Điểm cá nhân của một từ (re-rank completion của lexicon).
    /// Key trong uni đã lowercase sẵn — chỉ alloc lowercased khi lookup thô miss.
    func count(of word: String) -> Int {
        let c = t.uni(word)
        return c > 0 ? c : t.uni(word.lowercased())
    }

    /// Số lần cặp (prev → word) đã gặp (bigram cá nhân + seed) — AddTones chấm lưới âm tiết.
    func bigramCount(_ prev: String, _ word: String) -> Int {
        guard let p = t.ids[prev.lowercased()], let w = t.ids[word] else { return 0 }
        return t.biCount(p, w)
    }

    /// Số lần bộ ba (prev2, prev → word) người dùng đã gõ (không có seed) — thanh gợi ý ưu tiên.
    func trigramCount(_ prev2: String, _ prev: String, _ word: String) -> Int {
        guard let a = t.ids[prev2.lowercased()], let b = t.ids[prev.lowercased()],
              let s = t.triIdx[UserLMTables.ctx(a, b)] else { return 0 }
        if let w = t.ids[word] { let c = t.triCount(Int(s), w); if c > 0 { return c } }
        guard let w = t.ids[word.lowercased()] else { return 0 }
        return t.triCount(Int(s), w)
    }

    /// Seed ban đầu — chỉ khi datastore trống (lần đầu / sau reset).
    /// @autoclosure: literal seed (~1400 entries) KHÔNG được build khi store
    /// đã có dữ liệu; đang chờ load thì giữ closure lại, quyết sau swap-in.
    func seedIfEmpty(unigrams: @autoclosure @escaping () -> [String: Int],
                     bigrams: @autoclosure @escaping () -> [(String, String, Int)]) {
        seedSource = (unigrams, bigrams)
        guard isLoaded else {
            pendingSeed = (unigrams, bigrams)
            return
        }
        guard t.uniN == 0 else { return }
        applySeed(unigrams: unigrams(), bigrams: bigrams())
    }

    private func applySeed(unigrams: [String: Int], bigrams: [(String, String, Int)]) {
        // uni đang rỗng (điều kiện gọi) — gán thẳng như `uni = unigrams` bản cũ.
        for (w, c) in unigrams where c > 0 { t.setUni(t.intern(w), c) }
        for (a, b, c) in bigrams where c > 0 { t.setBi(t.intern(a), t.intern(b), c) }
        topCache = nil
        save()
    }

    // MARK: persistence (nhị phân VTL2 — xem UserLMCodec)

    private struct LoadedTables {
        var tables: UserLMTables
        var lastDecay: Date
        var manual: [String]
    }

    /// Dạng dict của store — ranh giới với sao lưu (BackupStore) / công cụ. `manual` = dạng hiển thị.
    struct Plain: Equatable {
        var uni: [String: Int] = [:]
        var bi: [String: [String: Int]] = [:]
        var tri: [String: [String: Int]] = [:]
        var manual: [String] = []
        var lastDecay = Date()
    }

    /// File nhị phân thật ứng với đường dẫn gốc (…/userlm.plist → …/userlm.bin).
    static func compactURL(for url: URL) -> URL {
        url.pathExtension == "bin" ? url : url.deletingPathExtension().appendingPathExtension("bin")
    }

    private static func readTables(from url: URL) -> LoadedTables? {
        let bin = compactURL(for: url)
        if let data = try? Data(contentsOf: bin), let d = UserLMCodec.decode(data) {
            // Lần chuyển trước ghi xong nhưng chưa kịp xoá bản cũ.
            if bin != url { try? FileManager.default.removeItem(at: url) }
            return LoadedTables(tables: d.tables, lastDecay: d.lastDecay, manual: d.manual)
        }
        // Chưa có (hoặc hỏng) bản nhị phân: đọc bản cũ, chuyển MỘT lần. Bản cũ chỉ bị xoá sau khi
        // file mới đã ghi xong VÀ đọc lại khớp từng byte; ghi hỏng ⇒ giữ nguyên bản cũ, lần sau thử lại.
        guard bin != url, let old = readLegacy(url) else { return nil }
        let tables = UserLMTables(uni: old.uni, bi: old.bi, tri: old.tri)
        if writeVerified(UserLMCodec.encode(tables, lastDecay: old.lastDecay, manual: old.manual), to: bin) {
            try? FileManager.default.removeItem(at: url)
        }
        return LoadedTables(tables: tables, lastDecay: old.lastDecay, manual: old.manual)
    }

    /// Layout cũ: binary plist {version, uni, bi, tri, lastDecay, manual} hoặc JSON v1 (bigram phẳng).
    private struct LegacySnapshot: Codable { var uni: [String: Int]; var bi: [String: Int] }
    static func readLegacy(_ url: URL) -> Plain? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var p = Plain()
        if let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let u = dict["uni"] as? [String: Int] {
            p.uni = u
            p.bi = dict["bi"] as? [String: [String: Int]] ?? [:]
            p.tri = dict["tri"] as? [String: [String: Int]] ?? [:]
            p.lastDecay = dict["lastDecay"] as? Date ?? Date()
            p.manual = dict["manual"] as? [String] ?? []
        } else if let old = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            // v1 (userlm.json cùng nội dung): bigram phẳng "a␁b" → nested
            p.uni = old.uni
            for (k, c) in old.bi {
                let parts = k.split(separator: Character(sep), maxSplits: 1)
                guard parts.count == 2 else { continue }
                p.bi[String(parts[0]), default: [:]][String(parts[1])] = c
            }
        } else {
            return nil
        }
        return p
    }

    /// Sao lưu / Từ điển: đọc store (nhị phân, hoặc bản cũ chưa chuyển) thành dict. Không ghi gì.
    static func readPlain(at url: URL) -> Plain? {
        if let data = try? Data(contentsOf: compactURL(for: url)), let d = UserLMCodec.decode(data) {
            return Plain(uni: d.tables.uniDict(), bi: d.tables.biDict(), tri: d.tables.triDict(),
                         manual: d.manual, lastDecay: d.lastDecay)
        }
        return compactURL(for: url) == url ? nil : readLegacy(url)
    }

    /// Nhập sao lưu: ghi `p` thành store nhị phân (atomic, đọc lại kiểm tra) rồi bỏ bản cũ.
    @discardableResult
    static func writePlain(_ p: Plain, to url: URL) -> Bool {
        let bin = compactURL(for: url)
        let tables = UserLMTables(uni: p.uni, bi: p.bi, tri: p.tri)
        guard writeVerified(UserLMCodec.encode(tables, lastDecay: p.lastDecay, manual: p.manual), to: bin)
        else { return false }
        if bin != url { try? FileManager.default.removeItem(at: url) }
        return true
    }

    /// Xoá store (bản nhị phân + mọi bản cũ) — "Xoá từ đã học".
    static func removeStore(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: compactURL(for: url))
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
    }

    private static func writeVerified(_ data: Data, to url: URL) -> Bool {
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return (try? Data(contentsOf: url)) == data
    }

    private struct Snapshot { let tables: UserLMTables; let lastDecay: Date; let manual: [String] }

    /// Snapshot COW trên main (rẻ — chỉ tăng refcount mảng), encode + ghi atomic trên ioQueue.
    func save() {
        saveWork?.cancel(); saveWork = nil
        guard isLoaded, let url = fileURL else { return }
        let snap = snapshot()
        ioQueue.async { Self.write(snap, to: url) }
    }

    /// Flush cho viewWillDisappear — extension có thể bị suspend/kill ngay sau.
    /// KHÔNG còn ioQueue.sync (chặn main đúng lúc bàn phím đang được ẩn):
    /// - Không có thay đổi chờ ghi (saveWork == nil — mọi mutation đều qua
    ///   scheduleSave()/save()) → khỏi encode + ghi cả file mỗi lần ẩn.
    /// - Ghi enqueue async lên ioQueue NGAY trên main → giữ thứ tự FIFO với các
    ///   save() trước/sau (snapshot cũ không thể ghi đè snapshot mới).
    /// - performExpiringActivity xin iOS thêm thời gian chạy nền cho tới khi ghi
    ///   xong (dùng được trong extension, khác beginBackgroundTask). Hết giờ
    ///   (expired) giữa chừng: .atomic ghi file tạm rồi rename → file cũ nguyên
    ///   vẹn, tệ nhất mất vài count chưa ghi (cache, không phải sổ cái).
    func saveNow() {
        guard saveWork != nil else { return }
        saveWork?.cancel(); saveWork = nil
        guard isLoaded, let url = fileURL else { return }
        let snap = snapshot()
        let done = DispatchSemaphore(value: 0)
        ioQueue.async { Self.write(snap, to: url); done.signal() }
        ProcessInfo.processInfo.performExpiringActivity(
            withReason: "VietTelex: lưu dữ liệu học từ") { expired in
            guard !expired else { return }
            _ = done.wait(timeout: .now() + 10)
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(tables: t, lastDecay: lastDecay, manual: Array(manual.values))
    }

    private static func write(_ s: Snapshot, to url: URL) {
        let data = UserLMCodec.encode(s.tables, lastDecay: s.lastDecay, manual: s.manual)
        let bin = compactURL(for: url)
        try? data.write(to: bin, options: .atomic)
    }

    /// Extension bị kill không báo trước: coalesce 5s sau record cuối, mất tối
    /// đa vài count — đây là cache, không phải sổ cái.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// App chứa: ghi NGAY (đồng bộ) — sau đó mới báo bàn phím nạp lại.
    func saveSync() {
        saveWork?.cancel(); saveWork = nil
        guard isLoaded, let url = fileURL else { return }
        let snap = snapshot()
        ioQueue.sync { Self.write(snap, to: url) }
    }

    /// App đã sửa/xoá store (Từ điển cá nhân / "Xoá từ đã học" — mốc userlmResetAt
    /// trong App Group đổi): bỏ bảng trong RAM, huỷ ghi chờ (không bao giờ ghi đè bản của
    /// app), nạp lại file (vắng ⇒ seed lại).
    func reloadAfterExternalEdit() {
        loadGeneration += 1              // load đang bay (nếu có) bị bỏ kết quả
        saveWork?.cancel(); saveWork = nil
        t = UserLMTables(); manual = [:]
        pendingRecords = []; pendingSeed = nil
        topCache = nil
        knownCache.removeAll()
        if let url = fileURL {
            isLoaded = false
            pendingSeed = seedSource
            loadAsync(from: url)
        } else {
            isLoaded = true
            if let s = seedSource { applySeed(unigrams: s.uni(), bigrams: s.bi()) }
        }
    }

    func eraseAll() {
        loadGeneration += 1              // load đang bay (nếu có) bị bỏ kết quả
        isLoaded = true
        saveWork?.cancel(); saveWork = nil
        manual = [:]
        t = UserLMTables()
        pendingRecords = []; pendingSeed = nil
        topCache = nil
        if let url = fileURL {
            ioQueue.async { Self.removeStore(at: url) }
        }
    }

    // MARK: decay

    /// Hồ sơ phản ánh thói quen GẦN ĐÂY: mỗi ≥7 ngày, count *= 0.7^tuần
    /// (một timestamp toàn cục duy nhất — không lưu thời gian per-từ).
    func decayIfDue(now: Date = Date()) {
        let weeks = Int(now.timeIntervalSince(lastDecay) / (7 * 86400))
        guard weeks >= 1 else { return }
        let f = pow(0.7, Double(weeks))
        t.mapCounts(uni: true, bi: true, tri: true) { Int(Double($0) * f) }
        keepManual()
        t.compact()
        lastDecay = now
        topCache = nil
        save()
    }

    /// Quá trần cứng: chia đôi mọi count (từ hiếm rơi về 0 và bị loại).
    private func pruneIfNeeded() {
        let u = t.uniN > Self.uniCap, b = t.biN > Self.biCap, r = t.triN > Self.triCap
        guard u || b || r else { return }
        t.mapCounts(uni: u, bi: b, tri: r) { $0 / 2 }
        if u { keepManual(); topCache = nil }
        t.compact()
    }

    // MARK: seed bigrams — mồi tĩnh khi chưa có dữ liệu cá nhân

    static let seedNext: [String: [String]] = [
        "anh": ["ơi", "đang", "có", "yêu"],
        "em": ["ơi", "yêu", "đang", "nhé"],
        "chị": ["ơi", "đang", "có"],
        "mẹ": ["ơi", "đang", "có"],
        "bạn": ["ơi", "có", "đang"],
        "mình": ["đang", "có", "sẽ", "nghĩ"],
        "tôi": ["đang", "có", "sẽ", "nghĩ"],
        "cảm": ["ơn"],
        "xin": ["chào", "lỗi", "phép"],
        "chúc": ["mừng", "ngủ", "sức"],
        "không": ["có", "phải", "biết", "sao"],
        "rất": ["vui", "đẹp", "ngon", "tốt"],
        "hôm": ["nay", "qua"],
        "ngày": ["mai", "mới", "nào"],
        "buổi": ["sáng", "trưa", "chiều", "tối"],
        "đi": ["làm", "học", "chơi", "ăn"],
        "ăn": ["cơm", "sáng", "trưa", "tối"],
        "đang": ["làm", "ăn", "đi", "ở"],
        "có": ["khỏe", "thể", "gì", "ai"],
        "làm": ["gì", "việc", "sao"],
        "yêu": ["em", "anh", "quá"],
        "ngủ": ["ngon", "sớm", "dậy"],
        "tạm": ["biệt"],
        "hẹn": ["gặp"],
        "gặp": ["lại", "nhau"],
        "vui": ["quá", "lắm", "vẻ"],
        "được": ["không", "rồi", "chưa"],
        "nhớ": ["em", "anh", "nhé"],
    ]
}

// MARK: - Bảng gọn

/// Bảng n-gram gọn: từ intern thành id (`words`/`ids`), count UInt32.
/// - uni: `uniC[id]` (0 = không có mục).
/// - bi: `biB[prev id]` = mảng (next id << 32 | count) sắp tăng theo next id — duyệt bucket cho
///   nextWords, tra một cặp bằng binary search.
/// - tri: `triIdx[(p2 << 32) | p1]` → slot; `triB[slot]` như bi. Slot rỗng giữ tới lần compact.
/// Giá trị (value type): snapshot để lưu nền chỉ tăng refcount (COW).
struct UserLMTables {
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
            let parts = k.components(separatedBy: UserLangModel.sep)
            guard parts.count == 2 else { continue }
            for (n, c) in inner where c > 0 {
                setTri(Self.ctx(intern(parts[0]), intern(parts[1])), intern(n), c)
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
            d[words[Int(Self.nid(c))] + UserLangModel.sep + words[Int(UInt32(truncatingIfNeeded: c))]] = nested(b)
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
