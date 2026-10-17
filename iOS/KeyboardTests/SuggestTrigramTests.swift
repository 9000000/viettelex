// SuggestTrigramTests.swift — TRIGRAM vnlm.bin trên thanh gợi ý. Song sinh android
// SuggestTrigramTests.kt (tham số chọn ở đó trên tập DEV suggest-dev.txt; fixture parity
// suggest-trigram-parity.txt do Kotlin sinh, ở đây khớp từng dòng). Đo trên tập kiểm thử
// bigram-heldout.txt: từ kế tiếp top-1 / top-3, slot1 / 3 slot khi gõ đủ chữ không dấu, ước lượng
// phím tiết kiệm (Telex: chữ không dấu + phím dấu/mũ/móc, đ = 2, + dấu cách; chạm chip từ kế
// tiếp = 1, ứng viên 1–2 sau tiền tố k chữ = k + 1).
import XCTest

final class SuggestTrigramTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: SuggestTrigramTests.self).url(forResource: name, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func chains(_ name: String) throws -> [[String]] {
        try fixture(name).filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.split(separator: " ").map(String.init) }
    }

    private func seeded() -> UserLangModel {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        return m
    }

    private let lm = SyllableLM.shared!
    private func id(_ w: String) -> Int { SyllableLM.id(of: w) ?? -1 }

    /// Trước 28/09/2026: chỉ bigram, tham số inline cũ.
    private let before = SuggestRank.Params(bigramWeight: 2.5, bigramCap: 8, bigramDamp: 0.45, useTrigram: false)

    func testForEachNextMatchesScore() throws {
        var checked = 0, withTri = 0
        for (a, b) in [("thành", "phố"), ("cảm", "ơn"), ("hôm", "nay"), ("tôi", "không"), ("việt", "nam"),
                       ("hello", "bạn"), ("của", "tôi"), ("là", "một")] {
            guard let ctx = lm.context(prev2: id(a), prev1: id(b)) else { continue }
            if ctx.hasTrigram { withTri += 1 }
            var seen = Set<Int>(), last = -1
            ctx.forEachNext { c, pmi in
                XCTAssertGreaterThan(c, last); last = c; seen.insert(c)
                XCTAssertEqual(pmi, ctx.score(c) + lm.uniAdj(c), accuracy: 1e-5, "\(a) \(b) → \(c)")
                checked += 1
            }
            var bi = Set<Int>()
            lm.bigram(id(b)).forEach { c, _ in bi.insert(c) }
            XCTAssertTrue(seen.isSuperset(of: bi))
            if !ctx.hasTrigram { XCTAssertEqual(bi, seen) }
            let ids = Array(stride(from: 0, to: lm.count, by: 7))
            let all = ctx.explicitAll(ids)
            // pool thật (≤ 64 id, lộn xộn, có trùng / -1) ⇒ đường đi song song dòng trigram
            let pool = Array(seen.sorted().reversed().prefix(40)) + [-1, ids[3], ids[3]] + Array(ids.prefix(12))
            let allPool = ctx.explicitAll(pool)
            for (i, w) in pool.enumerated() { XCTAssertEqual(allPool[i], ctx.explicit(w), "\(a) \(b) pool \(w)") }
            for (i, c) in ids.enumerated() {
                let e = ctx.explicit(c)
                XCTAssertEqual(all[i], e)
                if !seen.contains(c) { XCTAssertEqual(e, 0) }
                else if !bi.contains(c) { XCTAssertEqual(e, ctx.score(c) + lm.uniAdj(c), accuracy: 1e-5) }
            }
        }
        XCTAssertTrue(checked > 1000 && withTri >= 6, "checked=\(checked) withTri=\(withTri)")
        XCTAssertEqual(lm.bigram(id("nay")).explicit(id("tôi")), lm.context(prev2: -1, prev1: id("nay"))!.explicit(id("tôi")))
    }

    func testTrigramExamples() {
        XCTAssertEqual(SuggestRank.contextNext("không", prev2: "tôi", limit: 3), ["biết", "thể", "muốn"])   // vnlm hội thoại 18/10/2026 (trước: biết, muốn, nghĩ)
        XCTAssertEqual(SuggestRank.contextNext("có", prev2: "bạn", limit: 3).first, "thể")
        XCTAssertEqual(SuggestRank.contextNext("mừng", prev2: "chúc", limit: 3).first, "sinh")   // vnlm hội thoại 18/10/2026 (trước: giáng)
        XCTAssertEqual(SuggestRank.contextNext("điện", prev2: "hello", limit: 3), SuggestRank.bigramNext("điện", limit: 3))
        XCTAssertEqual(SuggestRank.contextNext("điện", prev2: nil, limit: 3), SuggestRank.bigramNext("điện", limit: 3))
        XCTAssertTrue(SuggestRank.contextNext("hello", prev2: "tôi", limit: 3).isEmpty)
    }

    func testNextFillKeepsLearnedTrigramFirst() {
        let m = seeded()
        func personal() -> [String] { SensitiveWords.filter(m.nextWords(after: "không", prev2: "tôi", limit: 6), enabled: true) }
        let tc = { (w: String) in m.trigramCount("tôi", "không", w) }
        XCTAssertEqual(SuggestRank.nextFill("không", prev2: "tôi", personal: personal(), triCount: tc), ["biết", "thể", "muốn"])
        for _ in 0..<3 { m.record(word: "tôi", after: nil); m.record(word: "không", after: "tôi"); m.record(word: "đi", after: "không", prev2: "tôi") }
        XCTAssertEqual(SuggestRank.nextFill("không", prev2: "tôi", personal: personal(), triCount: tc), ["đi", "biết", "thể"])
        let p1 = SensitiveWords.filter(m.nextWords(after: "không", limit: 6), enabled: true)
        XCTAssertEqual(SuggestRank.nextFill("không", prev2: nil, personal: p1, triCount: { _ in 0 }), Array(p1.prefix(3)))
    }

    /// Cùng số với Kotlin: top-6 contextNext (N) + PMI inline ×16 (I) trên ngữ cảnh heldout.
    func testParityFixture() throws {
        var n = 0
        for line in try fixture("suggest-trigram-parity") where !line.hasPrefix("#") && !line.isEmpty {
            let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let a = f[1], b = f[2]
            if f[0] == "N" {
                XCTAssertEqual(SuggestRank.contextNext(b, prev2: a, limit: 6).joined(separator: ","), f.count > 3 ? f[3] : "", line)
            } else {
                let typed = f[3]
                let pool = VNSuggest.matches(typed, poolLimit: 24, excluding: typed)
                let pmi = SuggestRank.inlinePmi(pool, prev: b, prev2: a)
                let got = pool.indices.map { "\(pool[$0].word):\(Int(((pmi?[$0] ?? 0) * 16).rounded()))" }.joined(separator: ",")
                XCTAssertEqual(got, f.count > 4 ? f[4] : "", line)
            }
            n += 1
        }
        XCTAssertGreaterThan(n, 800)
    }

    // MARK: đo (chậm)

    private struct M {
        var n = 0, top1 = 0, top3 = 0, nAcc = 0, slot1 = 0, slot3 = 0, keys = 0, saved = 0
        var fmt: String {
            String(format: "kế tiếp top1 %.2f top3 %.2f | slot1 %.2f 3slot %.2f | phím tiết kiệm %.2f%% (n=%d)",
                   100.0 * Double(top1) / Double(n), 100.0 * Double(top3) / Double(n),
                   100.0 * Double(slot1) / Double(nAcc), 100.0 * Double(slot3) / Double(n),
                   100.0 * Double(saved) / Double(keys), n)
        }
    }

    private func cost(_ w: String) -> Int {
        w.decomposedStringWithCanonicalMapping.unicodeScalars.reduce(0) { $0 + ($1 == "đ" ? 2 : 1) }
    }

    private func nextSlots(_ m: UserLangModel, _ prev: String, _ prev2: String?, _ p: SuggestRank.Params) -> [String] {
        let personal = SensitiveWords.filter(m.nextWords(after: prev, prev2: prev2, limit: 6), enabled: true)
        let next = SuggestRank.nextFill(prev, prev2: prev2, personal: personal,
                                        triCount: { w in prev2.map { m.trigramCount($0, prev, w) } ?? 0 },
                                        filter: { SensitiveWords.filter($0, enabled: true) }, p)
        return SuggestionFill.pad(next, with: SensitiveWords.filter(m.topWords(limit: 15), enabled: true), need: 3)
    }

    private func ranked(_ m: UserLangModel, _ typed: String, _ prev: String, _ prev2: String?,
                        _ p: SuggestRank.Params) -> [String] {
        let pool = VNSuggest.matches(typed, poolLimit: 24, excluding: typed)
        let ctx = Set(m.nextWords(after: prev, prev2: prev2, limit: 24))
        return SensitiveWords.filter(SuggestRank.rankInline(pool, pmi: SuggestRank.inlinePmi(pool, prev: prev, prev2: prev2, p),
                                                            typedLen: typed.count, count: { m.count(of: $0) }, ctx: ctx, p),
                                     enabled: true)
    }

    private func eval(_ chains: [[String]], _ p: SuggestRank.Params = .init(), learn: Bool = false) -> M {
        let m = seeded()
        var r = M()
        for chain in chains {
            for i in 1..<chain.count {
                let w = chain[i], prev = chain[i - 1], prev2 = i >= 2 ? chain[i - 2] : nil
                let slots = nextSlots(m, prev, prev2, p)
                r.n += 1
                if slots.first == w { r.top1 += 1 }
                if slots.contains(w) { r.top3 += 1 }
                let typed = SwipeTyping.fold(w)
                let rk = ranked(m, typed, prev, prev2, p)
                if w == typed || rk.prefix(2).contains(w) { r.slot3 += 1 }
                if w != typed { r.nAcc += 1; if rk.first == w { r.slot1 += 1 } }
                let full = cost(w) + 1
                var spent = full
                if slots.contains(w) { spent = 1 } else {
                    for k in 1..<max(typed.count, 1) where ranked(m, String(typed.prefix(k)), prev, prev2, p).prefix(2).contains(w) {
                        spent = k + 1; break
                    }
                    if spent == full && w != typed && rk.prefix(2).contains(w) { spent = typed.count + 1 }
                }
                r.keys += full; r.saved += full - spent
                if learn {
                    if i == 1 { m.record(word: prev, after: nil) }
                    m.record(word: w, after: prev, prev2: prev2)
                }
            }
        }
        return r
    }

    func testHeldoutBeforeAfter() throws {
        try SlowTests.require()
        let test = try chains("bigram-heldout").enumerated().filter { $0.offset % 3 == 0 }.map(\.element)   // Debug chậm (Kotlin đo đủ)
        let b = eval(test, before), a = eval(test)
        let bl = eval(test, before, learn: true), al = eval(test, learn: true)
        print("GỢI Ý TRIGRAM iOS mới trước: \(b.fmt)\nGỢI Ý TRIGRAM iOS mới sau:   \(a.fmt)")
        print("GỢI Ý TRIGRAM iOS học trước: \(bl.fmt)\nGỢI Ý TRIGRAM iOS học sau:   \(al.fmt)")
        XCTAssertGreaterThanOrEqual(Double(a.top3 - b.top3), 0.05 * Double(a.n), a.fmt)
        XCTAssertGreaterThanOrEqual(Double(a.top1 - b.top1), 0.03 * Double(a.n), a.fmt)
        XCTAssertTrue(a.slot1 >= b.slot1 && a.slot3 >= b.slot3 && a.saved > b.saved, a.fmt)
        XCTAssertTrue(al.top3 > bl.top3 && al.slot1 >= bl.slot1 && al.slot3 >= bl.slot3 && al.saved > bl.saved, al.fmt)
    }

    /// Độ trễ: phần LM + cả lượt gợi ý (đang gõ: pool + PMI + xếp; sau dấu cách: nextWords + lấp + đệm).
    func testLatency() throws {
        try SlowTests.require()
        let ch = try chains("bigram-heldout")
        let ctx = ch.flatMap { c in (2..<max(c.count, 2)).map { (c[$0 - 2], c[$0 - 1], SwipeTyping.fold(c[$0])) } }
        let pools = ctx.map { VNSuggest.matches($0.2, poolLimit: 24, excluding: $0.2) }
        let m = seeded()
        // các cặp trước/sau đo XEN KẼ nhiều vòng, lấy min mỗi bên
        let bodies: [() -> Void] = [
            { for c in ctx { _ = SuggestRank.bigramNext(c.1, limit: 6) } },
            { for c in ctx { _ = SuggestRank.contextNext(c.1, prev2: c.0, limit: 6) } },
            { for i in ctx.indices { _ = SuggestRank.inlinePmi(pools[i], prev: ctx[i].1) } },
            { for i in ctx.indices { _ = SuggestRank.inlinePmi(pools[i], prev: ctx[i].1, prev2: ctx[i].0) } },
            // cả lượt như bàn phím: đang gõ (pool + PMI + xếp) / sau dấu cách (nextWords + lấp + đệm)
            { for c in ctx { _ = self.ranked(m, c.2, c.1, c.0, self.before) } },
            { for c in ctx { _ = self.ranked(m, c.2, c.1, c.0, .init()) } },
            { for c in ctx { _ = self.nextSlots(m, c.1, c.0, self.before) } },
            { for c in ctx { _ = self.nextSlots(m, c.1, c.0, .init()) } },
        ]
        var best = [Double](repeating: .greatestFiniteMagnitude, count: bodies.count)
        for r in 0..<4 {
            for (i, f) in bodies.enumerated() {
                let t = CFAbsoluteTimeGetCurrent(); f()
                if r > 0 { best[i] = min(best[i], (CFAbsoluteTimeGetCurrent() - t) * 1e6 / Double(ctx.count)) }
            }
        }
        let (bi, tri, pb, pt, ib, ia, nb, na) = (best[0], best[1], best[2], best[3], best[4], best[5], best[6], best[7])
        print(String(format: "GỢI Ý TRIGRAM iOS độ trễ (n=%d): top kế tiếp bigram %.1f → trigram %.1f µs (×%.2f) | "
            + "PMI pool %.1f → %.1f µs (×%.2f) | cả lượt đang gõ %.1f → %.1f µs (×%.2f) | sau dấu cách %.1f → %.1f µs (×%.2f)",
                     ctx.count, bi, tri, tri / bi, pb, pt, pt / pb, ib, ia, ia / ib, nb, na, na / nb))
        XCTAssertLessThan(ia, ib * 1.35)   // đo yên: ×1.08 (máy tải cao dao động tới ×1.4)
        XCTAssertLessThan(na, nb * 1.35)
    }
}
