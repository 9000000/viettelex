import XCTest

/// Đợt sửa 14/10/2026 — đường phím nóng (không cấp phát thừa mỗi phím), dung lượng app
/// (dữ liệu dùng chung với bàn phím, Translation không link vào bàn phím) và chữ trong app.
final class PerfSizeUXFixTests: XCTestCase {

    // MARK: manualCompletions — chỉ mục fold sẵn, tìm nhị phân

    /// Bản cũ (fold cả danh sách mỗi phím) — chuẩn để so.
    private func reference(_ m: UserLangModel, _ prefix: String, limit: Int = 2) -> [String] {
        guard !m.manual.isEmpty, !prefix.isEmpty else { return [] }
        let f = UserLangModel.fold(prefix)
        return m.manual.filter { k, d in d != prefix && UserLangModel.fold(k).hasPrefix(f) }
            .sorted { a, b in
                let ca = m.count(of: a.key), cb = m.count(of: b.key)
                return ca != cb ? ca > cb : a.key < b.key
            }
            .prefix(limit).map { $0.value }
    }

    func testManualCompletionsMatchesFullScan() {
        let m = UserLangModel(appGroup: nil)
        let words = ["VietTelex", "Việt", "viettel", "Phúc", "Phương", "phường", "Đức", "Dũng", "Kubernetes",
                     "kube", "Ánh", "anh", "Zalo", "Zoom", "Đà", "đàn", "Nguyễn", "Ngọc", "ngân", "Trịnh"]
        for w in words { XCTAssertTrue(m.addWord(w), w) }
        m.record(word: "phúc", after: nil)                 // tần suất khác nhau ⇒ thứ tự theo count
        for _ in 0..<3 { m.record(word: "ngọc", after: nil) }
        let prefixes = ["v", "vi", "Việ", "viet", "VIETT", "p", "ph", "phu", "Phư", "d", "đ", "Đà", "da",
                        "k", "kube", "a", "Á", "z", "zo", "n", "ng", "Ngu", "t", "tr", "x", "", "VietTelex"]
        for p in prefixes {
            for limit in [1, 2, 5] {
                XCTAssertEqual(m.manualCompletions(p, limit: limit), reference(m, p, limit: limit), "\(p) / \(limit)")
            }
        }
    }

    func testManualIndexRebuiltWhenWordsChange() {
        let m = UserLangModel(appGroup: nil)
        XCTAssertTrue(m.addWord("Kubernetes"))
        XCTAssertEqual(m.manualCompletions("kub"), ["Kubernetes"])
        XCTAssertTrue(m.debugHasManualIndex, "phím kế tiếp dùng chỉ mục đã dựng")
        XCTAssertTrue(m.addWord("Kubectl"))
        XCTAssertFalse(m.debugHasManualIndex, "thêm từ ⇒ bỏ chỉ mục")
        XCTAssertEqual(Set(m.manualCompletions("kub", limit: 5)), ["Kubernetes", "Kubectl"])
        XCTAssertTrue(m.removeWord("Kubernetes"))
        XCTAssertEqual(m.manualCompletions("kub", limit: 5), ["Kubectl"])
        m.eraseAll()
        XCTAssertEqual(m.manualCompletions("kub"), [])
    }

    func testManualCompletionsLatencyWithLargeList() {
        let m = UserLangModel(appGroup: nil)
        let letters = Array("abcdeghiklmnopqrstuvxy")
        var n = 0
        for a in letters { for b in letters { for c in letters.prefix(4) where n < 2000 {
            if m.addWord("Ten" + String([a, b, c])) { n += 1 }
        } } }
        _ = m.manualCompletions("tenab")              // dựng chỉ mục một lần
        let t0 = CACurrentMediaTime()
        for _ in 0..<200 { _ = m.manualCompletions("tenab") }
        let perCall = (CACurrentMediaTime() - t0) / 200
        XCTAssertLessThan(perCall, 0.001, "mỗi phím phải ≪ 1 ms với 2.000 từ thêm tay (\(perCall * 1e6) µs)")
        XCTAssertEqual(m.manualCompletions("tenab", limit: 5), reference(m, "tenab", limit: 5))
    }

    // MARK: hoãn gợi ý — một timer dùng lại

    func testDebouncerFiresOnceAfterLastSchedule() {
        let d = MainDebouncer()
        let done = expectation(description: "fired")
        var fired = 0
        d.action = { fired += 1; done.fulfill() }
        for i in 0..<10 {   // 10 "phím" liên tiếp — chỉ chạy một lần, sau phím cuối
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.005) { d.schedule(after: 0.03) }
        }
        wait(for: [done], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(d.fireCount, 1)
        XCTAssertFalse(d.isArmed)
    }

    func testDebouncerCancelAndReuse() {
        let d = MainDebouncer()
        var fired = 0
        d.action = { fired += 1 }
        d.schedule(after: 0.02)
        d.cancel()
        let a = expectation(description: "after cancel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { a.fulfill() }
        wait(for: [a], timeout: 2)
        XCTAssertEqual(fired, 0, "huỷ ⇒ không chạy")
        let b = expectation(description: "reuse")
        d.action = { fired += 1; b.fulfill() }
        d.schedule(after: 0.01)
        wait(for: [b], timeout: 2)
        XCTAssertEqual(fired, 1, "cùng timer dùng lại được")
    }

    // MARK: khoá bar gợi ý

    func testBarSignatureEquality() {
        typealias S = KeyboardView.BarSignature
        let a = S(dark: false, theme: .system, s0: .init(display: "việt", insert: "việt"), s1: nil, s2: nil,
                  emojis: ["🇻🇳"], paste: .none)
        XCTAssertEqual(a, S(dark: false, theme: .system, s0: .init(display: "việt", insert: "việt"), s1: nil, s2: nil,
                            emojis: ["🇻🇳"], paste: .none))
        XCTAssertNotEqual(a, S(dark: true, theme: .system, s0: a.s0, s1: nil, s2: nil, emojis: ["🇻🇳"], paste: .none))
        XCTAssertNotEqual(a, S(dark: false, theme: .system, s0: .init(display: "việt", insert: "x"), s1: nil, s2: nil,
                               emojis: ["🇻🇳"], paste: .none))
        XCTAssertNotEqual(a, S(dark: false, theme: .system, s0: a.s0, s1: nil, s2: nil, emojis: [], paste: .none))
        XCTAssertNotEqual(a, S(dark: false, theme: .system, s0: a.s0, s1: nil, s2: nil, emojis: ["🇻🇳"], paste: .image))
        // Ranh giới ô: ("ab","") khác ("a","b") — chuỗi ghép cũ dựa vào ký tự phân cách.
        XCTAssertNotEqual(S(dark: false, theme: .system, s0: .init(display: "ab", insert: ""), s1: nil, s2: nil, emojis: [], paste: .none),
                          S(dark: false, theme: .system, s0: .init(display: "a", insert: "b"), s1: nil, s2: nil, emojis: [], paste: .none))
    }

    // MARK: TouchLog — không dựng chuỗi khi Debug mode tắt

    func testTouchLogDoesNotBuildStringWhenDisabled() {
        let was = TouchLog.enabled
        defer { TouchLog.enabled = was }
        TouchLog.enabled = false
        var built = 0
        func line() -> String { built += 1; return "x" }
        for _ in 0..<5 { TouchLog.write(line()) }
        XCTAssertEqual(built, 0)
    }

    // MARK: Dịch — framework nạp lười, bàn phím không link Translation

    func testTranslateLoaderPathFromKeyboardAppex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let appex = root.appendingPathComponent("VietTelex.app/PlugIns/VietTelexKeyboard.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        let b = try XCTUnwrap(Bundle(url: appex))
        let first = try XCTUnwrap(TranslateLoader.candidatePaths(bundle: b).first)
        XCTAssertTrue(first.hasSuffix("VietTelex.app/Frameworks/VTTranslate.framework/VTTranslate"),
                      "bàn phím tìm framework ở Frameworks của app chủ: \(first)")
        XCTAssertFalse(first.contains("PlugIns"))
    }

    func testTranslateLoaderMissingFrameworkIsUnsupported() async {
        let r = await TranslateLoader.run("xin chào", source: "vi", target: "en",
                                          entry: TranslateLoader.entry(paths: ["/nonexistent/VTTranslate"]))
        XCTAssertEqual(r.code, 2)
        XCTAssertEqual(TranslateFailure(engineCode: r.code), .unsupported)
        TranslateLoader.debugReset()
    }

    /// Framework thật (nhúng vào bundle test, không link): dlopen + gọi qua C trả kết quả,
    /// không crash. Simulator thường chưa có gói dịch ⇒ chấp nhận mọi mã hợp lệ.
    func testTranslateFrameworkLoadsAndAnswers() async throws {
        let fw = try XCTUnwrap(Bundle(for: Self.self).privateFrameworksURL)
            .appendingPathComponent("VTTranslate.framework/VTTranslate").path
        TranslateLoader.debugReset()
        defer { TranslateLoader.debugReset() }
        let entry = try XCTUnwrap(TranslateLoader.entry(paths: [fw]), "dlopen VTTranslate")
        let r = await TranslateLoader.run("xin chào", source: "vi", target: "en", entry: entry)
        XCTAssertTrue((0...4).contains(r.code), "mã \(r.code)")
        if r.code == 0 { XCTAssertFalse((r.text ?? "").isEmpty) }
        if #unavailable(iOS 26.0) { XCTAssertEqual(r.code, 2) }
    }

    func testTranslateFailureCodes() {
        XCTAssertNil(TranslateFailure(engineCode: 0))
        XCTAssertEqual(TranslateFailure(engineCode: 1), .notInstalled)
        XCTAssertEqual(TranslateFailure(engineCode: 2), .unsupported)
        XCTAssertEqual(TranslateFailure(engineCode: 3), .unknownLanguage)
        XCTAssertEqual(TranslateFailure(engineCode: 4), .failed)
        XCTAssertEqual(TranslateFailure(engineCode: 99), .failed)
    }

    /// Bàn phím không được import Translation (link = nạp ~34 framework lúc khởi động).
    func testKeyboardSourcesDoNotImportTranslation() throws {
        let kb = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Keyboard")
        let files = FileManager.default.enumerator(at: kb, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 20)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            let imports = src.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import Translation") }
            XCTAssertFalse(imports, f.lastPathComponent)
        }
    }

    // MARK: dữ liệu dùng chung — app đọc từ bàn phím nhúng

    func testBundleResourceFallsBackToEmbeddedKeyboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("VietTelex.app")
        let appex = app.appendingPathComponent("PlugIns/VietTelexKeyboard.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: appex.appendingPathComponent("vnlexicon.bin"))
        let appBundle = try XCTUnwrap(Bundle(url: app))
        let u = try XCTUnwrap(VTBundleResource.url("vnlexicon", "bin", bundles: [appBundle]))
        XCTAssertEqual(try Data(contentsOf: u), Data([1, 2, 3]))
        XCTAssertNil(VTBundleResource.url("enlexicon", "bin", bundles: [appBundle]))
        // Bundle có sẵn file thì dùng file đó (bàn phím / test) — bundle mới, khỏi cache NSBundle.
        let own = root.appendingPathComponent("Own.app")
        try FileManager.default.createDirectory(at: own.appendingPathComponent("PlugIns/VietTelexKeyboard.appex"),
                                                withIntermediateDirectories: true)
        try Data([9]).write(to: own.appendingPathComponent("vnlexicon.bin"))
        try Data([1]).write(to: own.appendingPathComponent("PlugIns/VietTelexKeyboard.appex/vnlexicon.bin"))
        let ownBundle = try XCTUnwrap(Bundle(url: own))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(VTBundleResource.url("vnlexicon", "bin", bundles: [ownBundle]))), Data([9]))
    }

    // MARK: chữ trong app

    private static var iosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func appSources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["App", "Keyboard", "Shared"] {
            let base = iosRoot.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for f in files { out.append((f.lastPathComponent, try String(contentsOf: f, encoding: .utf8))) }
        }
        return out
    }

    /// Mọi tính năng app đánh dấu "cần Toàn quyền" (FullAccessNotice) phải có trong dòng
    /// giới thiệu Toàn quyền ở tab Giới thiệu — trước chỉ ghi Rung phím + Mẫu câu động.
    func testFullAccessFooterListsEveryGatedFeature() throws {
        let src = try Self.appSources()
        let re = try NSRegularExpression(pattern: #"FullAccessNotice\(reason: L\("([^"]+)"\)\)"#)
        var reasons = Set<String>()
        for (_, t) in src {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                reasons.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        XCTAssertTrue(reasons.isSuperset(of: ["Rung phím", "Âm thanh phím", "Lịch sử clipboard", "Mẫu câu động"]), "\(reasons)")
        let footer = try XCTUnwrap(L10n.en.keys.first { $0.hasPrefix("Toàn quyền Truy cập là tuỳ chọn") })
        for r in reasons { XCTAssertTrue(footer.contains(r), "dòng Toàn quyền thiếu \(r)") }
        XCTAssertTrue(footer.contains("Nút Dán"), "nút Dán cần Toàn quyền (pasteOffer)")
    }

    /// Một cách viết: "Xoá" (đa số mã nguồn) — không trộn "Xóa".
    func testDeleteSpellingUnified() throws {
        for (name, t) in try Self.appSources() {
            XCTAssertFalse(t.contains("Xóa") || t.contains("xóa"), "\(name) còn “Xóa/xóa”")
        }
    }
}
