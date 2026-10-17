// SwipePracticeTests.swift — Luyện vuốt (App/Practice/SwipePractice.swift). Song sinh android
// SwipePracticeTests.kt, cùng fixture swipe-traces-sample.json (Kotlin sinh; iOS phải parse
// và decode ra đúng top-K đã ghi).
import XCTest

final class SwipePracticeTests: XCTestCase {
    func testTargetsDeterministicMixedAndSwipeable() {
        let a = (0..<200).map { SwipePractice.target(seed: 42, $0) }
        XCTAssertEqual(a, (0..<200).map { SwipePractice.target(seed: 42, $0) })
        XCTAssertNotEqual(a, (0..<200).map { SwipePractice.target(seed: 43, $0) })
        let en = a.filter { $0.lang == .en }.count
        XCTAssertTrue((20...70).contains(en), "tiếng Anh \(en)/200")
        for t in a {
            XCTAssertGreaterThanOrEqual(SwipePractice.keyCount(t.folded), 2, t.word)
            if t.lang == .vi {
                XCTAssertEqual(SwipeLexicon.fold(t.word), t.folded)
                XCTAssertNotNil(SwipeLexicon.index(of: t.folded))
            } else {
                XCTAssertNil(SwipeLexicon.index(of: t.word), "không trùng dạng Việt: \(t.word)")
            }
        }
        // parity Kotlin SwipePracticeTests.PARITY_SEED_42
        XCTAssertEqual((0..<12).map { SwipePractice.target(seed: 42, $0).word },
                       ["lòng", "head", "tử", "dịch", "first", "tốt", "đấy", "đàn", "bỏ", "cách", "câu", "mạnh"])
        XCTAssertEqual(SwipePractice.vietnamese.count, 400)
        XCTAssertEqual(SwipePractice.english.count, 120)
    }

    /// GeometryReader đo lần đầu bề rộng 0 → trước đây SwipeLayout precondition crash (Phil 27/09).
    func testZeroWidthLayoutIsNilNotCrash() {
        XCTAssertNil(PracticeKeyboardGeometry.layout(width: 0))
        XCTAssertNil(PracticeKeyboardGeometry.layout(width: -1))
        XCTAssertNotNil(PracticeKeyboardGeometry.layout(width: 393))
    }

    func testGeometryMatchesKeyboardFormulas() throws {
        let w: CGFloat = 402
        let keys = Dictionary(uniqueKeysWithValues: PracticeKeyboardGeometry.keys(width: w).map { ($0.0, $0.1) })
        XCTAssertEqual(keys.count, 26)
        let p = PracticeKeyboardGeometry.pitch(width: w)
        XCTAssertEqual(p, KeyGeometry.letterPitch(width: w, margin: 6.5, gap: 6), accuracy: 1e-9)
        XCTAssertEqual(keys["q"]!.minX, 6.5, accuracy: 1e-9)
        XCTAssertEqual(keys["p"]!.maxX, w - 6.5, accuracy: 1e-6)
        XCTAssertEqual(keys["a"]!.midX - keys["q"]!.midX, p / 2, accuracy: 1e-6)   // hàng 2 thụt nửa bước
        XCTAssertEqual(keys["v"]!.midX, w / 2, accuracy: 1e-6)                    // hàng 3 căn giữa
        XCTAssertEqual(keys["z"]!.width, keys["q"]!.width, accuracy: 1e-9)
        XCTAssertEqual(keys["a"]!.midY - keys["q"]!.midY, 54, accuracy: 1e-9)
        XCTAssertEqual(keys["q"]!.height, 44, accuracy: 1e-9)
        let l = try XCTUnwrap(PracticeKeyboardGeometry.layout(width: w))
        XCTAssertEqual(l.keyWidth, Float(p), accuracy: 1e-5)
        // nét sạch trên bàn phím mẫu giải mã đúng
        let d = SwipeDecoder(); d.setLayout(l)
        var sim = SwipeSim(seed: 3)
        for word in ["viet", "khong", "nguoi", "meeting"] {
            let top = SwipePractice.decode(d, sim.path(word, l, sigma: 0.05), lang: word == "meeting" ? .en : .vi)
            XCTAssertEqual(top.first?.folded, word)
        }
    }

    private func sampleTrace(_ word: String, lang: SwipeLang) -> SwipeTrace {
        let l = SwipeLayout.qwerty(keyWidth: 36, rowHeight: 54)
        var sim = SwipeSim(seed: 11)
        let p = sim.path(SwipeLexicon.fold(word), l, sigma: 0.1)
        return SwipeTrace(target: word, folded: SwipeLexicon.fold(word), lang: lang, layout: l, path: p,
                          decoded: ["x"], time: 1_790_000_000_000)
    }

    func testJSONRoundTripAndGuards() throws {
        let t = sampleTrace("việt", lang: .vi)
        XCTAssertEqual(t.keys.count, 26)
        XCTAssertEqual(SwipePractice.parseLines(SwipePractice.line(t)), [t])
        let doc = SwipePractice.export([t, sampleTrace("meeting", lang: .en)], now: Date(timeIntervalSince1970: 0))
        let back = try XCTUnwrap(SwipePractice.parseExport(doc))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].language, .en)
        XCTAssertNil(SwipePractice.parseExport(Data(#"{"format":"khác","version":1,"platform":"x","exported":"","traces":[]}"#.utf8)))
        XCTAssertNil(SwipePractice.parseExport(Data(#"{"format":"viettelex-swipe-traces","version":9,"platform":"x","exported":"","traces":[]}"#.utf8)))
        XCTAssertNil(SwipePractice.parseExport(Data("không phải json".utf8)))
        let store = SwipePractice.line(t) + "\n{hỏng\n{\"target\":\"a\"}\n\n" + SwipePractice.line(t) + "\n"
        XCTAssertEqual(SwipePractice.parseLines(store).count, 2)
    }

    func testSampleFixtureParityWithKotlin() throws {
        let url = try XCTUnwrap(Bundle(for: SwipePracticeTests.self)
            .url(forResource: "swipe-traces-sample", withExtension: "json"))
        let traces = try XCTUnwrap(SwipePractice.parseExport(try Data(contentsOf: url)))
        XCTAssertEqual(traces.count, 8)
        let l = try XCTUnwrap(traces[0].layout)
        let d = SwipeDecoder(); d.setLayout(l)
        for t in traces {
            XCTAssertEqual(SwipePractice.decode(d, t.path(), lang: t.language).map(\.folded), t.decoded, t.target)
        }
        let r = SwipePractice.evaluate(traces)
        XCTAssertEqual(r.n, 8)
        XCTAssertEqual(r.top1, r.recorded)
        XCTAssertGreaterThanOrEqual(r.top1, 7)
    }
}
