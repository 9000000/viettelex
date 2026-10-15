// Lịch sử clipboard — model THUẦN (không UIKit, không đọc UIPasteboard).
// Lưu CHỈ trên máy: file JSON trong container riêng của extension (không App
// Group, không mạng). Hợp đồng chung với Android keyboard/ClipboardHistory.kt:
// tối đa 20 mục, mục không ghim hết hạn sau 1 giờ, mục "giống bí mật" sau 2 phút,
// ghim không hết hạn, trùng text → đưa lên đầu (giữ ghim).
import Foundation

struct ClipItem: Codable, Equatable {
    var text: String
    var at: TimeInterval          // giây (timeIntervalSince1970)
    var pinned: Bool
    var sensitive: Bool
}

final class ClipboardHistory {
    let maxItems: Int
    let ttl: TimeInterval
    let sensitiveTTL: TimeInterval
    /// Mục dài hơn bị bỏ qua. 4000 cũ làm văn bản nhiều đoạn copy xong "không được lưu"
    /// (tester Plus 15/10/2026); 20 mục × 10k ký tự vẫn nhỏ so với trần RAM extension.
    static let maxTextLength = 10_000
    static let freshWindow: TimeInterval = 180

    private(set) var raw: [ClipItem] = []     // mới nhất trước
    private let fileURL: URL?

    init(fileURL: URL?, maxItems: Int = 20, ttl: TimeInterval = 3600, sensitiveTTL: TimeInterval = 120) {
        self.fileURL = fileURL
        self.maxItems = maxItems
        self.ttl = ttl
        self.sensitiveTTL = sensitiveTTL
        if let u = fileURL, let data = try? Data(contentsOf: u),
           let items = try? JSONDecoder().decode([ClipItem].self, from: data) {
            raw = items
        }
    }

    /// File mặc định: Application Support của extension (container riêng).
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("clipboard-history.json")
    }

    /// Thêm mục; trả về true nếu danh sách đổi. Rỗng / quá dài → bỏ qua.
    @discardableResult
    func add(_ text: String, now: TimeInterval, sensitive: Bool? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxTextLength else { return false }
        let s = sensitive ?? ClipSensitivity.looksSecret(text)
        var pinned = false
        if let i = raw.firstIndex(where: { $0.text == text }) {
            pinned = raw[i].pinned
            raw.remove(at: i)
        }
        raw.insert(ClipItem(text: text, at: now, pinned: pinned, sensitive: s && !pinned), at: 0)
        while raw.count > maxItems, let i = raw.lastIndex(where: { !$0.pinned }) {
            raw.remove(at: i)
        }
        return true
    }

    /// Bỏ mục không ghim đã hết hạn; true nếu có mục bị bỏ.
    @discardableResult
    func prune(now: TimeInterval) -> Bool {
        let before = raw.count
        raw.removeAll { !$0.pinned && now - $0.at > ($0.sensitive ? sensitiveTTL : ttl) }
        return raw.count != before
    }

    /// Danh sách hiển thị: ghim lên trên, rồi mới nhất trước.
    func items(now: TimeInterval) -> [ClipItem] {
        prune(now: now)
        return raw.filter(\.pinned) + raw.filter { !$0.pinned }
    }

    /// Ghim/bỏ ghim. `limit` = số mục ghim tối đa (nil = không giới hạn —
    /// `PlusGate.pinnedClipLimit`); đầy thì KHÔNG ghim thêm, trả false (bỏ ghim luôn được).
    @discardableResult
    func togglePin(_ text: String, limit: Int? = nil) -> Bool {
        guard let i = raw.firstIndex(where: { $0.text == text }) else { return false }
        if !raw[i].pinned, let l = limit, pinnedCount >= l { return false }
        raw[i].pinned.toggle()
        if raw[i].pinned { raw[i].sensitive = false }   // user chủ động giữ
        return true
    }

    var pinnedCount: Int { raw.filter(\.pinned).count }

    func remove(_ text: String) { raw.removeAll { $0.text == text } }

    /// "Xoá hết": xoá mục KHÔNG ghim (ghim chỉ bỏ bằng nút riêng).
    func clearUnpinned() { raw.removeAll { !$0.pinned } }

    func removeAll() { raw.removeAll() }

    /// Mục mới nhất nếu vừa thêm trong 3 phút (nguồn cho chip STK/SĐT/OTP).
    func latestFresh(now: TimeInterval, window: TimeInterval = ClipboardHistory.freshWindow) -> ClipItem? {
        guard let first = raw.max(by: { $0.at < $1.at }), now - first.at <= window else { return nil }
        return first
    }

    func save() {
        guard let u = fileURL else { return }
        if raw.isEmpty { try? FileManager.default.removeItem(at: u); return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Tắt tính năng → xoá sạch file (riêng tư).
    static func wipe(at url: URL?) {
        if let u = url { try? FileManager.default.removeItem(at: u) }
    }
}
