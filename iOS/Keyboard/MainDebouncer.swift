// MainDebouncer — MỘT DispatchSourceTimer dùng lại cho việc hoãn ngắn mỗi phím (gợi ý
// ~30 ms sau phím cuối). Trước: mỗi phím `DispatchQueue.main.asyncAfter` = một block +
// một timer mới trong libdispatch. Giờ: `schedule` chỉ hẹn lại cùng timer (không cấp phát),
// phím mới tới trước hạn ⇒ hạn dời theo phím mới (y như gen-check cũ bỏ lượt cũ).
import Foundation

final class MainDebouncer {
    private let timer: DispatchSourceTimer
    private var armed = false
    /// Số lần thực sự chạy (test).
    private(set) var fireCount = 0
    var action: (() -> Void)?

    init(queue: DispatchQueue = .main) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self, self.armed else { return }
            self.armed = false
            self.fireCount += 1
            self.action?()
        }
        timer.resume()
    }

    /// Hẹn (hoặc dời) lần chạy tới `delay` giây kể từ bây giờ.
    func schedule(after delay: TimeInterval) {
        armed = true
        timer.schedule(deadline: .now() + delay, repeating: .never)
    }

    func cancel() {
        armed = false
        timer.schedule(deadline: .distantFuture, repeating: .never)
    }

    var isArmed: Bool { armed }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}
