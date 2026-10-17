// CuratedPairsTests.swift — cặp chọn tay (Scripts/curated-pairs.txt → CuratedPairs): Thêm dấu, bung
// dấu từ vuốt, sửa chung hai từ vuốt, xếp gợi ý đang gõ. Song sinh android CuratedPairsTests.kt.
// Câu/cặp Phil báo 18/10/2026.
import XCTest

final class CuratedPairsTests: XCTestCase {
    private func r(_ s: String, personal: AddTones.Personal? = nil) -> String {
        AddTones.restore(s, personal: personal).text
    }

    // MARK: Thêm dấu

    func testAddTonesPhilSentences() {
        XCTAssertEqual(r("Minh dang go tieng Viet khong dau."), "Mình đang gõ tiếng Việt không dấu.")
        XCTAssertEqual(r("Thu go tieng Viet khong dau xem sao."), "Thử gõ tiếng Việt không dấu xem sao.")
        XCTAssertEqual(r("tieng Viet co dau"), "tiếng Việt có dấu")
        XCTAssertEqual(r("bop vu"), "bóp vú")
        XCTAssertEqual(r("bop dai"), "bóp dái")
        XCTAssertEqual(r("leu bao"), "lều báo")
        XCTAssertEqual(r("go vuot tren ban phim"), "gõ vuốt trên bàn phím")
    }

    /// Ba cách đọc của "co dau": đứng một mình = cô dâu (vnlm.bin: PMI cô→dâu +4,5 trội hẳn), ngữ cảnh
    /// gõ/chữ = có dấu, chat "làm gì …" = có đâu.
    func testCoDauThreeReadings() {
        // đứng một mình: vnlm.bin hội thoại (18/10/2026) nghiêng "có dấu"; tần suất vnlexicon corpus hội thoại
        // (giai đoạn 2, cùng ngày) đưa về lại "cô dâu" — Phil quyết
        XCTAssertEqual(r("co dau"), "cô dâu")
        XCTAssertEqual(r("co dau chu re"), "cô dâu chú rể")
        XCTAssertEqual(r("tieng Viet co dau"), "tiếng Việt có dấu")
        XCTAssertEqual(r("lam gi co dau"), "làm gì có đâu")
    }

    /// Cặp chọn tay không lật câu thường (các cặp đã bỏ khỏi danh sách vì lý do này).
    func testNoCollateralFlips() {
        XCTAssertEqual(r("xin so dien thoai"), "xin số điện thoại")
        XCTAssertEqual(r("di qua dinh nui"), "đi qua đỉnh núi")
        XCTAssertEqual(r("co hoi viec lam"), "cơ hội việc làm")
        XCTAssertEqual(r("them dau tu"), "thêm đầu tư")
        XCTAssertEqual(r("anh di dau day"), "anh đi đâu đấy")
    }

    /// Người dùng thắng: đã gõ "không đâu" ≥ curatedYield lần ⇒ bảng tắt ở vị trí đó.
    func testUserHabitBeatsCuratedPair() {
        let s = "tieng Viet khong dau"
        XCTAssertTrue(r(s).hasSuffix("không dấu"))
        let pers = AddTones.Personal(count: { _ in 0 }, pair: { a, b in a == "không" && b == "đâu" ? 3 : 0 })
        XCTAssertTrue(r(s, personal: pers).hasSuffix("không đâu"), r(s, personal: pers))
        let few = AddTones.Personal(count: { _ in 0 }, pair: { a, b in a == "không" && b == "đâu" ? 2 : 0 })
        XCTAssertTrue(r(s, personal: few).hasSuffix("không dấu"))
    }

    func testCuratedOffIsOldBehaviour() {
        var p = AddTones.Params(); p.curated = false
        // vnlm.bin hội thoại (18/10/2026) tự ra "bóp vú" ⇒ khoá bằng cặp còn cần bảng
        XCTAssertEqual(AddTones.restore("bop dai", p).text, "bóp dài")
    }

    // MARK: bảng

    func testTableLookups() {
        XCTAssertTrue(CuratedPairs.has(nil, "bóp", "vú"))
        XCTAssertFalse(CuratedPairs.has(nil, "không", "dấu"), "chỉ trong ngữ cảnh")
        XCTAssertTrue(CuratedPairs.has("việt", "không", "dấu"))
        XCTAssertFalse(CuratedPairs.has(nil, "cô", "dâu"), "chỉ cho vuốt")
        XCTAssertTrue(CuratedPairs.swipe(nil, "cô", "dâu"))
        XCTAssertEqual(CuratedPairs.next(after: "Việt", prev2: "tiếng"), [])
        XCTAssertEqual(CuratedPairs.next(after: "có", prev2: "Việt"), ["dấu"])
        XCTAssertEqual(CuratedPairs.next(after: "có", prev2: "gì"), ["đâu"])
        XCTAssertEqual(CuratedPairs.next(after: "có", prev2: nil), [], "sau \"có\" không thêm \"dấu\"")
        XCTAssertEqual(CuratedPairs.withNext(["a"], after: "bóp", prev2: nil), ["a", "dái", "vú"])
        XCTAssertEqual(CuratedPairs.withNext(["a"], after: nil, prev2: nil), ["a"])
        for k in CuratedPairs.pairs.union(CuratedPairs.triples).union(CuratedPairs.nextOnly) {
            XCTAssertEqual(k, k.lowercased().precomposedStringWithCanonicalMapping)
        }
    }

    /// Không phải seed từ kế tiếp: UserLangModel (mồi seed) không gợi "dấu" sau "có".
    func testNotANextWordSeed() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        XCTAssertFalse(m.nextWords(after: "có", limit: 6).contains("dấu"))
        XCTAssertFalse(m.nextWords(after: "bóp", limit: 6).contains("vú"))
    }

    // MARK: vuốt (phần thuần: bung dấu theo ngữ cảnh + sửa chung hai từ)

    /// Người dùng mới (chỉ seed) — = KeyboardViewController.swipeEnded: next = nextWords(24) + chọn tay.
    private static let seeded: UserLangModel = {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        return m
    }()

    private func ctx(prev: String?, prev2: String? = nil, curated: Bool = true) -> SwipeTyping.Context {
        let m = Self.seeded
        let personal = prev.map { m.nextWords(after: $0, prev2: prev2, limit: 24) } ?? []
        // Context tự cộng CuratedPairs.next(prev2, prev) — tắt bằng cách bỏ prev khỏi khoá tra (chỉ mốc đo)
        return SwipeTyping.Context(next: Set(personal.map { $0.lowercased() }), count: { m.count(of: $0) },
                                   prev: prev, prev2: prev2, lm: SyllableLM.shared, curated: curated)
    }

    private func swipe(_ folded: String, prev: String?, prev2: String? = nil, curated: Bool = true) -> String? {
        SwipeTyping.pick([folded], context: ctx(prev: prev, prev2: prev2, curated: curated), case: .lower)?.word
    }

    func testSwipeExpansionInContext() {
        XCTAssertNotNil(SyllableLM.shared)
        XCTAssertEqual(swipe("dau", prev: "cô"), "dâu", "gõ \"cô\" rồi vuốt \"dau\"")
        XCTAssertEqual(swipe("dau", prev: "có", prev2: "việt"), "dấu", "tiếng Việt có dấu")
        XCTAssertEqual(swipe("dau", prev: "không", prev2: "việt"), "dấu", "tiếng Việt không dấu")
        XCTAssertEqual(swipe("dau", prev: "có", prev2: "gì"), "đâu", "làm gì có đâu")
        XCTAssertEqual(swipe("vu", prev: "bóp"), "vú")
        XCTAssertEqual(swipe("dai", prev: "bóp"), "dái")
        XCTAssertEqual(swipe("cu", prev: "sờ"), "cu")
        XCTAssertEqual(swipe("cu", prev: "mò"), "cu")
        XCTAssertEqual(swipe("bao", prev: "lều"), "báo")
        // không ngữ cảnh chọn tay ⇒ như cũ
        print("SWIPE trước/sau: cô+dau \(swipe("dau", prev: "cô", curated: false) ?? "-")→\(swipe("dau", prev: "cô") ?? "-"), "
              + "bóp+vu \(swipe("vu", prev: "bóp", curated: false) ?? "-")→\(swipe("vu", prev: "bóp") ?? "-"), "
              + "sờ+cu \(swipe("cu", prev: "sờ", curated: false) ?? "-")→\(swipe("cu", prev: "sờ") ?? "-"), "
              + "lều+bao \(swipe("bao", prev: "lều", curated: false) ?? "-")→\(swipe("bao", prev: "lều") ?? "-")")
    }

    /// Hai cú vuốt liền "co" "dau": từ trước được sửa chung theo cặp (có đâu → cô dâu).
    func testSwipeJointRevise() throws {
        func joint(_ first: String, _ second: String, prev: String? = nil) -> (String, String?) {
            let c0 = ctx(prev: prev)
            let scored = SwipeRevise.scored([SwipeCandidate(folded: first, score: 0)], context: c0.word,
                                            lambdaFreq: c0.lambdaFreq)
            let current = SwipeTyping.pick([first], context: c0, case: .lower)!.word
            let c1 = ctx(prev: current, prev2: prev)
            let next = SwipeRevise.nextPool([SwipeCandidate(folded: second, score: 0)], context: c1.word,
                                            lambdaFreq: c1.lambdaFreq)
            return (current, SwipeRevise.revise(scored, current: current, prev: prev, next: next))
        }
        let (cur, rev) = joint("co", "dau")
        XCTAssertEqual(rev ?? cur, "cô", "co dau → cô dâu (đang hiện \(cur))")
        // "so" "cu", "vai" "lon": ở đây ứng viên giả điểm 0 nên "sờ"/"vãi" không lọt top ứng viên của từ trước;
        // đường vuốt thật (android SwipeVocabTests, fixture swipe-vocab.tsv) ra "Sờ cu", "Vãi lồn".
    }

    /// Gợi ý đang gõ dở: sau "bóp", gõ "vu" ⇒ "vú" đứng đầu (ctx gồm từ chọn tay).
    func testInlineRankingUsesCuratedContext() {
        let pool = VNSuggest.matches("vu", poolLimit: 24, excluding: "vu")
        XCTAssertFalse(pool.isEmpty)
        let ctx = Set(CuratedPairs.withNext([], after: "bóp", prev2: nil))
        let pmi = SuggestRank.inlinePmi(pool, prev: "bóp")
        let ranked = SuggestRank.rankInline(pool, pmi: pmi, typedLen: 2, count: { _ in 0 }, ctx: ctx)
        XCTAssertEqual(ranked.first, "vú", "\(ranked.prefix(4))")
    }
}
