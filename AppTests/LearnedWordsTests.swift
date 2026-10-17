import XCTest
@testable import VietTelex

/// "Học từ bạn gõ" (LearnedModel.swift / LearnedWords.swift): mô hình, xếp hạng với dữ liệu học,
/// lưu file + phục hồi khi hỏng, xoá, LearnTracker, và cổng học đầu-cuối qua handle().
final class LearnedWordsTests: XCTestCase {
    private func model() -> LearnedModel { LearnedModel(isKnownWord: { VNSuggest.contains($0) }) }

    /// Gõ `sentence` `times` lần (mỗi lần một câu riêng: ngữ cảnh 2 từ, cắt ở cuối câu).
    private func type(_ m: LearnedModel, _ sentence: String, times: Int = 1) {
        for _ in 0..<times {
            var tr = LearnTracker()
            for w in sentence.split(separator: " ") {
                if let e = tr.commit(String(w), boundary: " ") { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
            }
            if let e = tr.breakContext() { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
        }
    }

    private func next(_ before: String, _ m: LearnedModel?, filter: Bool = true, english: Bool = false) -> [String] {
        guard let r = PredictionLogic.request(before: before, typed: "", english: english) else { return [] }
        return PredictionModel.shared.candidates(r, raw: "", filterSensitive: filter, learned: m)
    }

    private func complete(_ before: String, typed: String, _ m: LearnedModel?) -> [String] {
        guard let r = PredictionLogic.request(before: before, typed: typed, english: false) else { return [] }
        return PredictionModel.shared.candidates(r, raw: typed, learned: m)
    }

    // MARK: mô hình (= UserLangModel iOS)

    func testRecordSemanticsMatchIOS() {
        let m = model()
        type(m, "cảm ơn bạn")
        XCTAssertEqual(m.count("ơn"), 1)
        XCTAssertEqual(m.bigramCount("cảm", "ơn"), 1)
        XCTAssertEqual(m.trigramCount("cảm", "ơn", "bạn"), 0, "bộ ba chỉ ghi khi cặp (p2, p1) đã ≥ 2")
        type(m, "cảm ơn bạn", times: 2)
        XCTAssertEqual(m.trigramCount("cảm", "ơn", "bạn"), 2)
        XCTAssertEqual(m.t.uniDict(), ["cảm": 3, "ơn": 3, "bạn": 3])
        XCTAssertEqual(m.t.biDict(), ["cảm": ["ơn": 3], "ơn": ["bạn": 3]])
        XCTAssertEqual(m.t.triDict(), ["cảm\u{1}ơn": ["bạn": 2]])
    }

    func testLearnableMatchesIOS() {
        // = UserLangModel.learnable: chữ cái thuần, ≤ 12, không chuỗi lặp ≥ 3.
        for (w, ok) in [("cơm", true), ("Phúc", true), ("keyboard", true), ("heey", true), ("heeey", false),
                        ("a1", false), ("", false), ("quáaaa", false), ("abcdefghijkl", true),
                        ("abcdefghijklm", false), ("e-mail", false)] {
            XCTAssertEqual(LearnedModel.learnable(w), ok, w)
        }
    }

    func testPruneHalvesWhenFull() {
        let m = model()
        for i in 0..<(LearnedModel.uniCap + 1) {
            // từ khác nhau, toàn chữ cái
            let w = String(i, radix: 26).map { c -> Character in
                let v = Int(String(c), radix: 26)!
                return Character(UnicodeScalar(97 + v)!)
            }
            m.record(word: "x" + String(w), after: nil)
        }
        XCTAssertLessThanOrEqual(m.wordCount, LearnedModel.uniCap, "vượt trần ⇒ chia đôi, count 1 rơi về 0")
    }

    func testDecayAfterTwoWeeks() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let m = LearnedModel(isKnownWord: { _ in true }, now: t0)
        for _ in 0..<10 { m.record(word: "cơm", after: "ăn") }
        m.decayIfDue(now: t0.addingTimeInterval(6 * 86400))
        XCTAssertEqual(m.count("cơm"), 10, "chưa đủ một tuần")
        m.decayIfDue(now: t0.addingTimeInterval(14 * 86400 + 1))
        XCTAssertEqual(m.count("cơm"), 4, "10 × 0,7² = 4,9 → 4")
        XCTAssertEqual(m.bigramCount("ăn", "cơm"), 4)
    }

    // MARK: xếp hạng với dữ liệu học

    func testEmptyModelKeepsSeedRanking() {
        for b in ["cảm ", "xin ", "ăn ", "cảm ơn ", "tên ", "hôm na"] {
            let typed = b.hasSuffix(" ") ? "" : String(b.split(separator: " ").last!)
            let r = PredictionLogic.request(before: b, typed: typed, english: false)!
            XCTAssertEqual(PredictionModel.shared.candidates(r, raw: typed, learned: model()),
                           PredictionModel.shared.candidates(r, raw: typed), b)
        }
    }

    /// Yêu cầu maintainer: gõ "ăn cơm" 3 lần ⇒ "ăn␣" gợi ý "cơm".
    func testAnComThreeTimesSuggestsCom() {
        let m = model()
        type(m, "ăn cơm", times: 3)
        XCTAssertEqual(next("ăn ", m).first, "cơm")
    }

    func testLearnedPairOvertakesSeedWithShrinkage() {
        let m = model()
        type(m, "ăn tối", times: 3)
        XCTAssertEqual(next("ăn ", m).first, "cơm", "3 lần chưa đè seed curated (λ = n/(n+4))")
        type(m, "ăn tối")
        XCTAssertEqual(next("ăn ", m).first, "tối")
    }

    func testNoBigramGuessUntilTypedTwice() {
        XCTAssertEqual(next("Tên ", nil), [], "không seed ⇒ không đoán")
        let m = model()
        type(m, "tên tôi")
        XCTAssertEqual(next("Tên ", m), [], "một lần gõ chưa đủ (learnedPairMin = 2)")
        type(m, "tên tôi")
        XCTAssertEqual(next("Tên ", m), ["tôi"])
    }

    func testLearnedTrigramLeadsStaticTrigram() {
        let m = model()
        // "sếp": không phải top trigram tĩnh sau "cảm ơn" (vnlm hội thoại 18/10/2026: anh; trước: cậu)
        type(m, "cảm ơn sếp", times: 3)
        XCTAssertEqual(next("cảm ơn ", m).first, "sếp")
        let once = model()
        type(once, "cảm ơn sếp")
        XCTAssertNotEqual(next("cảm ơn ", once).first, "sếp")
    }

    func testUnknownWordNeedsThreeTimes() {
        let m = model()
        type(m, "gặp xyzk", times: 2)
        XCTAssertFalse(next("gặp ", m).contains("xyzk"))
        type(m, "gặp xyzk")
        XCTAssertTrue(next("gặp ", m).contains("xyzk"))
    }

    func testSensitiveWordsStoredButFiltered() {
        let m = model()
        type(m, "thằng cặc", times: 4)
        XCTAssertEqual(m.count("cặc"), 4, "vẫn đếm")
        XCTAssertFalse(next("thằng ", m, filter: true).contains("cặc"))
        XCTAssertEqual(next("thằng ", m, filter: false).first, "cặc")
    }

    func testCompletionBoostFromLearnedContext() {
        let m = model()
        // seed 18/10/2026 có cặp "tôi hiểu" (seedNext tôi ∋ hiểu, +ngữ cảnh) ⇒ đổi ví dụ sang "anh hi"
        XCTAssertEqual(complete("anh hi", typed: "hi", nil).first, "hiểu")
        type(m, "anh hiền", times: 5)
        XCTAssertEqual(complete("anh hi", typed: "hi", m).first, "hiền")
    }

    func testEnglishContextKeepsEnglishLearnedWords() {
        let m = model()
        type(m, "hello world", times: 3)
        XCTAssertEqual(next("hello ", m, english: true), ["world"])
    }

    func testGoldenLearnRowsMatchFixture() throws {
        // Cột `learn` của golden Windows: cùng mô hình, cùng kết quả (đối chiếu C++).
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/app/tests/fixtures/word-prediction.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var n = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, !f[5].isEmpty else { continue }
            let m = model()
            for part in f[5].split(separator: "|") {
                var s = String(part), times = 1
                if let star = s.lastIndex(of: "*"), let k = Int(s[s.index(after: star)...]) { times = k; s = String(s[..<star]) }
                type(m, s, times: times)
            }
            let before = f[0].replacingOccurrences(of: "\\n", with: "\n")
            let r = PredictionLogic.request(before: before, typed: f[1], english: f[3] == "1")
            let got = r.map { PredictionModel.shared.candidates($0, raw: f[2], filterSensitive: f[4] != "0", learned: m) } ?? []
            XCTAssertEqual(got.joined(separator: "|"), f[6], line.description)
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 20)
    }

    // MARK: lưu file

    private func tempURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vt-learned-\(getpid())-\(name)")
            .appendingPathComponent(LearnedModel.fileName)
    }

    func testPersistenceRoundTrip() {
        let m = model()
        type(m, "cảm ơn anh", times: 3)
        type(m, "tên tôi là phúc", times: 2)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(LearnedModel.write(m.snapshot().encoded(), to: url))
        let (back, recovered) = LearnedModel.load(from: url, isKnownWord: { VNSuggest.contains($0) },
                                                  now: m.lastDecay)
        XCTAssertFalse(recovered)
        XCTAssertEqual(back.t.uniDict(), m.t.uniDict())
        XCTAssertEqual(back.t.biDict(), m.t.biDict())
        XCTAssertEqual(back.t.triDict(), m.t.triDict())
        XCTAssertEqual(next("cảm ơn ", back), next("cảm ơn ", m))
        // Cùng định dạng VTL2 của iOS/Android (UserLMCodec): danh sách thêm tay rỗng.
        let d = UserLMCodec.decode(try! Data(contentsOf: url))
        XCTAssertEqual(d?.tables.uniDict(), m.t.uniDict())
        XCTAssertEqual(d?.manual, [])
    }

    func testCorruptFileRecoversEmpty() throws {
        let m = model()
        type(m, "ăn cơm", times: 3)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var data = m.snapshot().encoded()
        data[data.count / 2] ^= 0xFF                       // CRC sai
        XCTAssertTrue(LearnedModel.write(data, to: url))
        var (back, recovered) = LearnedModel.load(from: url)
        XCTAssertTrue(recovered)
        XCTAssertTrue(back.isEmpty)
        for bad in [Data(), Data("garbage".utf8), m.snapshot().encoded().prefix(20)] {
            XCTAssertTrue(LearnedModel.write(Data(bad), to: url))
            (back, recovered) = LearnedModel.load(from: url)
            XCTAssertTrue(recovered && back.isEmpty)
        }
        // Thiếu file: rỗng, không phải "phục hồi".
        try FileManager.default.removeItem(at: url)
        (back, recovered) = LearnedModel.load(from: url)
        XCTAssertFalse(recovered)
        XCTAssertTrue(back.isEmpty)
    }

    /// Linux app Cài đặt "Xoá từ đã học" ghi kho rỗng này (config.py empty_learned_store) — đọc được, rỗng.
    func testLinuxEmptyStoreDecodes() {
        var hex = "56544c32" + "0100" + "0000" + String(repeating: "00", count: 24) + "3a3b26a4"
        var bytes: [UInt8] = []
        while !hex.isEmpty { bytes.append(UInt8(hex.prefix(2), radix: 16)!); hex.removeFirst(2) }
        let m = LearnedModel.decode(Data(bytes))
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.isEmpty, true)
        XCTAssertEqual(LearnedModel(now: Date(timeIntervalSince1970: 0)).snapshot().encoded(), Data(bytes))
    }

    /// Windows fixture (gen_prediction_golden.sh) = mã Swift này, từng byte.
    func testWindowsFixtureBytes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/app/tests/fixtures/learned-words.bin")
        let m = LearnedModel(isKnownWord: { VNSuggest.contains($0) }, now: Date(timeIntervalSince1970: 1_760_000_000))
        for (s, k) in [("cảm ơn anh", 3), ("tên tôi là phúc", 2), ("ăn cơm", 4), ("heeey you", 2), ("gặp xyzk", 3)] {
            type(m, s, times: k)
        }
        XCTAssertEqual(m.snapshot().encoded(), try Data(contentsOf: url))
    }

    /// Số đo cho báo cáo: RAM mô hình đầy (người gõ nhiều), cỡ file, chi phí mỗi ranh giới từ.
    func testPerfAndMemoryNumbers() {
        func heap() -> Int {
            var st = malloc_statistics_t()
            malloc_zone_statistics(nil, &st)
            return Int(st.size_in_use)
        }
        let words = (0..<5000).map { i -> String in
            var s = "w", v = i
            for _ in 0..<3 { s.append(Character(UnicodeScalar(97 + v % 26)!)); v /= 26 }
            return s
        }
        var seed: UInt32 = 12345
        func pick() -> String {
            seed = seed &* 1664525 &+ 1013904223
            let u = Double(seed >> 8) / 16777216
            return words[Int(5000 * u * u * u) % 5000]
        }
        let h0 = heap()
        let m = LearnedModel()
        let t0 = DispatchTime.now().uptimeNanoseconds
        var tr = LearnTracker()
        let n = 60000
        var commitNs: UInt64 = 0
        for i in 0..<n {
            if i % 8 == 0, let e = tr.breakContext() { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
            let a = DispatchTime.now().uptimeNanoseconds
            let e = tr.commit(pick(), boundary: " ")
            commitNs += DispatchTime.now().uptimeNanoseconds - a
            if let e { m.record(word: e.word, after: e.prev1, prev2: e.prev2, weight: e.weight) }
        }
        let perWordUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n) / 1000
        let h1 = heap()
        let file = m.snapshot().encoded().count
        print("LEARN macOS: tracker.commit \(Double(commitNs) / Double(n)) ns (key path), commit+record \(perWordUs) µs/word; "
              + "model \(m.wordCount) words / \(m.pairCount) pairs / \(m.tripleCount) triples; heap +\((h1 - h0) / 1024) KB; "
              + "file \(file / 1024) KB")
        XCTAssertLessThanOrEqual(m.wordCount, LearnedModel.uniCap)
        XCTAssertLessThan(perWordUs, 100)
        let t1 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<200 { _ = m.nextWords(after: words[i], prev2: words[i + 1], seeds: [], limit: 6) }
        print("LEARN macOS: nextWords \(Double(DispatchTime.now().uptimeNanoseconds - t1) / 200 / 1000) µs")
    }

    func testStoreSavesClearsAndDropsStalePending() throws {
        let q = DispatchQueue(label: "test.learned")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LearnedWords(queue: q, url: url)
        let g = store.generation
        for _ in 0..<3 { store.record(.init(word: "cơm", prev1: "ăn", prev2: nil, weight: 1), generation: g) }
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(LearnedModel.load(from: url).model.count("cơm"), 3)
        store.clearAll()
        store.flush()                                      // hàng đợi + IO đã chạy hết
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.withModelForTesting { $0.count("cơm") }, 0)
        // Lượt học CHỜ của thế hệ trước khi xoá bị bỏ.
        store.record(.init(word: "cơm", prev1: "ăn", prev2: nil, weight: 1), generation: g)
        XCTAssertEqual(store.withModelForTesting { $0.count("cơm") }, 0)
        store.record(.init(word: "phở", prev1: nil, prev2: nil, weight: 1), generation: store.generation)
        XCTAssertEqual(store.withModelForTesting { $0.count("phở") }, 1)
        // Tắt: lưu nốt rồi bỏ khỏi RAM.
        store.unload()
        XCTAssertFalse(store.isLoadedForTesting)
        store.flush()
        XCTAssertEqual(LearnedModel.load(from: url).model.count("phở"), 1)
    }

    // MARK: hoa/thường đã học (CaseTable — chung iOS/Android/Windows)

    /// Gõ như controller: từng câu riêng, lượt học mang dạng gốc + bằng chứng giữa câu.
    private func typeCased(_ m: LearnedModel, _ sentence: String, times: Int = 1) {
        for _ in 0..<times {
            var tr = LearnTracker()
            func rec(_ e: LearnTracker.Event) {
                m.record(word: e.form, after: e.prev1, prev2: e.prev2, weight: e.weight, caseEvidence: e.caseEvidence)
            }
            for w in sentence.split(separator: " ") { if let e = tr.commit(String(w), boundary: " ") { rec(e) } }
            if let e = tr.breakContext() { rec(e) }
        }
    }

    func testLearnedCasingThreeMidSentenceUses() {
        let m = model()
        typeCased(m, "gửi SenPrints", times: 2)
        XCTAssertNil(m.learnedCase("senprints"))
        typeCased(m, "gửi SenPrints")
        XCTAssertEqual(m.learnedCase("senprints"), "SenPrints")
        typeCased(m, "gặp anh Văn", times: 3)
        XCTAssertEqual(m.learnedCase("văn"), "Văn")
        // gợi ý từ kế tiếp + hoàn thành từ hiện dạng đã học (DisplayCase không có "văn")
        XCTAssertTrue(next("gặp anh ", m).contains("Văn"), "\(next("gặp anh ", m))")
        XCTAssertTrue(complete("gặp anh vă", typed: "vă", m).contains("Văn"), "\(complete("gặp anh vă", typed: "vă", m))")
        XCTAssertFalse(next("gặp anh ", nil).contains("Văn"))
    }

    func testLearnedCasingIgnoresSentenceStartCapsAndChains() {
        let m = model()
        typeCased(m, "Văn ơi", times: 5)                    // đầu câu
        typeCased(m, "gặp VĂN", times: 5)                   // Caps Lock
        typeCased(m, "yêu Việt Nam", times: 5)              // chuỗi tên riêng
        XCTAssertNil(m.learnedCase("văn"))
        XCTAssertNil(m.learnedCase("nam"))
        XCTAssertEqual(m.learnedCase("việt"), "Việt", "\"Việt\" giữa câu (sau \"yêu\") là bằng chứng thật")
        XCTAssertEqual(m.cases.stats["việt"]?.hits, 5)
        XCTAssertNil(m.cases.stats["nam"])
        XCTAssertNil(m.cases.stats["văn"])
        // từ nhập nhằng gõ thường nhiều trước đó: vài lần viết hoa không đủ
        let n = model()
        typeCased(n, "bài văn", times: 20)
        typeCased(n, "anh Văn", times: 3)
        XCTAssertNil(n.learnedCase("văn"))
    }

    func testLearnedCasingPersistsAndClears() throws {
        let m = model()
        typeCased(m, "gửi SenPrints", times: 3)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(LearnedModel.write(m.snapshot().encoded(), to: url))
        let back = LearnedModel.load(from: url, isKnownWord: { VNSuggest.contains($0) }, now: m.lastDecay).model
        XCTAssertEqual(back.learnedCase("senprints"), "SenPrints")
        XCTAssertEqual(back.cases, m.cases)
        back.clear()
        XCTAssertNil(back.learnedCase("senprints"))
        XCTAssertTrue(back.isEmpty)
        // không có dữ liệu hoa/thường ⇒ byte y như định dạng cũ (flags 0)
        let plain = model()
        type(plain, "ăn cơm", times: 2)
        let bytes = plain.snapshot().encoded()
        XCTAssertEqual(bytes[6], 0)
        XCTAssertEqual(bytes, UserLMCodec.encode(plain.t, lastDecay: plain.lastDecay, manual: []))
    }

    // MARK: LearnTracker

    func testTrackerContextAndPending() {
        var t = LearnTracker()
        XCTAssertNil(t.commit("Ăn", boundary: " "))
        XCTAssertEqual(t.pending, .init(word: "ăn", prev1: nil, prev2: nil, weight: 1, form: "Ăn"))
        XCTAssertEqual(t.pending?.caseEvidence, false, "đầu câu: chữ hoa không phải bằng chứng")
        XCTAssertEqual(t.commit("cơm", boundary: ","), .init(word: "ăn", prev1: nil, prev2: nil, weight: 1, form: "Ăn"))
        XCTAssertNil(t.prev1, "dấu câu cắt ngữ cảnh")
        XCTAssertEqual(t.commit("rồi", boundary: " "), .init(word: "cơm", prev1: "ăn", prev2: nil, weight: 1, form: "cơm"))
        XCTAssertEqual(t.pending, .init(word: "rồi", prev1: nil, prev2: nil, weight: 1, form: "rồi"))
        // ⌫ vào chữ vừa chốt: bỏ.
        t.discard()
        XCTAssertNil(t.pending)
        XCTAssertNil(t.breakContext())
        // Từ không đứng riêng ("a.đi") / không học được: không học, cắt ngữ cảnh.
        _ = t.commit("đi", boundary: " ")
        XCTAssertEqual(t.commit("x1", boundary: " ")?.word, "đi")
        XCTAssertNil(t.pending)
        XCTAssertNil(t.commit("học", boundary: " ", standsAlone: false))
        XCTAssertNil(t.pending)
    }

    func testTrackerTypoFixLearnsFixedForm() {
        var t = LearnTracker()
        _ = t.commit("tôi", boundary: " ")
        _ = t.commit("dii", boundary: " ")
        t.replacePending(with: "đi")
        XCTAssertEqual(t.pending, .init(word: "đi", prev1: "tôi", prev2: nil, weight: 1, form: "đi"))
        XCTAssertEqual(t.commit("học", boundary: " ")?.word, "đi")
        XCTAssertEqual(t.pending?.prev1, "đi", "ngữ cảnh theo dạng đã sửa")
    }
}

// MARK: - Cổng học đầu-cuối (handle())

/// Học chỉ ở đường IMK với công tắc + cài đặt hệ thống bật, app không phải terminal / trình soạn
/// mã, không ô mật khẩu; ⌫ vào từ vừa chốt không học từ đó.
final class LearnedWordsGateTests: XCTestCase {
    private var savedLearn = true
    private var savedBreaker = true

    override func setUp() {
        super.setUp()
        Accessibility.testTrustOverride = true
        FocusedFieldDetector._testSetCached(false)
        FocusedFieldDetector._testSetMarked(false)
        FocusedFieldDetector._testSetPassthrough(false)
        SecureFieldDetector._testSetCached(false)
        SystemInlinePrediction.setForTesting(true)
        savedLearn = AppState.shared.learnWords
        AppState.shared.learnWords = true
        savedBreaker = AppState.shared.tapCascadeBreaker
        AppState.shared.tapCascadeBreaker = false
        LearnedWords.shared.resetForTesting()
    }

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        SystemInlinePrediction.setForTesting(nil)
        SecureFieldDetector._testSetCached(false)
        AppState.shared.learnWords = savedLearn
        AppState.shared.tapCascadeBreaker = savedBreaker
        AppState.shared.currentBundleID = nil
        FrontmostApp.shared._testSetBundleID(nil)
        CaretHint.shared.setPendingForTesting(nil)
        LearnedWords.shared.resetForTesting()
        super.tearDown()
    }

    private func learned(_ w: String) -> Int { LearnedWords.shared.withModelForTesting { $0.count(w) } }
    private func pair(_ a: String, _ b: String) -> Int { LearnedWords.shared.withModelForTesting { $0.bigramCount(a, b) } }

    func testStoreIsNeverTheRealFileInTests() {
        XCTAssertTrue(LearnedWords.shared.fileURLForTesting.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testLearnsCommittedWordsInTextEdit() {
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        for _ in 0..<3 { h.type("awn cowm ") }
        h.keyCode(36, chars: "\r")                         // Enter: lượt chờ được học
        XCTAssertEqual(learned("cơm"), 3)
        XCTAssertEqual(pair("ăn", "cơm"), 3)
        XCTAssertEqual(pair("cơm", "ăn"), 2, "câu nối bằng dấu cách vẫn cùng câu")
    }

    func testSwitchOffLearnsNothing() {
        AppState.shared.learnWords = false
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        h.type("awn cowm ")
        h.keyCode(36, chars: "\r")
        XCTAssertEqual(learned("cơm"), 0)
    }

    func testSystemPredictionOffLearnsNothing() {
        SystemInlinePrediction.setForTesting(false)
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        h.type("awn cowm ")
        h.keyCode(36, chars: "\r")
        XCTAssertEqual(learned("cơm"), 0)
    }

    func testCodeEditorAndTerminalLearnNothing() {
        for id in ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2"] {
            let h = ControllerHarness(bundleID: id)
            h.type("awn cowm ")
            h.keyCode(36, chars: "\r")
            XCTAssertEqual(learned("cơm"), 0, id)
        }
    }

    func testSecureFieldLearnsNothing() {
        SecureFieldDetector._testSetCached(true)
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        h.type("awn cowm ")
        h.keyCode(36, chars: "\r")
        XCTAssertEqual(learned("cơm"), 0)
        XCTAssertEqual(learned("awn"), 0)
    }

    func testBackspaceIntoCommittedWordDropsIt() {
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        h.type("awn cowm ")
        h.keyCode(51)                                      // ⌫ ngay sau ranh giới
        h.keyCode(36, chars: "\r")
        XCTAssertEqual(learned("ăn"), 1)
        XCTAssertEqual(learned("cơm"), 0, "từ có thể đang bị sửa ⇒ không học")
    }

    func testLearnsMidSentenceCasingButNotSentenceStart() {
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        for _ in 0..<3 { h.type("Gawpj anh Vawn "); h.keyCode(36, chars: "\r") }   // mỗi lần một câu
        LearnedWords.shared.withModelForTesting { m in
            XCTAssertEqual(m.learnedCase("văn"), "Văn")
            XCTAssertNil(m.learnedCase("gặp"), "đầu câu")
            XCTAssertNil(m.cases.stats["gặp"])
        }
    }

    func testSecureFieldLearnsNoCasing() {
        SecureFieldDetector._testSetCached(true)
        let h = ControllerHarness(bundleID: "com.apple.TextEdit")
        for _ in 0..<3 { h.type("anh Vawn ") }
        h.keyCode(36, chars: "\r")
        LearnedWords.shared.withModelForTesting { m in XCTAssertTrue(m.cases.isEmpty) }
    }

    func testAcceptedPredictionLearnsWithWeightTwo() {
        let h = ControllerHarness(bundleID: "com.apple.TextEdit", text: "a ")
        h.acceptPrediction(typing: "dduw", typed: "đư", word: "được")
        h.keyCode(36, chars: "\r")
        XCTAssertEqual(learned("được"), 2)
    }
}
