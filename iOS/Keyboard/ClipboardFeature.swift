// Luồng lịch sử clipboard + chip + ẩn danh — THUẦN (không UIKit, không đọc
// UIPasteboard): controller đưa changeCount/nội dung vào, hỏi lại quyết định.
// Tách riêng để test luồng không cần bàn phím thật.
import Foundation

/// Phần clipboard hệ thống bàn phím đọc (UIPasteboard.general; test thay bằng bản giả).
/// changeCount / hasStrings / types không bật hỏi "Cho phép dán?"; `string` thì có.
protocol PasteboardSource: AnyObject {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    var string: String? { get }
    var types: [String] { get }
}

final class ClipboardFeature {
    /// App Group keys (app ghi, extension chỉ đọc).
    static let historyKey = "clipboardHistory"   // mặc định TẮT
    static let incognitoKey = "incognitoMode"    // mặc định TẮT

    private(set) var historyEnabled = false
    private(set) var incognito = false
    /// Chỉ tạo khi bật (0 RAM khi tắt).
    private(set) var history: ClipboardHistory?
    private let fileURL: URL?

    /// Nội dung clipboard đã biết (đọc được) ứng với changeCount nào.
    private(set) var known: (change: Int, text: String)?

    /// Clipboard nâng cao (Plus): số mục ghim tối đa + chip tách số. Test thay được.
    var pinLimit: () -> Int? = { PlusGate.pinnedClipLimit }
    var chipsUnlocked: () -> Bool = { PlusGate.isUnlocked(.advancedClipboard) }

    init(fileURL: URL? = ClipboardHistory.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Đọc công tắc mỗi lần bàn phím hiện. Tắt lịch sử → xoá file + bỏ RAM.
    func load(historyEnabled h: Bool, incognito i: Bool) {
        historyEnabled = h
        incognito = i
        if h {
            if history == nil { history = ClipboardHistory(fileURL: fileURL) }
        } else {
            if history != nil || fileURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                ClipboardHistory.wipe(at: fileURL)
            }
            history = nil
        }
        if i { known = nil }
    }

    func load(from defaults: UserDefaults?) {
        load(historyEnabled: defaults?.bool(forKey: Self.historyKey) ?? false,
             incognito: defaults?.bool(forKey: Self.incognitoKey) ?? false)
    }

    /// Được GHI vào lịch sử không (bật, không ẩn danh, ô không phải mật khẩu,
    /// clipboard không bị đánh dấu "concealed" bởi trình quản lý mật khẩu).
    func canRecord(secureField: Bool, concealed: Bool) -> Bool {
        historyEnabled && !incognito && !secureField && !concealed
    }

    /// Tự đọc clipboard khi thấy changeCount mới? Chỉ khi được ghi VÀ iOS không hỏi
    /// "Cho phép dán?" (user đã chọn Cho phép) — không thì mỗi lần hiện bàn phím
    /// sẽ bật hộp thoại.
    func shouldAutoRead(fullAccess: Bool, noPrompt: Bool, secureField: Bool, concealed: Bool) -> Bool {
        fullAccess && noPrompt && canRecord(secureField: secureField, concealed: concealed)
    }

    /// Nội dung clipboard vừa đọc được (tự đọc hoặc lúc chạm Dán).
    func captured(_ text: String, change: Int, now: TimeInterval, secureField: Bool, concealed: Bool) {
        guard canRecord(secureField: secureField, concealed: concealed) else { return }
        known = (change, text)
        if let h = history, h.add(text, now: now) { h.save() }
    }

    /// Chip cho clipboard HIỆN TẠI (changeCount khớp nội dung đã biết, chưa dùng).
    func chips(currentChange: Int, usedChange: Int) -> [ClipChip] {
        guard !incognito, chipsUnlocked(), let k = known, k.change == currentChange, k.change != usedChange else { return [] }
        return ClipDetect.detect(k.text)
    }

    func items(now: TimeInterval) -> [ClipItem] {
        guard let h = history else { return [] }
        let changed = h.prune(now: now)
        if changed { h.save() }
        return h.items(now: now)
    }

    /// false = đã đủ số mục ghim miễn phí (không đổi gì).
    @discardableResult
    func togglePin(_ text: String) -> Bool {
        guard let h = history else { return false }
        let ok = h.togglePin(text, limit: pinLimit())
        if ok { h.save() }
        return ok
    }
    func remove(_ text: String) { history?.remove(text); history?.save() }
    func clearUnpinned() { history?.clearUnpinned(); history?.save() }
}
