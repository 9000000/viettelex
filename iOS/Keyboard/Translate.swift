// Dịch trên máy (Plus) — chip "Dịch ↔ <đích>" trong danh sách Công cụ văn bản.
// RIÊNG TƯ: chỉ dùng Apple Translation với gói ngôn ngữ ĐÃ CÀI trên máy
// (TranslationSession(installedSource:target:), iOS 26+) — không mạng, không server.
// Bàn phím không tự tải gói được (session kiểu này canRequestDownloads == false) ⇒ báo
// người dùng mở app (App/Plus/TranslateSettingsView.swift).
// KHÔNG TỐN GÌ khi không dùng: Translation/NaturalLanguage chỉ chạm tới khi bấm chip;
// session là biến cục bộ, nhả ngay sau một lần dịch. Luật chiều dịch: Shared/TranslatePrefs.swift.
import Foundation
import NaturalLanguage
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

    // MARK: nhận ra tiếng Việt (rẻ, chắc) trước khi hỏi NaturalLanguage

    /// Từ mang dấu CHỈ tiếng Việt có: đ, móc (ơ ư), trăng (ă), dấu hỏi (̉), dấu nặng (̣),
    /// hoặc nguyên âm mang hai dấu (ấ ề ổ…). Sắc/huyền/ngã/mũ đứng một mình không tính
    /// (tiếng Pháp, Bồ Đào Nha… cũng có).
    static func isVietnameseMarked(_ word: Substring) -> Bool {
        var marksOnLetter = 0
        for c in String(word).decomposedStringWithCanonicalMapping.unicodeScalars {
            switch c.value {
            case 0x0111, 0x0110, 0x0309, 0x0323, 0x031B, 0x0306: return true
            case 0x0300...0x036F:
                marksOnLetter += 1
                if marksOnLetter >= 2 { return true }
            default: marksOnLetter = 0
            }
        }
        return false
    }

    /// ≥ 1/4 số từ (và ít nhất một từ) mang dấu riêng của tiếng Việt.
    static func looksVietnamese(_ s: String) -> Bool {
        let words = s.split(whereSeparator: { !$0.isLetter })
        guard !words.isEmpty else { return false }
        let marked = words.filter(isVietnameseMarked).count
        return marked > 0 && marked * 4 >= words.count
    }

    /// Ngôn ngữ của đoạn chữ ("vi", "en", "ja", "zh-Hant"…) hoặc nil khi không chắc.
    /// NaturalLanguage chạy trên máy; chỉ gọi khi bấm Dịch.
    static func detect(_ s: String) -> String? {
        if looksVietnamese(s) { return TranslatePrefs.vietnamese }
        let r = NLLanguageRecognizer()
        let langs = Set(([TranslatePrefs.vietnamese] + TranslatePrefs.knownTargets).map(TranslatePrefs.base))
        r.languageConstraints = langs.subtracting(["zh"]).map { NLLanguage(rawValue: $0) }
            + [.simplifiedChinese, .traditionalChinese]
        r.processString(s)
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        switch lang {
        case .simplifiedChinese: return "zh"
        case .traditionalChinese: return "zh-TW"
        default: return lang.rawValue
        }
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
