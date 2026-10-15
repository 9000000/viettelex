// Dịch trên máy (Plus) — chip "Dịch ↔ <đích>" trong danh sách Công cụ văn bản.
// RIÊNG TƯ: chỉ dùng Apple Translation với gói ngôn ngữ ĐÃ CÀI trên máy
// (TranslationSession(installedSource:target:), iOS 26+) — không mạng, không server.
// Bàn phím không tự tải gói được (session kiểu này canRequestDownloads == false) ⇒ báo
// người dùng mở app (App/Plus/TranslateSettingsView.swift).
// KHÔNG TỐN GÌ khi không dùng: file này KHÔNG import Translation — phần gọi Apple Translation
// nằm ở iOS/VTTranslate/TranslateEngine.swift. iOS: bàn phím không link Translation (link là
// dyld nạp nó + ~33 framework phụ thuộc lúc khởi động); `TranslateLoader` dlopen
// VTTranslate.framework của app chủ lần đầu bấm chip. Session là biến cục bộ, nhả ngay sau
// một lần dịch. Luật chiều dịch: Shared/TranslatePrefs.swift.
// macOS dùng chung file này (project.yml, Công cụ → Dịch — App/Sources/TranslateAction.swift)
// + TranslateEngine.swift biên dịch thẳng vào app: mọi chỗ cần OS mới ghi cả iOS 26 lẫn macOS 26.
import Foundation

/// Phần THUẦN (test được): nhận ra ngôn ngữ + giữ khoảng trắng hai đầu.
enum TranslateText {
    /// Hệ điều hành có dịch trên máy dùng được từ bàn phím (init installedSource: iOS/macOS 26).
    static var isSupportedOS: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    // MARK: chiều dịch — đoán bằng chữ, KHÔNG dùng NaturalLanguage (Phil 13/10/2026: thư viện
    // nhận diện ngôn ngữ bị nạp ngay khi bàn phím mở ⇒ tốn RAM cả khi không dịch). Cùng luật
    // với Android (keyboard/Translate.kt TranslateDirection.plan):
    //  1. Có chữ chỉ tiếng Việt mới có (ă đ ĩ ũ ơ ư, khối ạ…ỹ) — hoặc đích là tiếng Anh và có
    //     nguyên âm Latin-1 mang dấu (à é ô…) ⇒ tiếng Việt.
    //  2. Không thì chữ cái chủ yếu thuộc hệ chữ của đích ⇒ đã là ngôn ngữ đích (khứ hồi).
    //  3. Còn lại ⇒ coi là tiếng Việt (gồm cả tiếng Việt không dấu).
    // Giới hạn: tiếng Việt không dấu khi đích dùng chữ Latin bị coi là ngôn ngữ đích; tiếng
    // Anh khi đích là tiếng Nhật bị dịch như tiếng Việt; không tách ngôn ngữ cùng hệ chữ.

    /// Chữ cái chỉ có trong bảng chữ tiếng Việt (ngoài Latin-1).
    static func isVietnameseOnly(_ v: UInt32) -> Bool {
        switch v {
        case 0x0102, 0x0103, 0x0110, 0x0111, 0x0128, 0x0129,
             0x0168, 0x0169, 0x01A0, 0x01A1, 0x01AF, 0x01B0: return true
        default: return (0x1EA0...0x1EF9).contains(v)
        }
    }

    /// à á â ã è é ê ì í ò ó ô õ ù ú ý (cả hoa).
    private static let latin1VnVowels: Set<UInt32> = [0xE0, 0xE1, 0xE2, 0xE3, 0xE8, 0xE9, 0xEA, 0xEC,
                                                      0xED, 0xF2, 0xF3, 0xF4, 0xF5, 0xF9, 0xFA, 0xFD]

    static func looksVietnamese(_ s: String, target: String) -> Bool {
        let loose = TranslatePrefs.base(target) == "en"
        return s.precomposedStringWithCanonicalMapping.unicodeScalars.contains { c in
            isVietnameseOnly(c.value)
                || (loose && latin1VnVowels.contains(c.value | (c.value >= 0xC0 && c.value <= 0xDD ? 0x20 : 0)))
        }
    }

    enum Script { case latin, cyrillic, arabic, hebrew, greek, devanagari, thai, hangul, kana, han, other }

    static func script(_ v: UInt32) -> Script {
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .han
        default: return .other
        }
    }

    /// Hệ chữ của ngôn ngữ đích (theo mã gốc; còn lại là chữ Latin).
    static func scripts(of target: String) -> Set<Script> {
        switch TranslatePrefs.base(target) {
        case "ru", "uk", "be", "bg", "mk": return [.cyrillic]
        case "ar", "fa", "ur": return [.arabic]
        case "he": return [.hebrew]
        case "el": return [.greek]
        case "hi", "mr": return [.devanagari]
        case "th": return [.thai]
        case "ko": return [.hangul]
        case "ja": return [.kana, .han]
        case "zh": return [.han]
        default: return [.latin]
        }
    }

    /// Chữ cái của đoạn chữ chủ yếu thuộc hệ chữ của đích (không tính dấu câu/số/khoảng trắng).
    static func inTargetScript(_ s: String, target: String) -> Bool {
        let want = scripts(of: target)
        var hit = 0, miss = 0, kana = false
        for c in s.unicodeScalars where c.properties.isAlphabetic {
            let sc = script(c.value)
            if sc == .kana { kana = true }
            if want.contains(sc) { hit += 1 } else { miss += 1 }
        }
        if TranslatePrefs.base(target) == "zh" && kana { return false }  // có kana ⇒ tiếng Nhật
        return hit > 0 && hit >= miss
    }

    /// Ngôn ngữ nguồn đoán được: "vi" hoặc chính `target`; nil khi không có chữ để dịch.
    static func detect(_ s: String, target: String) -> String? {
        guard s.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return nil }
        if looksVietnamese(s, target: target) { return TranslatePrefs.vietnamese }
        if inTargetScript(s, target: target) { return target }
        return TranslatePrefs.vietnamese
    }

    // MARK: khoảng trắng

    /// Tách khoảng trắng đầu/cuối (bản dịch hay bỏ mất — "xin chào " phải ra "hello ").
    static func splitWhitespace(_ s: String) -> (lead: String, core: String, trail: String) {
        let cs = Array(s.unicodeScalars)
        guard let first = cs.firstIndex(where: { !TextTools.isSpace($0) }),
              let last = cs.lastIndex(where: { !TextTools.isSpace($0) }) else {
            return (s, "", "")
        }
        func str(_ r: ArraySlice<Unicode.Scalar>) -> String {
            var v = String.UnicodeScalarView(); v.append(contentsOf: r); return String(v)
        }
        return (str(cs[..<first]), str(cs[first...last]), str(cs[(last + 1)...]))
    }

    /// Ráp bản dịch vào đúng khoảng trắng của chữ gốc.
    static func rewrap(original: String, translated: String) -> String {
        let o = splitWhitespace(original)
        let t = splitWhitespace(translated)
        return o.lead + t.core + o.trail
    }

    // MARK: nhiều đoạn (bug tester Plus 15/10/2026: "không dịch được cả đoạn dài có ngắt dòng")
    // Gửi cả khối nhiều dòng thành MỘT chuỗi cho Apple Translation thì dấu xuống dòng không
    // được giữ (đoạn bị dồn/mất). Dịch TỪNG DÒNG trong một session (lô), ráp lại đúng ký tự
    // xuống dòng gốc; dòng trống / dòng không có chữ cái giữ nguyên.

    /// Ngăn giữa các mục của một lô qua C ABI `vt_translate` (khớp TranslateEngine.batchSeparator).
    static let batchSeparator: Character = "\u{1E}"

    /// Tách thành các dòng + chuỗi xuống dòng giữa chúng (`breaks.count == lines.count - 1`).
    /// Mỗi ký tự xuống dòng ("\n", "\r\n" là MỘT Character, U+2028…) là một ranh giới, nên
    /// dòng trống được giữ: "a\n\nb" ⇒ lines ["a", "", "b"], breaks ["\n", "\n"].
    static func splitLines(_ s: String) -> (lines: [String], breaks: [String]) {
        var lines: [String] = [], breaks: [String] = []
        var cur = ""
        for c in s {
            if c.isNewline {
                lines.append(cur); cur = ""
                breaks.append(String(c))
            } else {
                cur.append(c)
            }
        }
        lines.append(cur)
        return (lines, breaks)
    }

    static func joinLines(_ lines: [String], breaks: [String]) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            out += l
            if i < breaks.count { out += breaks[i] }
        }
        return out
    }

    /// Có chữ cái để dịch không.
    static func hasLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic }
    }

    /// Kế hoạch dịch nhiều dòng: chỉ số các dòng cần dịch + lõi (bỏ khoảng trắng hai đầu) của chúng.
    static func linePlan(_ s: String) -> (lines: [String], breaks: [String], indices: [Int], cores: [String]) {
        let (lines, breaks) = splitLines(s)
        var idx: [Int] = [], cores: [String] = []
        for (i, l) in lines.enumerated() where hasLetters(l) {
            idx.append(i)
            cores.append(String(splitWhitespace(l).core.map { $0 == batchSeparator ? " " : $0 }))
        }
        return (lines, breaks, idx, cores)
    }

    /// Ráp bản dịch từng dòng (`translated[k]` ứng với `indices[k]`) — nil nếu số mục lệch.
    static func assemble(lines: [String], breaks: [String], indices: [Int], translated: [String]) -> String? {
        guard translated.count == indices.count else { return nil }
        var out = lines
        for (k, i) in indices.enumerated() { out[i] = rewrap(original: lines[i], translated: translated[k]) }
        return joinLines(out, breaks: breaks)
    }

    /// Dịch văn bản (có thể nhiều dòng) bằng `one` — một lần gọi duy nhất: một dòng ⇒ gửi
    /// nguyên; nhiều dòng ⇒ gửi lô các dòng có chữ (ngăn bằng `batchSeparator`), ráp lại.
    static func translateLines(_ text: String,
                               using one: (String) async -> Result<String, TranslateFailure>) async -> Result<String, TranslateFailure> {
        let plan = linePlan(text)
        guard plan.lines.count > 1 else { return await one(text) }
        guard !plan.cores.isEmpty else { return .success(text) }
        switch await one(plan.cores.joined(separator: String(batchSeparator))) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            let parts = out.split(separator: batchSeparator, omittingEmptySubsequences: false).map(String.init)
            guard let joined = assemble(lines: plan.lines, breaks: plan.breaks,
                                        indices: plan.indices, translated: parts) else { return .failure(.failed) }
            return .success(joined)
        }
    }

    /// Không có vùng chọn: chỉ dịch được đoạn (dòng) đang gõ trước con trỏ. Trả true khi ô còn
    /// chữ khác ngoài đoạn đó (đoạn trước trong `before`, hoặc chữ sau con trỏ) ⇒ báo người
    /// dùng chọn toàn bộ văn bản. iOS chỉ đưa bàn phím một cửa sổ chữ quanh con trỏ (thường
    /// tới đầu đoạn) nên không thể tự lấy hết văn bản khi không có vùng chọn.
    static func coversOnlyPart(isSelection: Bool, source: String, before: String?, after: String?) -> Bool {
        guard !isSelection else { return false }
        if let a = after, hasLetters(a) { return true }
        guard let b = before else { return false }
        let rest = b.unicodeScalars.dropLast(source.unicodeScalars.count)
        return rest.contains { $0.properties.isAlphabetic }
    }
}

/// Kết quả một lần dịch.
enum TranslateFailure: Error, Equatable {
    /// Cặp ngôn ngữ được hỗ trợ nhưng gói chưa tải ⇒ mở app để tải.
    case notInstalled
    /// Máy / hệ điều hành không dịch được cặp này.
    case unsupported
    /// Không nhận ra ngôn ngữ của đoạn chữ.
    case unknownLanguage
    case failed
}

extension TranslateFailure {
    /// Mã từ TranslateEngine (`TranslateEngineCode`); 0 (ok) ⇒ nil.
    init?(engineCode: Int32) {
        switch engineCode {
        case 0: return nil
        case 1: self = .notInstalled
        case 2: self = .unsupported
        case 3: self = .unknownLanguage
        default: self = .failed
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
enum OnDeviceTranslator {
    /// Dịch một lần (gói ngôn ngữ phải đã cài — kiểm trước, không tạo session thừa).
    /// Nhiều dòng ⇒ một lô (một session), mỗi dòng có chữ là một mục; ráp lại giữ nguyên
    /// xuống dòng / dòng trống (TranslateText.linePlan).
    static func translate(_ text: String, pair: TranslateDirection.Pair) async -> Result<String, TranslateFailure> {
        await TranslateText.translateLines(text) { await translateOne($0, pair: pair) }
    }

    private static func translateOne(_ text: String, pair: TranslateDirection.Pair) async -> Result<String, TranslateFailure> {
        #if os(iOS)
        let r = await TranslateLoader.run(text, source: pair.source, target: pair.target)
        #else
        let r = await TranslateEngine.run(text, source: pair.source, target: pair.target)
        #endif
        if let f = TranslateFailure(engineCode: r.code) {
            if f == .failed {
                #if os(iOS)
                TouchLog.write("translate failed: \(r.text ?? "?")")
                #else
                DebugLog.log("translate failed: \(r.text ?? "?")")
                #endif
            }
            return .failure(f)
        }
        return .success(r.text ?? "")
    }
}

#if os(iOS)
/// Nạp lười VTTranslate.framework (nhúng ở app chủ, KHÔNG link vào bàn phím) rồi gọi
/// `vt_translate` qua dlsym. Không tìm thấy / không nạp được ⇒ `.unsupported` (không crash).
enum TranslateLoader {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void
    typealias Entry = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
                                      UnsafeMutableRawPointer?, Callback) -> Void

    static let frameworkName = "VTTranslate"

    /// Đường dẫn binary framework: bàn phím = VietTelex.app/PlugIns/X.appex ⇒ ../../Frameworks;
    /// app/test = Frameworks của chính bundle.
    static func candidatePaths(bundle: Bundle = .main) -> [String] {
        let rel = "\(frameworkName).framework/\(frameworkName)"
        var out: [String] = []
        if bundle.bundleURL.pathExtension == "appex" {
            out.append(bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Frameworks").appendingPathComponent(rel).path)
        }
        if let p = bundle.privateFrameworksURL { out.append(p.appendingPathComponent(rel).path) }
        return out
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Entry??

    /// dlopen một lần (lần đầu cần) — nil nếu không có framework.
    static func entry(paths: [String] = candidatePaths()) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        var found: Entry?
        for p in paths where FileManager.default.fileExists(atPath: p) {
            guard let h = dlopen(p, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(h, "vt_translate") else {
                TouchLog.write("translate: dlopen \(p) lỗi \(String(cString: dlerror()))")
                continue
            }
            found = unsafeBitCast(sym, to: Entry.self)
            break
        }
        cached = .some(found)
        return found
    }

    #if DEBUG
    /// Test: quên kết quả dlopen (để thử đường dẫn khác).
    static func debugReset() { lock.lock(); cached = nil; lock.unlock() }
    #endif

    private final class Box {
        let done: (Int32, String?) -> Void
        init(_ done: @escaping (Int32, String?) -> Void) { self.done = done }
    }

    static func run(_ text: String, source: String, target: String,
                    entry fn: Entry? = nil) async -> (code: Int32, text: String?) {
        guard let fn = fn ?? entry() else { return (2, nil) }   // TranslateEngineCode.unsupported
        return await withCheckedContinuation { cont in
            let box = Box { code, out in cont.resume(returning: (code, out)) }
            let ctx = Unmanaged.passRetained(box).toOpaque()
            text.withCString { t in source.withCString { s in target.withCString { d in
                fn(t, s, d, ctx) { ctx, code, out in
                    guard let ctx else { return }
                    let b = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                    b.done(code, out.map { String(cString: $0) })
                }
            } } }
        }
    }
}
#endif
