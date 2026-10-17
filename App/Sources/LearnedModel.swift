// LearnedModel.swift — "HỌC TỪ BẠN GÕ" cho gợi ý từ trên máy tính (maintainer duyệt 16/10/2026).
// Dùng chung macOS (App/Sources) + Linux (symlink linux/engine-capi/Sources/TextToolCLI); bản
// C++ Windows: windows/app/core/learned_words.{h,cpp} (cùng số, cùng thứ tự — golden
// windows/app/tests/fixtures/word-prediction.tsv có cột `learn`).
//
// Cùng ngữ nghĩa UserLangModel iOS (iOS/docs/IOS-SUGGESTIONS.md tầng 3), dùng ĐÚNG bảng gọn +
// codec của iOS (iOS/Keyboard/UserLMTables.swift — UserLMTables / UserLMCodec "VTL2"), không
// kéo phần di trú plist/JSON, sao lưu, từ điển cá nhân (đo 16/10/2026: cả UserLangModel ≈ +95 KB
// mỗi kiến trúc; xem báo cáo trong commit):
//   • record: unigram += w, bigram (prev1 → từ) += w, trigram (prev2, prev1 → từ) += w CHỈ khi
//     cặp (prev2, prev1) đã ≥ 2 (giảm nhiễu) — y như iOS. w = 1 từ gõ, 2 gợi ý được nhận (Tab).
//   • learnable: chữ cái thuần, ≤ 12 ký tự, không chuỗi lặp ≥ 3 ("heeeyyy").
//   • trần cứng uni 3000 / bi 6000 / tri 3000: vượt ⇒ chia đôi mọi count của bảng đó + compact.
//   • decay: mỗi ≥ 7 ngày nhân mọi count với 0,7^tuần (một mốc thời gian toàn cục, lúc nạp).
//   • learning vs suggesting: từ NGOÀI vnlexicon phải đạt count ≥ 3 mới được gợi ý.
//   • xếp từ kế tiếp: nội suy λ_tri·P_tri + λ_bi·P_bi + 0,1·P_uni + (1−λ_bi)·0,9·P_seed
//     (λ = n/(n+2) trigram, n/(n+4) bigram) — seed = dòng SeedNextData (chính thứ tự iOS cho
//     người dùng mới), nên mô hình rỗng cho ĐÚNG kết quả cũ (golden không đổi).
//   • luật "không đoán bigram sau một từ" (Phil 16/10/2026) giữ nguyên, trừ: seed curated, và
//     cặp người dùng ĐÃ GÕ ≥ `learnedPairMin` (= SuggestRank.learnedTriMin = 2) lần — cùng ngữ
//     nghĩa "bộ ba gõ ≥ 2 lần được dẫn đầu" của iOS, áp cho cặp (prev → từ) của chính người dùng.
//
//   • hoa/thường đã học (10/2026): CaseTable (UserLMTables.swift) — dạng người dùng NHẤT QUÁN viết
//     GIỮA CÂU ("SenPrints", tên "Văn": ≥ 3 lần và ≥ 80% số lần giữa câu); đầu câu / Caps Lock /
//     chuỗi tên riêng (việt → Nam) không tính. Gợi ý hiện dạng đó (DisplayCase.resolve). Lưu chung
//     learned-words.bin (VTL2 flags bit 0 — không có dữ liệu hoa/thường ⇒ byte y như cũ).
//
// RIÊNG TƯ: chỉ đếm tần suất (không câu, không thứ tự, không thời điểm per-từ); file nhỏ trên
// máy (macOS ~/Library/Application Support/<bundle id>/learned-words.bin, Linux
// $XDG_DATA_HOME/viettelex/learned-words.bin, Windows %LOCALAPPDATA%\VietTelex\learned-words.bin),
// KHÔNG mạng, KHÔNG iCloud. Từ nhạy cảm vẫn được đếm nhưng bị lọc lúc GỢI Ý (như iOS) theo
// "Lọc từ nhạy cảm".
//
// KHÔNG thread-safe: mỗi nền tảng dùng trên đúng một hàng đợi (macOS: hàng đợi nền CaretHint;
// Linux: thread của `--serve`).
import Foundation

final class LearnedModel {
    static let uniCap = 3000
    static let biCap = 6000
    static let triCap = 3000
    /// Từ ngoài lexicon: đạt chừng này lượt mới được gợi ý (vẫn đếm từ lần đầu).
    static let unknownSuggestThreshold = 3
    /// Cặp (prev → từ) / bộ ba người dùng đã gõ ≥ chừng này lần ⇒ được gợi ý từ kế tiếp dù
    /// không có seed (= SuggestRank.learnedTriMin).
    static let learnedPairMin = 2
    static let maxWordLength = 12
    /// Tên file trong thư mục dữ liệu của app (định dạng VTL2 — UserLMCodec, danh sách thêm tay rỗng).
    static let fileName = "learned-words.bin"

    private(set) var t = UserLMTables()
    private(set) var cases = CaseTable()
    private(set) var lastDecay: Date
    /// Lexicon tĩnh (VNSuggest.contains) — từ trong lexicon được gợi ý ngay.
    let isKnownWord: (String) -> Bool
    private var knownCache: [String: Bool] = [:]
    /// Số lần đổi kể từ lần `markSaved()` — store chỉ ghi khi > 0.
    private(set) var changes = 0

    init(isKnownWord: @escaping (String) -> Bool = { _ in false }, now: Date = Date()) {
        self.isKnownWord = isKnownWord
        lastDecay = now
    }

    var isEmpty: Bool { t.uniN == 0 && t.biN == 0 && t.triN == 0 && cases.isEmpty }
    var wordCount: Int { t.uniN }
    var pairCount: Int { t.biN }
    var tripleCount: Int { t.triN }

    // MARK: học

    /// = UserLangModel.learnable.
    static func learnable(_ w: String) -> Bool {
        guard !w.isEmpty, w.count <= maxWordLength, w.allSatisfy({ $0.isLetter }) else { return false }
        var run = 1
        var prev: Character?
        for c in w {
            run = (c == prev) ? run + 1 : 1
            if run >= 3 { return false }
            prev = c
        }
        return true
    }

    /// Một từ vừa chốt (khoá chữ thường). O(log n) + chèn vào bucket; prune hiếm (khi đầy).
    /// `caseEvidence`: `word` mang đúng hoa/thường đã gõ và là bằng chứng GIỮA CÂU
    /// (`DisplayCase.casingEvidence`) ⇒ đếm vào bảng hoa/thường (trước khi tăng unigram).
    func record(word: String, after prev1: String?, prev2: String? = nil, weight: Int = 1,
                caseEvidence: Bool = false) {
        guard weight > 0, Self.learnable(word) else { return }
        let w = word.lowercased()
        let wid = t.intern(w)
        if caseEvidence {
            cases.observe(word.precomposedStringWithCanonicalMapping, key: w, priorCount: t.uni(wid))
        }
        t.setUni(wid, t.uni(wid) + weight)
        if let p1 = prev1?.lowercased(), Self.learnable(p1) {
            let pid = t.intern(p1)
            t.addBi(pid, wid, weight)
            if let p2 = prev2?.lowercased(), Self.learnable(p2),
               let p2id = t.ids[p2], t.biCount(p2id, pid) >= 2 {
                t.addTri(UserLMTables.ctx(p2id, pid), wid, weight)
            }
        }
        pruneIfNeeded()
        changes += 1
    }

    // MARK: tra

    /// Dạng hoa/thường người dùng hay viết (`key` chữ thường); nil = chưa đủ nhất quán.
    func learnedCase(_ key: String) -> String? {
        cases.isEmpty ? nil : cases.preferred(key)
    }

    func count(_ w: String) -> Int {
        let c = t.uni(w)
        return c > 0 ? c : t.uni(w.lowercased())
    }

    func bigramCount(_ prev: String, _ word: String) -> Int {
        guard let p = t.ids[prev.lowercased()], let w = t.ids[word.lowercased()] else { return 0 }
        return t.biCount(p, w)
    }

    func trigramCount(_ prev2: String, _ prev: String, _ word: String) -> Int {
        guard let a = t.ids[prev2.lowercased()], let b = t.ids[prev.lowercased()],
              let s = t.triIdx[UserLMTables.ctx(a, b)], let w = t.ids[word.lowercased()] else { return 0 }
        return t.triCount(Int(s), w)
    }

    private func cachedKnown(_ w: String) -> Bool {
        if let v = knownCache[w] { return v }
        if knownCache.count > 4096 { knownCache.removeAll() }
        let v = isKnownWord(w)
        knownCache[w] = v
        return v
    }

    /// Được phép XUẤT HIỆN trong gợi ý chưa (learning vs suggesting).
    func suggestable(_ w: String) -> Bool {
        cachedKnown(w) || t.uni(w) >= Self.unknownSuggestThreshold
    }

    /// Từ kế tiếp sau (prev2, prev1) = UserLangModel.nextWords với `seeds` = dòng SeedNextData của
    /// prev1. `pairMin` > 0 ⇒ ứng viên chỉ đến từ dữ liệu học khi cặp (prev1 → từ) ≥ pairMin hoặc
    /// bộ ba ≥ learnedPairMin (luật "không đoán bigram sau một từ"); seed luôn được. 0 = không chặn
    /// (ngữ cảnh +4 của hoàn thành từ, như iOS `Set(nextWords(limit: 24))`).
    func nextWords(after prev1: String, prev2: String? = nil, seeds: [String], limit: Int,
                   pairMin: Int = LearnedModel.learnedPairMin) -> [String] {
        let p1 = prev1.lowercased()
        let pid = t.ids[p1]
        let biBucket = pid.map { t.biB[Int($0)] } ?? []
        var triBucket: ContiguousArray<UInt64> = []
        if let pid, let p2 = prev2, let p2id = t.ids[p2.lowercased()],
           let slot = t.triIdx[UserLMTables.ctx(p2id, pid)] {
            triBucket = t.triB[Int(slot)]
        }
        var biTotal = 0, triTotal = 0
        for e in biBucket { biTotal += UserLMTables.cnt(e) }
        for e in triBucket { triTotal += UserLMTables.cnt(e) }
        let uniTotal = max(t.uniTotal, 1)
        let lamTri = Double(triTotal) / (Double(triTotal) + 2)
        let lamBi = Double(biTotal) / (Double(biTotal) + 4)

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

        // Chấm một lần mỗi ứng viên, giữ top `limit` bằng chèn (limit ≤ 24) — điểm giảm, hoà theo
        // chữ tăng (= sort của UserLangModel.nextWords).
        var top: [(w: String, s: Double)] = []
        top.reserveCapacity(limit + 1)
        for c in cands {
            var seed = -1
            for (k, s) in seeds.enumerated() where s == c.w { seed = k; break }
            if seed < 0 {
                if pairMin > 0, c.bc < pairMin, c.tc < Self.learnedPairMin { continue }
                if !suggestable(c.w) { continue }
            }
            var pSeed = 0.0
            if seed >= 0 {
                pSeed = 1
                for _ in 0..<seed { pSeed *= 0.5 }
            }
            let pTri = triTotal > 0 ? Double(c.tc) / Double(triTotal) : 0
            let pBi = biTotal > 0 ? Double(c.bc) / Double(biTotal) : 0
            let pUni = Double(t.uni(c.w)) / Double(uniTotal)
            let sc = lamTri * pTri + lamBi * pBi + 0.1 * pUni + (1 - lamBi) * 0.9 * pSeed
            var j = top.count
            while j > 0, top[j - 1].s < sc || (top[j - 1].s == sc && top[j - 1].w > c.w) { j -= 1 }
            if j < limit {
                top.insert((c.w, sc), at: j)
                if top.count > limit { top.removeLast() }
            }
        }
        return top.map { $0.w }
    }

    // MARK: decay / prune / xoá

    /// Mỗi ≥ 7 ngày: count *= 0,7^tuần (gọi lúc nạp).
    func decayIfDue(now: Date = Date()) {
        let weeks = Int(now.timeIntervalSince(lastDecay) / (7 * 86400))
        guard weeks >= 1 else { return }
        var f = 1.0
        for _ in 0..<min(weeks, 64) { f *= 0.7 }
        scale(uni: true, bi: true, tri: true, by: f)
        lastDecay = now
        changes += 1
    }

    /// Quá trần cứng: chia đôi mọi count của bảng đó (Int(c·0,5) = c/2 như iOS).
    private func pruneIfNeeded() {
        let u = t.uniN > Self.uniCap, b = t.biN > Self.biCap, r = t.triN > Self.triCap
        guard u || b || r else { return }
        scale(uni: u, bi: b, tri: r, by: 0.5)
    }

    private func scale(uni: Bool, bi: Bool, tri: Bool, by f: Double) {
        t.mapCounts(uni: uni, bi: bi, tri: tri) { Int(Double($0) * f) }
        t.compact()
        if uni {                                  // từ rơi khỏi unigram ⇒ bỏ hoa/thường của nó
            let tt = t
            cases.retain { tt.uni($0) > 0 }
        }
    }

    /// "Xoá từ đã học".
    func clear(now: Date = Date()) {
        t = UserLMTables()
        cases = CaseTable()
        knownCache.removeAll()
        lastDecay = now
        changes += 1
    }

    // MARK: lưu (VTL2 — UserLMCodec, chung iOS/Android/Windows)

    struct Snapshot {
        let tables: UserLMTables
        let lastDecay: Date
        var cases = CaseTable()
        func encoded() -> Data { UserLMCodec.encode(tables, lastDecay: lastDecay, manual: [], cases: cases) }
    }

    /// Bản chụp COW (rẻ — tăng refcount mảng); encode + ghi ở thread khác.
    func snapshot() -> Snapshot { Snapshot(tables: t, lastDecay: lastDecay, cases: cases) }
    func markSaved() { changes = 0 }

    /// Nạp từ dữ liệu file; nil = hỏng / sai định dạng (gọi nơi dựng mô hình rỗng thay thế).
    static func decode(_ data: Data, isKnownWord: @escaping (String) -> Bool = { _ in false }) -> LearnedModel? {
        guard let d = UserLMCodec.decode(data) else { return nil }
        let m = LearnedModel(isKnownWord: isKnownWord, now: d.lastDecay)
        m.t = d.tables
        m.cases = d.cases
        return m
    }

    /// Đọc file (thiếu / hỏng ⇒ mô hình rỗng — file hỏng bị ghi đè ở lần lưu kế) rồi decay.
    /// `recovered` = có file nhưng không đọc được.
    static func load(from url: URL, isKnownWord: @escaping (String) -> Bool = { _ in false },
                     now: Date = Date()) -> (model: LearnedModel, recovered: Bool) {
        guard let data = try? Data(contentsOf: url) else { return (LearnedModel(isKnownWord: isKnownWord, now: now), false) }
        guard let m = decode(data, isKnownWord: isKnownWord) else {
            return (LearnedModel(isKnownWord: isKnownWord, now: now), true)
        }
        m.decayIfDue(now: now)
        return (m, false)
    }

    /// Ghi nguyên tử (file tạm + rename): đứt giữa chừng ⇒ file cũ còn nguyên.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }

    static func removeFile(at url: URL) { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Theo dõi từ đã chốt (logic thuần, mỗi ô / controller một bản)

/// Biến dòng "từ vừa chốt ở ranh giới" của bộ gõ thành lượt học (từ, prev1, prev2, trọng số).
/// Ngữ cảnh = tối đa 2 từ trước trong CÙNG câu, cách nhau đúng một dấu cách (như
/// PredictionLogic.request); dấu câu / xuống dòng / dời con trỏ cắt ngữ cảnh.
/// Mỗi từ được GIỮ CHỜ tới sự kiện kế tiếp rồi mới học: ⌫ ngay sau ranh giới (sửa lại từ) hay
/// gợi ý thay chữ vừa chốt ⇒ bỏ (không học dạng sai); nhận gợi ý sửa lỗi gõ ⇒ học dạng đã sửa.
struct LearnTracker {
    struct Event: Equatable {
        var word: String
        var prev1: String?
        var prev2: String?
        var weight: Int
        /// Đúng hoa/thường đã gõ (NFC) — bảng hoa/thường đã học; `word` là khoá chữ thường.
        var form: String = ""
        /// `form` là bằng chứng hoa/thường GIỮA CÂU (có prev1 — đầu câu/dấu câu đã cắt ngữ cảnh —
        /// và không do chuỗi tên riêng, DisplayCase.casingEvidence).
        var caseEvidence: Bool { prev1 != nil && DisplayCase.casingEvidence(form, prev: prev1) }
    }

    private(set) var prev1: String?
    private(set) var prev2: String?
    private(set) var pending: Event?

    /// Từ `word` (bộ gõ tự soạn) vừa chốt bởi `boundary` (ký tự vừa gõ: " ", ",", "."…).
    /// `standsAlone` = từ đứng riêng (đầu văn bản mình biết / sau khoảng trắng — "a.b" không phải
    /// từ). Trả lượt học CHỜ trước đó (nếu có) để ghi ngay.
    mutating func commit(_ word: String, boundary: String, standsAlone: Bool = true, weight: Int = 1) -> Event? {
        let out = pending
        pending = nil
        let nfc = word.precomposedStringWithCanonicalMapping
        let w = nfc.lowercased()
        guard standsAlone, LearnedModel.learnable(w) else {
            prev1 = nil; prev2 = nil
            return out
        }
        pending = Event(word: w, prev1: prev1, prev2: prev2, weight: weight, form: nfc)
        if boundary == " " {
            prev2 = prev1; prev1 = w
        } else {
            prev1 = nil; prev2 = nil
        }
        return out
    }

    /// Gợi ý sửa lỗi gõ vừa được nhận: lượt chờ học dạng ĐÃ SỬA (cùng ngữ cảnh).
    mutating func replacePending(with fixed: String) {
        guard let p = pending else { return }
        let nfc = fixed.precomposedStringWithCanonicalMapping
        let f = nfc.lowercased()
        guard LearnedModel.learnable(f) else { discard(); return }
        pending?.word = f
        pending?.form = nfc
        if prev1 == p.word { prev1 = f }
    }

    /// ⌫ ngay sau ranh giới / chữ vừa chốt bị thay: bỏ lượt chờ, cắt ngữ cảnh.
    mutating func discard() {
        pending = nil; prev1 = nil; prev2 = nil
    }

    /// Enter / Tab / dời con trỏ / đổi ô: lượt chờ được học, ngữ cảnh cắt.
    mutating func breakContext() -> Event? {
        let out = pending
        pending = nil; prev1 = nil; prev2 = nil
        return out
    }
}
