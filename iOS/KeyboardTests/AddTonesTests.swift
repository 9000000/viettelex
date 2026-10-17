// AddTonesTests.swift — thêm dấu cho câu không dấu. Song sinh android AddTonesTests.kt.
// Đo trên câu Tatoeba GIỮ LẠI (bigram-heldout.txt — không nằm trong dữ liệu dựng
// vnlm.bin): bỏ dấu → khôi phục → tỉ lệ âm tiết đúng. Parity Kotlin qua add-tones.txt.
import XCTest

final class AddTonesTests: XCTestCase {
    /// Ba câu Phil thử trên macOS 18/10/2026 (số trong câu, vần iê/uô/ươ, "go" giữa câu) —
    /// chip Thêm dấu iOS phải thay CẢ câu.
    func testPhilSentencesFromMacFeedback() {
        let cases = ["Ngay mai minh se den truong hop lop cap 3.", "Thu go tieng Viet khong dau xem sao.",
                     "Minh dang go tieng Viet khong dau."]
        for c in cases {
            XCTAssertNotNil(AddTones.plan(c), c)
        }
    }

    private func fixture(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: AddTonesTests.self).url(forResource: name, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    private func heldout() throws -> [[String]] {
        try fixture("bigram-heldout").filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: " ").map(String.init) }
    }

    private func r(_ s: String) -> String { AddTones.restore(s).text }

    func testBasicSentences() {
        XCTAssertEqual(r("toi di hoc hom nay"), "tôi đi học hôm nay")
        XCTAssertEqual(r("khong co gi"), "không có gì")
        XCTAssertTrue(["cảm ơn bạn rất nhiều", "cám ơn bạn rất nhiều"].contains(r("cam on ban rat nhieu")))
    }

    func testKeepsCasePunctuationAndSpacing() {
        XCTAssertEqual(r("Toi di hoc, hom nay troi dep!"), "Tôi đi học, hôm nay trời đẹp!")
        XCTAssertEqual(r("TOI DI HOC"), "TÔI ĐI HỌC")
        XCTAssertEqual(r("  (toi)  di\thoc..."), "  (tôi)  đi\thọc...")
        let s = "toi di hoc hom nay"
        XCTAssertEqual(r(s).unicodeScalars.count, s.unicodeScalars.count)
    }

    func testKeepsNonVietnameseTokens() {
        XCTAssertEqual(r("toi mua iPhone 15 o shopee.vn"), "tôi mua iPhone 15 ở shopee.vn")
        XCTAssertEqual(r("gui mail cho abc@gmail.com nhe"), "gửi mail cho abc@gmail.com nhé")
        XCTAssertEqual(r("h2o 123 toi"), "h2o 123 tôi")
        XCTAssertEqual(r("xem movie tren netflix"), "xem movie trên netflix")
        XCTAssertTrue(r("toi thich the weekend").hasSuffix("the weekend"))
        XCTAssertEqual(r("toi 😀 di"), "tôi 😀 đi")
    }

    func testSegmentStopsAtDiacriticsAndNewline() {
        XCTAssertEqual(AddTones.segment("Tôi đi hoc hom nay "), "hoc hom nay ")
        XCTAssertEqual(AddTones.segment("dong 1\nhom nay"), "hom nay")
        XCTAssertEqual(AddTones.segment("toi di\n"), "")
        XCTAssertEqual(AddTones.segment(""), "")
        XCTAssertEqual(AddTones.segment("  toi di"), "toi di")
    }

    func testPlanIsMinimalTail() {
        XCTAssertEqual(AddTones.plan("Tôi viết: toi di hoc "), AddTones.Plan(original: "oi di hoc ", replacement: "ôi đi học "))
        XCTAssertNil(AddTones.plan("toi "), "1 âm tiết không mời")
        XCTAssertNil(AddTones.plan("anh em "), "đã đúng không mời")
        XCTAssertNil(AddTones.plan("the quick brown fox jumps over "), "câu tiếng Anh không mời")
        XCTAssertNil(AddTones.plan("Tôi đi học "))
    }

    func testMaxSyllablesCap() {
        let long = Array(repeating: "toi", count: 300).joined(separator: " ")
        XCTAssertEqual(AddTones.segment(long).split(separator: " ").count, AddTones.maxSyllables)
    }

    func testPersonalModelWins() {
        let pers = AddTones.Personal(count: { _ in 0 }, pair: { a, b in a == "con" && b == "ma" ? 40 : 0 })
        XCTAssertTrue(AddTones.restore("con ma nay", personal: pers).text.hasPrefix("con ma "))
    }

    /// Parity với Kotlin: cùng đầu vào ⇒ cùng kết quả (fixture sinh bởi bản Kotlin).
    func testSharedFixture() throws {
        var n = 0
        for l in try fixture("add-tones") where !l.isEmpty && !l.hasPrefix("#") {
            let parts = l.components(separatedBy: "\t")
            XCTAssertEqual(parts.count, 2, l)
            XCTAssertEqual(AddTones.restore(parts[0]).text, parts[1], "đầu vào: \(parts[0])")
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 40)
    }

    private func measure(_ chains: [[String]], lm: SyllableLM? = SyllableLM.shared) -> (n: Int, ok: Int, sOk: Int) {
        var n = 0, ok = 0, sOk = 0
        for c in chains {
            let folded = c.map { SwipeTyping.fold($0) }.joined(separator: " ")
            let out = AddTones.restore(folded, lm: lm).text.split(separator: " ").map(String.init)
            var all = true
            for i in c.indices { n += 1; if out[i] == c[i] { ok += 1 } else { all = false } }
            if all { sOk += 1 }
        }
        return (n, ok, sOk)
    }

    func testHeldoutAccuracy() throws {
        let chains = try heldout()
        let uni = measure(chains, lm: nil)
        let full = measure(chains)
        let ru = Double(uni.ok) / Double(uni.n), rf = Double(full.ok) / Double(full.n)
        print(String(format: "ADDTONES heldout iOS: chỉ unigram %.4f | + bigram %.4f (n=%d) | câu %.3f",
                     ru, rf, full.n, Double(full.sOk) / Double(chains.count)))
        // cùng ngưỡng với Kotlin (đo 27/09/2026: 0.7635 → 0.9463, câu 0.732; 28/09/2026 bigram
        // vnlm.bin: → 0.9556, câu 0.769)
        XCTAssertGreaterThanOrEqual(rf, 0.94)
        XCTAssertGreaterThanOrEqual(rf - ru, 0.15)
    }

    func testSpeed30Syllables() throws {
        let s = try heldout().flatMap { $0 }.prefix(30).map { SwipeTyping.fold($0) }.joined(separator: " ")
        for _ in 0..<5 { _ = AddTones.restore(s) }
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = AddTones.restore(s) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 20
        print(String(format: "ADDTONES 30 âm tiết iOS (Debug): %.2f ms", ms))
        XCTAssertLessThan(ms, 10)
    }
}
