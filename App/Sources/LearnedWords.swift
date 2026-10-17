// LearnedWords.swift — kho "Học từ bạn gõ" của macOS (mô hình: LearnedModel.swift, dùng chung
// Linux). Bật/tắt: Cài đặt → Gợi ý cạnh con trỏ → "Học từ bạn gõ" (AppState.learnWords, mặc định
// BẬT như iOS — học đi theo gợi ý), nút "Xoá từ đã học…". Chỉ có tác dụng khi gợi ý từ chạy:
// cài đặt hệ thống "Show inline predictive text" (SystemInlinePrediction) bật.
//
// LUỒNG (ưu tiên số 1 là mượt):
//   • phím: controller giữ một LearnTracker (so chuỗi, không cấp phát lớn); ở ranh giới từ nó
//     trả lượt học ⇒ `record` chỉ `async` lên hàng đợi nền của CaretHint (`work`, nối tiếp —
//     cùng hàng đợi xếp hạng gợi ý ⇒ không khoá). Cập nhật mô hình O(log n) mỗi từ.
//   • lưu: hẹn 5 s sau lượt học cuối (gộp), chụp bảng COW trên `work`, encode VTL2 + ghi
//     NGUYÊN TỬ trên hàng đợi .utility riêng. Nạp lười lần đầu cần (trên `work`).
//   • tắt (công tắc / cài đặt hệ thống): không nạp, không học — mỗi ranh giới một lần đọc cờ;
//     đang nạp thì lưu nốt rồi bỏ khỏi RAM.
// File: ~/Library/Application Support/<bundle id>/learned-words.bin (VTL2, CRC32; hỏng ⇒ bắt đầu
// lại rỗng). Không mạng, không iCloud (công tắc cũng không đồng bộ).
import Foundation

final class LearnedWords {
    static let shared = LearnedWords()

    /// Gộp lượt lưu: ghi sau chừng này giây kể từ lượt học cuối.
    static let saveDelay: TimeInterval = 5

    static var defaultURL: URL {
        // Test host: KHÔNG BAO GIỜ đụng kho thật của bản Dev đang cài trên máy.
        if isTestHost {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("viettelex-learned-tests-\(getpid())", isDirectory: true)
                .appendingPathComponent(LearnedModel.fileName)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let id = Bundle.main.bundleIdentifier ?? "com.viettelex.inputmethod.telex"
        return base.appendingPathComponent(id, isDirectory: true).appendingPathComponent(LearnedModel.fileName)
    }

    /// Mọi trạng thái dưới đây: CHỈ trên `queue` (= hàng đợi nền CaretHint).
    private let queue: DispatchQueue
    private let io = DispatchQueue(label: "com.viettelex.learned.io", qos: .utility)
    private let url: URL
    private var model: LearnedModel?
    private var saveGen = 0

    /// Thế hệ dữ liệu (xoá ⇒ +1): controller bỏ lượt học CHỜ của thế hệ cũ. Bất kỳ thread.
    private let genLock = NSLock()
    private var gen = 0                      // guarded by genLock
    /// Đếm click chuột (tap) — con trỏ có thể đã dời: ngữ cảnh học bị cắt. Bất kỳ thread.
    private var clicks: UInt64 = 0           // guarded by genLock

    init(queue: DispatchQueue? = nil, url: URL? = nil) {
        self.queue = queue ?? CaretHint.shared.work
        self.url = url ?? Self.defaultURL
    }

    var generation: Int { genLock.withLock { gen } }
    var clickCount: UInt64 { genLock.withLock { clicks } }
    func noteClick() { genLock.withLock { clicks &+= 1 } }

    // MARK: trên `queue`

    /// Mô hình cho xếp hạng (nạp lười). Gọi trên `queue`.
    func modelForRanking() -> LearnedModel {
        if let m = model { return m }
        // File hỏng ⇒ bắt đầu rỗng (ghi đè ở lần lưu kế).
        let m = LearnedModel.load(from: url, isKnownWord: { VNSuggest.contains($0) }).model
        model = m
        if m.changes > 0 { scheduleSave() }      // decay vừa áp
        return m
    }

    var isLoadedForTesting: Bool { queue.sync { model != nil } }
    var fileURLForTesting: URL { url }
    /// Test: đọc mô hình trên `queue` (sau mọi lượt học đã xếp hàng).
    func withModelForTesting<T>(_ f: (LearnedModel) -> T) -> T { queue.sync { f(modelForRanking()) } }
    /// Test: về trạng thái rỗng (RAM + file), đồng bộ.
    func resetForTesting() {
        queue.sync { saveGen += 1; model = nil }
        io.sync { LearnedModel.removeFile(at: url) }
    }

    // MARK: bất kỳ thread

    /// Một lượt học (đã qua mọi cổng ở controller). Không chặn: chỉ `async`.
    func record(_ e: LearnTracker.Event, generation g: Int) {
        queue.async { [self] in
            guard g == generation else { return }
            modelForRanking().record(word: e.form.isEmpty ? e.word : e.form, after: e.prev1, prev2: e.prev2,
                                     weight: e.weight, caseEvidence: !e.form.isEmpty && e.caseEvidence)
            scheduleSave()
        }
    }

    /// "Xoá từ đã học": RAM + file, huỷ lượt lưu đang hẹn; lượt chờ ở controller bị bỏ (thế hệ).
    func clearAll() {
        genLock.withLock { gen += 1 }
        queue.async { [self] in
            saveGen += 1
            if model != nil { model = LearnedModel(isKnownWord: { VNSuggest.contains($0) }) }
            let u = url
            io.async { LearnedModel.removeFile(at: u) }
        }
    }

    /// Công tắc / cài đặt hệ thống vừa tắt: lưu nốt (nếu có đổi) rồi bỏ khỏi RAM.
    func unload() {
        queue.async { [self] in
            guard let m = model else { return }
            if m.changes > 0 { saveNow(m) }
            model = nil
        }
    }

    /// Ghi ngay mọi thay đổi chờ (thoát app). Đồng bộ — chỉ dùng khi thoát / test.
    func flush() {
        queue.sync { if let m = model, m.changes > 0 { saveNow(m) } }
        io.sync {}
    }

    // MARK: lưu

    private func scheduleSave() {
        saveGen += 1
        let g = saveGen
        queue.asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            guard let self, g == self.saveGen, let m = self.model, m.changes > 0 else { return }
            self.saveNow(m)
        }
    }

    private func saveNow(_ m: LearnedModel) {
        saveGen += 1
        let snap = m.snapshot()
        m.markSaved()
        let u = url
        io.async { LearnedModel.write(snap.encoded(), to: u) }
    }
}
