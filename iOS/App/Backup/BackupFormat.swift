// BackupFormat — file sao lưu một tệp khi đổi máy (iOS ⇄ Android ⇄ iOS).
//
// Định dạng JSON (UTF-8), GIỐNG HỆT bản Kotlin android/keyboard/.../Backup.kt —
// fixture chung docs/backup/fixtures/*.json được test ở cả hai nền tảng:
//
// {
//   "format": "viettelex-backup",   // bắt buộc — nhận diện file
//   "version": 1,                   // phiên bản người ghi
//   "minReaderVersion": 1,          // người đọc cũ hơn số này ⇒ từ chối (đổi không tương thích)
//   "createdAt": "2026-09-27T08:00:00Z",
//   "platform": "ios" | "android" | "macos",
//   "settings":  { "simpleTelex": true, …, "rowHeightAdjust": 0 },
//   "shortcuts": { "ko": "không", … },                    // gõ tắt: trigger → cụm từ
//   "templates": [ { "label": "👋", "text": "Chào buổi sáng" }, … ],
//   "learnedWords": { "uni": {…}, "bi": {…}, "tri": {…} }  // TUỲ CHỌN (riêng tư)
// }
//
// Quy tắc tương thích: thiếu mục nào = không đụng mục đó khi nhập; key/trường lạ bị
// bỏ qua (bản mới thêm trường không làm bản cũ hỏng); setting sai kiểu bị bỏ qua.
// Tên setting là tên CHUẨN (theo Android Keys) — iOS map "reEditWord" cục bộ.
import Foundation

enum BackupSettingKind: Equatable {
    case bool(Bool), int(Int, ClosedRange<Int>)
    /// Chuỗi trong tập giá trị cho phép (mặc định, cho phép) — giá trị lạ bị bỏ qua.
    case string(String, [String])
}

/// Setting được sao lưu/đồng bộ. KHÔNG gồm: debugTouchLog, trạng thái nội bộ
/// (kbFullAccess, suggestionBarCollapsed…), công tắc đồng bộ iCloud của chính máy.
enum BackupSettings {
    struct Spec { let key: String; let kind: BackupSettingKind }
    static let all: [Spec] = [
        Spec(key: "simpleTelex", kind: .bool(true)),
        Spec(key: "freeMarking", kind: .bool(true)),
        Spec(key: "quickTelex", kind: .bool(false)),
        Spec(key: "modernTone", kind: .bool(false)),
        Spec(key: "contextualEnglish", kind: .bool(true)),
        Spec(key: "reEditWords", kind: .bool(true)),
        Spec(key: "autoFixAdjacent", kind: .bool(true)),
        Spec(key: "teencode", kind: .bool(false)),
        Spec(key: "autoRestore", kind: .bool(true)),
        Spec(key: "liveSpellCheck", kind: .bool(true)),
        Spec(key: "swipeTyping", kind: .bool(false)),
        Spec(key: "swipeEnglish", kind: .bool(true)),
        Spec(key: "hardwareTelex", kind: .bool(true)),   // chỉ Android dùng
        Spec(key: "showSuggestions", kind: .bool(true)),
        Spec(key: "filterSensitive", kind: .bool(true)),
        Spec(key: "templatesEnabled", kind: .bool(true)),
        Spec(key: "showSpaceLogo", kind: .bool(true)),
        Spec(key: "hapticFeedback", kind: .bool(false)),
        Spec(key: "hapticStrength", kind: .int(45, 10...100)),
        Spec(key: "keySound", kind: .bool(false)),
        Spec(key: "keySoundVolume", kind: .int(50, 0...100)),
        // Kiểu âm phím; "custom" đi theo nhưng FILE âm không — máy mới thiếu file ⇒ bàn phím dùng mặc định.
        Spec(key: "keySoundStyle", kind: .string("subtle", ["subtle", "wood", "mechanical", "typewriter", "bubble", "custom"])),
        Spec(key: "numberRow", kind: .bool(false)),
        Spec(key: "rowHeightAdjust", kind: .int(0, -10...10)),
        Spec(key: "keyboardRaise", kind: .int(0, 0...48)),   // "Nâng bàn phím" (cùng khoá Android)
        Spec(key: "shortcutsEnabled", kind: .bool(true)),
        Spec(key: "addTonesChip", kind: .bool(false)),
        Spec(key: "numberChips", kind: .bool(true)),
        Spec(key: "mathResults", kind: .bool(true)),
        Spec(key: "textToolsEnabled", kind: .bool(true)),   // công tắc Công cụ văn bản (Plus)
        Spec(key: "suggestInNoSuggestFields", kind: .bool(true)),
        Spec(key: "emojiSuggest", kind: .bool(true)),    // chỉ iOS dùng
        Spec(key: "pasteButton", kind: .bool(true)),     // chỉ iOS dùng
        Spec(key: "smartTouch", kind: .bool(true)),
        Spec(key: "autoCorrect", kind: .bool(false)),
        Spec(key: "autoCapitalize", kind: .bool(true)),
        Spec(key: "spaceSwipeLanguage", kind: .bool(false)),
        Spec(key: "longPressNumbers", kind: .bool(true)),
        Spec(key: "longPressSymbols", kind: .bool(false)),
        Spec(key: "autoSpaceAfterPunct", kind: .bool(false)),
        Spec(key: "keyboardTransparency", kind: .int(0, 0...100)),
        Spec(key: "keyLabelTransparency", kind: .int(0, 0...100)),
        // "Nền theo hệ thống" từng theme có nền riêng (chỉ iOS dùng) — systemBackdropOled…
        Spec(key: "systemBackdropOled", kind: .bool(false)),
        Spec(key: "systemBackdropContrast", kind: .bool(false)),
        Spec(key: "systemBackdropPeach", kind: .bool(false)),
        Spec(key: "systemBackdropMint", kind: .bool(false)),
        Spec(key: "systemBackdropSky", kind: .bool(false)),
        Spec(key: "systemBackdropLavender", kind: .bool(false)),
        // Ngôn ngữ giao diện app (L10n) — mặc định "vi", không theo máy.
        Spec(key: "uiLanguage", kind: .string("vi", ["vi", "en"])),
    ]
    static let byKey: [String: Spec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
}

enum SettingValue: Equatable {
    case bool(Bool), int(Int), string(String)

    /// Dạng chuỗi ổn định cho sổ đồng bộ ("true"/"false"/"-3"/"en").
    var syncString: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
    /// Parse theo spec của key; nil = sai kiểu / ngoài phạm vi kiểu.
    static func fromSyncString(_ s: String, key: String) -> SettingValue? {
        guard let spec = BackupSettings.byKey[key] else { return nil }
        switch spec.kind {
        case .bool: return s == "true" ? .bool(true) : s == "false" ? .bool(false) : nil
        case .int(_, let r): return Int(s).map { .int(min(max($0, r.lowerBound), r.upperBound)) }
        case .string(_, let allowed): return allowed.contains(s) ? .string(s) : nil
        }
    }
}

struct BackupTemplate: Equatable { var label: String; var text: String }

/// Từ đã học — cùng cấu trúc UserLangModel iOS/Android (tri key = "p2\u{1}p1").
struct LearnedWords: Equatable {
    var uni: [String: Int] = [:]
    var bi: [String: [String: Int]] = [:]
    var tri: [String: [String: Int]] = [:]
    /// Từ thêm tay (Từ điển cá nhân), dạng hiển thị ("VietTelex"). JSON: "manual" (tuỳ chọn).
    var manual: [String] = []
    var isEmpty: Bool { uni.isEmpty && bi.isEmpty && tri.isEmpty && manual.isEmpty }

    /// Gộp khi nhập: lấy count LỚN hơn mỗi mục (nhập lại cùng file không nhân đôi).
    func merged(with o: LearnedWords) -> LearnedWords {
        func m1(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
            a.merging(b) { max($0, $1) }
        }
        func m2(_ a: [String: [String: Int]], _ b: [String: [String: Int]]) -> [String: [String: Int]] {
            a.merging(b) { m1($0, $1) }
        }
        // Từ thêm tay: hợp theo lowercase, giữ dạng hiển thị đang có.
        var seen = Set<String>(), man: [String] = []
        for w in manual + o.manual where seen.insert(w.lowercased()).inserted { man.append(w) }
        return LearnedWords(uni: m1(uni, o.uni), bi: m2(bi, o.bi), tri: m2(tri, o.tri), manual: man)
    }
}

struct BackupPayload: Equatable {
    var createdAt: Date?
    var platform: String?
    /// nil = file không có mục này (nhập thì không đụng).
    var settings: [String: SettingValue]?
    var shortcuts: [String: String]?
    var templates: [BackupTemplate]?
    var learnedWords: LearnedWords?
}

enum BackupError: Error, Equatable {
    case notJSON, notBackup, tooNew(Int)

    var message: String {
        switch self {
        case .notJSON: return L("File không phải JSON hợp lệ.")
        case .notBackup: return L("Không phải file sao lưu VietTelex.")
        case .tooNew(let v): return L("File sao lưu từ phiên bản mới hơn (định dạng %@) — hãy cập nhật VietTelex.", v)
        }
    }
}

enum BackupCodec {
    static let format = "viettelex-backup"
    static let version = 1
    /// Giới hạn đọc (file tự ghi thường < 1 MB kể cả từ đã học).
    static let maxBytes = 8 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func encode(_ p: BackupPayload) -> Data {
        var root: [String: Any] = [
            "format": format, "version": version, "minReaderVersion": 1,
        ]
        if let d = p.createdAt { root["createdAt"] = iso.string(from: d) }
        if let pl = p.platform { root["platform"] = pl }
        if let s = p.settings {
            var o: [String: Any] = [:]
            for (k, v) in s {
                switch v { case .bool(let b): o[k] = b; case .int(let i): o[k] = i; case .string(let t): o[k] = t }
            }
            root["settings"] = o
        }
        if let sc = p.shortcuts { root["shortcuts"] = sc }
        if let t = p.templates { root["templates"] = t.map { ["label": $0.label, "text": $0.text] } }
        if let lw = p.learnedWords {
            var o: [String: Any] = ["uni": lw.uni, "bi": lw.bi, "tri": lw.tri]
            if !lw.manual.isEmpty { o["manual"] = lw.manual }
            root["learnedWords"] = o
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    static func decode(_ data: Data) throws -> BackupPayload {
        guard data.count <= maxBytes else { throw BackupError.notBackup }
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }   // BOM
        guard let obj = try? JSONSerialization.jsonObject(with: d),
              let root = obj as? [String: Any] else { throw BackupError.notJSON }
        guard root["format"] as? String == format else { throw BackupError.notBackup }
        if let min = intValue(root["minReaderVersion"]), min > version {
            throw BackupError.tooNew(intValue(root["version"]) ?? min)
        }
        var p = BackupPayload()
        p.createdAt = (root["createdAt"] as? String).flatMap { iso.date(from: $0) }
        p.platform = root["platform"] as? String
        if let s = root["settings"] as? [String: Any] {
            var out: [String: SettingValue] = [:]
            for (k, raw) in s {
                guard let spec = BackupSettings.byKey[k] else { continue }   // key lạ: bỏ
                switch spec.kind {
                case .bool:
                    if let b = boolValue(raw) { out[k] = .bool(b) }
                case .int(_, let r):
                    if let i = intValue(raw) { out[k] = .int(min(max(i, r.lowerBound), r.upperBound)) }
                case .string(_, let allowed):
                    if let t = raw as? String, allowed.contains(t) { out[k] = .string(t) }
                }
            }
            p.settings = out
        }
        if let sc = root["shortcuts"] as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in sc {
                let key = k.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, let s = v as? String, !s.isEmpty { out[key] = s }
            }
            p.shortcuts = out
        }
        if let arr = root["templates"] as? [Any] {
            var out: [BackupTemplate] = []
            for e in arr {
                guard let o = e as? [String: Any], let t = o["text"] as? String, !t.isEmpty,
                      !out.contains(where: { $0.text == t }) else { continue }
                out.append(BackupTemplate(label: o["label"] as? String ?? "", text: t))
            }
            p.templates = out
        }
        if let lw = root["learnedWords"] as? [String: Any] {
            p.learnedWords = LearnedWords(uni: counts(lw["uni"]), bi: nested(lw["bi"]), tri: nested(lw["tri"]),
                                          manual: (lw["manual"] as? [Any] ?? []).compactMap {
                                              ($0 as? String).flatMap(UserLangModel.normalizeManual)
                                          })
        }
        return p
    }

    // JSONSerialization trả NSNumber cho cả bool lẫn số — phân biệt bằng CFBoolean.
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
    private static func boolValue(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, isBool(n) else { return nil }
        return n.boolValue
    }
    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return n.intValue
    }
    private static func counts(_ v: Any?) -> [String: Int] {
        guard let o = v as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (k, raw) in o { if let c = intValue(raw), c > 0, !k.isEmpty { out[k] = c } }
        return out
    }
    private static func nested(_ v: Any?) -> [String: [String: Int]] {
        guard let o = v as? [String: Any] else { return [:] }
        var out: [String: [String: Int]] = [:]
        for (k, raw) in o { let c = counts(raw); if !c.isEmpty { out[k] = c } }
        return out
    }
}

/// Kết quả gộp khi nhập file (thuần — store chỉ việc ghi). Chính sách:
/// - settings: file ghi đè từng key có trong file;
/// - gõ tắt: gộp, cùng trigger thì bản trong file thắng (đang khôi phục);
/// - mẫu câu: gộp, bỏ trùng theo câu (như Import YAML);
/// - từ đã học: gộp lấy count lớn hơn.
enum BackupMerge {
    static func shortcuts(current: [String: String], imported: [String: String]) -> [String: String] {
        current.merging(imported) { _, new in new }
    }
    static func templates(current: [BackupTemplate], imported: [BackupTemplate]) -> [BackupTemplate] {
        var out = current
        for t in imported where !out.contains(where: { $0.text == t.text }) { out.append(t) }
        return out
    }

    /// Mô tả ngắn cho người dùng sau khi nhập.
    static func summary(_ p: BackupPayload, templatesAdded: Int, shortcutsChanged: Int) -> String {
        var parts: [String] = []
        if let s = p.settings, !s.isEmpty { parts.append(L("%@ cài đặt", s.count)) }
        if p.shortcuts != nil { parts.append(L("%@ gõ tắt", shortcutsChanged)) }
        if p.templates != nil { parts.append(L("%@ mẫu câu mới", templatesAdded)) }
        if let lw = p.learnedWords, !lw.isEmpty { parts.append(L("%@ từ đã học", lw.uni.count)) }
        return parts.isEmpty ? L("File không có dữ liệu để nhập.") : L("Đã nhập %@.", parts.joined(separator: ", "))
    }
}
