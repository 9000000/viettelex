// Phần DUY NHẤT chạm Apple Translation — tách khỏi Translate.swift (14/10/2026) để bàn phím
// iOS KHÔNG link Translation.framework: link (kể cả weak) là dyld nạp nó + ~33 framework phụ
// thuộc (AppIntents, Speech, ContextKit…) ngay lúc extension khởi động, dù không bao giờ dịch.
//
// - iOS: file này (iOS/VTTranslate/) là framework nhỏ `VTTranslate.framework` nhúng ở app chủ
//   (VietTelex.app/Frameworks/). Bàn phím `dlopen` nó lần đầu bấm chip Dịch
//   (Keyboard/Translate.swift `TranslateLoader`) và gọi qua hàm C `vt_translate` — không
//   link lúc build. Extension không được chứa thư mục Frameworks riêng (App Store
//   ITMS-90206) nên framework nằm ở app chủ, như framework dùng chung thông thường.
// - macOS: biên dịch thẳng vào app (project.yml gốc) — `OnDeviceTranslator` gọi trực tiếp.
//
// Không phụ thuộc file nào khác (framework chỉ có file này): vào là chuỗi, ra là mã số.
import Foundation
#if canImport(Translation)
import Translation
#endif

/// Mã kết quả — khớp `TranslateFailure.init?(engineCode:)` ở Translate.swift.
enum TranslateEngineCode {
    static let ok: Int32 = 0
    static let notInstalled: Int32 = 1
    static let unsupported: Int32 = 2
    static let unknownLanguage: Int32 = 3
    static let failed: Int32 = 4
}

enum TranslateEngine {
    /// Dịch một lần. Kiểm tra gói đã cài TRƯỚC (LanguageAvailability, không tạo session);
    /// session sống trong hàm này rồi được nhả. Trả (mã, bản dịch khi ok / tên kiểu lỗi khi failed).
    static func run(_ text: String, source: String, target: String) async -> (code: Int32, text: String?) {
        #if canImport(Translation)
        guard #available(iOS 26.0, macOS 26.0, *) else { return (TranslateEngineCode.unsupported, nil) }
        let src = Locale.Language(identifier: source)
        let dst = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: src, to: dst) {
        case .installed: break
        case .supported: return (TranslateEngineCode.notInstalled, nil)
        case .unsupported: return (TranslateEngineCode.unsupported, nil)
        @unknown default: return (TranslateEngineCode.unsupported, nil)
        }
        let session = TranslationSession(installedSource: src, target: dst)
        do {
            let r = try await session.translate(text)
            return (TranslateEngineCode.ok, r.targetText)
        } catch {
            switch error {
            case TranslationError.notInstalled: return (TranslateEngineCode.notInstalled, nil)
            case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
                 TranslationError.unsupportedTargetLanguage: return (TranslateEngineCode.unsupported, nil)
            case TranslationError.unableToIdentifyLanguage: return (TranslateEngineCode.unknownLanguage, nil)
            default: return (TranslateEngineCode.failed, "\(type(of: error))")
            }
        }
        #else
        return (TranslateEngineCode.unsupported, nil)
        #endif
    }
}

#if VT_TRANSLATE_FRAMEWORK
/// Callback C: (ctx, mã, chuỗi UTF-8 — bản dịch hoặc tên lỗi, có thể nil). Gọi đúng MỘT lần,
/// từ luồng bất kỳ; chuỗi chỉ sống trong lúc gọi.
public typealias VTTranslateCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void

/// Điểm vào cho `dlsym` (Keyboard/Translate.swift `TranslateLoader`). Chép chuỗi vào ngay
/// trước khi trả về (caller nhả bộ đệm ngay sau lời gọi).
@_cdecl("vt_translate")
public func vt_translate(_ text: UnsafePointer<CChar>, _ source: UnsafePointer<CChar>,
                         _ target: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?,
                         _ callback: VTTranslateCallback) {
    let t = String(cString: text), s = String(cString: source), d = String(cString: target)
    Task.detached(priority: .userInitiated) {
        let r = await TranslateEngine.run(t, source: s, target: d)
        if let out = r.text {
            out.withCString { callback(ctx, r.code, $0) }
        } else {
            callback(ctx, r.code, nil)
        }
    }
}
#endif
