// Dịch trên máy (Plus) — chip "Dịch ↔ <đích>" trong danh sách Công cụ văn bản.
// RIÊNG TƯ: chỉ dùng Apple Translation với gói ngôn ngữ ĐÃ CÀI trên máy
// (TranslationSession(installedSource:target:), iOS 26+) — không mạng, không server.
// Bàn phím không tự tải gói được (session kiểu này canRequestDownloads == false) ⇒ báo
// người dùng mở app (App/Plus/TranslateSettingsView.swift).
// KHÔNG TỐN GÌ khi không dùng: Translation chỉ chạm tới khi bấm chip;
// session là biến cục bộ, nhả ngay sau một lần dịch. Luật chiều dịch: Shared/TranslatePrefs.swift.
import Foundation
#if canImport(Translation)
import Translation
#endif

/// Phần THUẦN (test được): nhận ra ngôn ngữ + giữ khoảng trắng hai đầu.
enum TranslateText {
    /// Hệ điều hành có dịch trên máy dùng được từ bàn phím (init installedSource: iOS 26).
    static var isSupportedOS: Bool {
        if #available(iOS 26.0, *) { return true }
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

@available(iOS 26.0, *)
enum OnDeviceTranslator {
    /// Dịch một lần. Kiểm tra gói đã cài TRƯỚC (LanguageAvailability, không tạo session);
    /// session sống trong hàm này rồi được nhả.
    static func translate(_ text: String, pair: TranslateDirection.Pair) async -> Result<String, TranslateFailure> {
        #if canImport(Translation)
        let src = Locale.Language(identifier: pair.source)
        let dst = Locale.Language(identifier: pair.target)
        switch await LanguageAvailability().status(from: src, to: dst) {
        case .installed: break
        case .supported: return .failure(.notInstalled)
        case .unsupported: return .failure(.unsupported)
        @unknown default: return .failure(.unsupported)
        }
        let session = TranslationSession(installedSource: src, target: dst)
        do {
            let r = try await session.translate(text)
            return .success(r.targetText)
        } catch {
            switch error {
            case TranslationError.notInstalled: return .failure(.notInstalled)
            case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
                 TranslationError.unsupportedTargetLanguage: return .failure(.unsupported)
            case TranslationError.unableToIdentifyLanguage: return .failure(.unknownLanguage)
            default:
                TouchLog.write("translate failed: \(type(of: error))")
                return .failure(.failed)
            }
        }
        #else
        return .failure(.unsupported)
        #endif
    }
}
