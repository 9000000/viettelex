// SuggestBigramTests.swift — bigram âm tiết tĩnh trên THANH GỢI Ý khi gõ chạm. Song sinh
// android SuggestBigramTests.kt (cùng ngưỡng). Đo trên câu Tatoeba GIỮ LẠI (bigram-heldout.txt)
// như người dùng MỚI (UserLangModel chỉ có seed, không học thêm): mỗi âm tiết có âm tiết trước,
// gõ đủ chữ KHÔNG DẤU.
//  - inline: slot1 = ứng viên chính khớp (chỉ tính âm tiết có dấu — không dấu đã nằm ở slot
//    nguyên văn); 3 slot = nguyên văn | ứng viên 1 | ứng viên 2, trên mọi âm tiết.
//  - từ kế tiếp: âm tiết đúng nằm trong 3 gợi ý sau dấu cách (chưa gõ gì).
import XCTest

final class SuggestBigramTests: XCTestCase {

    private func heldout() throws -> [[String]] {
        let url = try XCTUnwrap(Bundle(for: SuggestBigramTests.self)
            .url(forResource: "bigram-heldout", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: " ").map(String.init) }
    }

    private func seeded() -> UserLangModel {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        return m
    }

    private struct Acc {
        var nAcc = 0, top1 = 0, n = 0, top3 = 0, nNext = 0, next3 = 0
        var r1: Double { Double(top1) / Double(nAcc) }
        var r3: Double { Double(top3) / Double(n) }
        var rn: Double { Double(next3) / Double(nNext) }
        var fmt: String {
            String(format: "slot1 %.3f (n=%d) | 3 slot %.3f (n=%d) | từ kế tiếp top3 %.3f (n=%d)",
                   r1, nAcc, r3, n, rn, nNext)
        }
    }

    /// `useBigram` = false ⇒ như trước (không bigram tĩnh trên thanh gợi ý).
    private func measure(_ chains: [[String]], useBigram: Bool, learn: Bool = false) -> Acc {
        let m = seeded()
        let big = useBigram ? SyllableLM.shared : nil
        var a = Acc()
        for chain in chains {
            for i in 1..<chain.count {
                let w = chain[i], prev = chain[i - 1], prev2 = i >= 2 ? chain[i - 2] : nil
                let typed = SwipeTyping.fold(w)
                let pool = VNSuggest.matches(typed, poolLimit: 24, excluding: typed)
                let ctx = Set(m.nextWords(after: prev, prev2: prev2, limit: 24))
                let ranked = SensitiveWords.filter(SuggestRank.rankInline(
                    pool, pmi: SuggestRank.inlinePmi(pool, prev: prev, lm: big),
                    typedLen: typed.count, count: { m.count(of: $0) }, ctx: ctx), enabled: true)
                a.n += 1
                if w == typed || ranked.prefix(2).contains(w) { a.top3 += 1 }
                if w != typed { a.nAcc += 1; if ranked.first == w { a.top1 += 1 } }
                let personal = Array(SensitiveWords.filter(m.nextWords(after: prev, prev2: prev2, limit: 6),
                                                           enabled: true).prefix(3))
                let next = personal.count >= 3 || big == nil ? personal : SuggestionFill.pad(personal,
                    with: SensitiveWords.filter(SuggestRank.bigramNext(prev, limit: 6, lm: big), enabled: true),
                    need: 3)
                let slots = SuggestionFill.pad(next, with: SensitiveWords.filter(m.topWords(limit: 15), enabled: true),
                                               need: 3)
                a.nNext += 1
                if slots.contains(w) { a.next3 += 1 }
                if learn {
                    if i == 1 { m.record(word: prev, after: nil) }
                    m.record(word: w, after: prev, prev2: prev2)
                }
            }
        }
        return a
    }

    func testHeldoutNewUser() throws {
        try SlowTests.require()
        let chains = try heldout()
        let before = measure(chains, useBigram: false)
        let t0 = CFAbsoluteTimeGetCurrent()
        let after = measure(chains, useBigram: true)
        print("GỢI Ý CHẠM heldout iOS trước: \(before.fmt)")
        print("GỢI Ý CHẠM heldout iOS sau:   \(after.fmt) | "
            + String(format: "%.1f µs/âm tiết (Debug, cả nextWords + đo)",
                     (CFAbsoluteTimeGetCurrent() - t0) * 1e6 / Double(after.n)))
        // cùng ngưỡng Kotlin (đo 27/09/2026: slot1 0.747→0.829, 3 slot 0.880→0.938, kế tiếp 0.111→0.271)
        XCTAssertGreaterThanOrEqual(after.r1, 0.82, after.fmt)
        XCTAssertGreaterThanOrEqual(after.r3, 0.93, after.fmt)
        XCTAssertGreaterThanOrEqual(after.rn, 0.31, after.fmt)
        XCTAssertGreaterThanOrEqual(after.r1 - before.r1, 0.07)
        // 18/10/2026 seed từ corpus hội thoại: phần bigram thêm 0.16 → 0.10 (seed mạnh hơn) — xem bản Kotlin
        XCTAssertGreaterThanOrEqual(after.rn - before.rn, 0.09)
    }

    /// Người dùng đã gõ lâu (học dần từng từ): bigram không làm tụt, cá nhân vẫn dẫn.
    func testHeldoutLearningUserNotHurt() throws {
        try SlowTests.require()
        let chains = try heldout().enumerated().filter { $0.offset % 6 == 0 }.map(\.element)   // Debug chậm (Kotlin đo đủ)
        let before = measure(chains, useBigram: false, learn: true)
        let after = measure(chains, useBigram: true, learn: true)
        print("GỢI Ý CHẠM heldout iOS học dần trước: \(before.fmt) | sau: \(after.fmt)")
        XCTAssertGreaterThanOrEqual(after.r1, before.r1)
        XCTAssertGreaterThanOrEqual(after.r3, before.r3)
        XCTAssertGreaterThanOrEqual(after.rn, before.rn)
    }

    private func rank(_ prev: String, _ typed: String, _ m: UserLangModel? = nil) -> [String] {
        let m = m ?? seeded()
        let pool = VNSuggest.matches(typed, poolLimit: 24, excluding: typed)
        return SuggestRank.rankInline(pool, pmi: SuggestRank.inlinePmi(pool, prev: prev), typedLen: typed.count,
                                      count: { m.count(of: $0) }, ctx: Set(m.nextWords(after: prev, limit: 24)))
    }

    func testContextPicksDiacritics() {
        XCTAssertEqual(rank("đã", "bo").first, "bỏ")
        XCTAssertEqual(rank("bữa", "an").first, "ăn")
        XCTAssertEqual(rank("hình", "phat").first, "phạt")
        // (vnlm.bin thay vnbigram.bin 28/09/2026: "mọi giấc" bị cắt tỉa khỏi vnlm ⇒ đổi ví dụ)
        XCTAssertEqual(rank("bệnh", "vien").first, "viện")
        XCTAssertEqual(rank("thời", "tiet").first, "tiết")
        XCTAssertEqual(rank("vào", "thang").first, "tháng")
        // không âm tiết trước / âm tiết lạ ⇒ như cũ (tần suất + seed)
        let m = seeded()
        let pool = VNSuggest.matches("bo", poolLimit: 24, excluding: "bo")
        XCTAssertEqual(SuggestRank.rankInline(pool, pmi: nil, typedLen: 2, count: { m.count(of: $0) }, ctx: []),
                       SuggestRank.rankInline(pool, pmi: SuggestRank.inlinePmi(pool, prev: "hello"), typedLen: 2,
                                              count: { m.count(of: $0) }, ctx: []))
        XCTAssertNil(SuggestRank.inlinePmi(pool, prev: nil))
    }

    func testPersonalStillWins() {
        // bigram: "sao" + co → cô; user hay gõ "sao có" ⇒ nextWords cá nhân thắng
        XCTAssertEqual(rank("sao", "co").first, "cô")
        let m = seeded()
        for _ in 0..<3 { m.record(word: "có", after: "sao") }
        XCTAssertEqual(rank("sao", "co", m).first, "có")
    }

    func testNextWordFill() {
        XCTAssertEqual(SuggestRank.bigramNext("điện", limit: 3), ["thoại", "tử", "ảnh"])
        XCTAssertTrue(SuggestRank.bigramNext("máy", limit: 3).contains("bay"))
        XCTAssertTrue(SuggestRank.bigramNext("hello", limit: 3).isEmpty)
        XCTAssertTrue(SuggestRank.bigramNext("máy", limit: 0).isEmpty)
        XCTAssertEqual(SuggestRank.bigramNext("Điện", limit: 3), SuggestRank.bigramNext("điện", limit: 3))
    }

    func testLexiconIdMatchesSwipeLookup() {
        for w in ["hòa", "hoà", "Thuỷ", "quý", "nghiêng", "a", "đ", "hello", ""] {
            XCTAssertEqual(VNSuggest.lexiconId(of: w), SyllableLM.id(of: w), w)
        }
    }

    /// Độ trễ phần bigram thêm vào (inline chạy nền; từ kế tiếp trên main) + RAM bẩn của bảng.
    func testLatencyAndDirtyMemory() throws {
        try SlowTests.require()
        let chains = try heldout()
        let pairs = chains.flatMap { c in (1..<c.count).map { (c[$0 - 1], SwipeTyping.fold(c[$0])) } }
        let pools = pairs.map { VNSuggest.matches($0.1, poolLimit: 24, excluding: $0.1) }
        _ = SyllableLM.shared
        var t = CFAbsoluteTimeGetCurrent()
        for i in pairs.indices { _ = SuggestRank.inlinePmi(pools[i], prev: pairs[i].0) }
        let inline = (CFAbsoluteTimeGetCurrent() - t) * 1e6 / Double(pairs.count)
        t = CFAbsoluteTimeGetCurrent()
        for i in pairs.indices { _ = SuggestRank.bigramNext(pairs[i].0, limit: 6) }
        let next = (CFAbsoluteTimeGetCurrent() - t) * 1e6 / Double(pairs.count)

        // RAM bẩn: map một bản MỚI (như shared) rồi tra toàn bảng bigram — phys_footprint không
        // được tăng đáng kể (trang file-backed sạch, không giải mã vào heap).
        let url = try XCTUnwrap(Bundle(for: SuggestBigramTests.self).url(forResource: "vnlm", withExtension: "bin"))
        let m0 = Self.footprint()
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        let big = try XCTUnwrap(SyllableLM.load(d, lexiconHash: SyllableLM.fnv1a(VNLexicon2Data.blob),
                                               lexiconCount: VNLexicon2Data.count))
        var sink: Float = 0
        for p in 0..<big.count { big.bigram(p).forEach { _, s in sink += s } }
        let dirty = Double(Self.footprint() - m0) / 1024
        print(String(format: "GỢI Ý CHẠM iOS (Debug sim): PMI pool %.1f µs | bigramNext %.1f µs | "
            + "RAM bẩn sau map + duyệt toàn bảng %.0f KB (file %d KB) sink=%.0f",
                     inline, next, dirty, d.count / 1024, sink))
        XCTAssertLessThan(inline, 500)
        XCTAssertLessThan(next, 500)
        XCTAssertLessThan(dirty, 256, "bảng phải đọc tại chỗ (mmap), không copy vào heap")
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
