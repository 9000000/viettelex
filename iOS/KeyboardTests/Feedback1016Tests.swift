// Góp ý người dùng 16/10/2026 (iOS 1.2.13):
//  1. "Bỏ dấu vẫn lag, hình như gõ trong Gmail mới bị" — ô soạn thư Gmail là web view: host
//     báo textWillChange/selectionDidChange/textDidChange MUỘN sau MỖI lệnh sửa của bàn phím
//     (applyingEdit đã false). Trước đây mỗi tiếng vọng đó chạy đồng bộ: đối chiếu từ đang gõ
//     + đọc lại trait ô + auto-shift (đọc context) + tính lại CẢ thanh gợi ý (updateSuggestions
//     ngay trên main, rồi lượt hoãn 30 ms của phím lại tính lần nữa). Giờ: tiếng vọng của edit
//     chính mình (từ đang gõ vẫn nằm nguyên trước con trỏ) ⇒ 0 việc; thay đổi thật ⇒ gộp vào
//     lượt hoãn chung của phím.
//  2. "Zalo sau khi kill thì lần đầu không hiện khung gõ dù bàn phím đã mở" — xem phần 2.
import XCTest
import UIKit

final class Feedback1016Tests: XCTestCase {

    // MARK: 1. Gmail: tiếng vọng host sau mỗi lệnh sửa

    /// Host kiểu web view: sau mỗi phím gửi đủ 4 callback (như Gmail / WKWebView).
    @MainActor private func hostEcho(_ vc: KeyboardViewController) {
        vc.textWillChange(nil)
        vc.selectionWillChange(nil)
        vc.selectionDidChange(nil)
        vc.textDidChange(nil)
    }

    @MainActor private func runToneCorpus(echo: Bool) -> (ctx: Double, traits: Double, passes: Double, text: String) {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        let keys = Array("vieejt tooi ddi hocj cas caf car cax caj nam tieengs vieetj ")
        KeyboardBenchTests.spin(0.05)
        rig.proxy.contextReads = 0; rig.proxy.traitReads = 0
        rig.vc.debugSuggestionPasses = 0
        for c in keys {
            _ = rig.key(c, index: 1, drain: 0)
            if echo { hostEcho(rig.vc) }
            KeyboardBenchTests.spin(0.045)            // > 30 ms: lượt gợi ý hoãn của phím chạy
        }
        let n = Double(keys.count)
        return (Double(rig.proxy.contextReads) / n, Double(rig.proxy.traitReads) / n,
                Double(rig.vc.debugSuggestionPasses) / n, rig.proxy.text)
    }

    /// Ngân sách mỗi phím khi host vọng lại mọi edit (Gmail): đọc context, đọc trait, số lượt
    /// tính thanh gợi ý — phải ngang host không vọng (Ghi chú, Tin nhắn).
    @MainActor func testWebViewEchoAddsNoPerKeyWork() {
        let quiet = runToneCorpus(echo: false)
        let gmail = runToneCorpus(echo: true)
        print(String(format: "ECHOBUDGET quiet ctx=%.2f traits=%.2f passes=%.2f | echo ctx=%.2f traits=%.2f passes=%.2f",
                     quiet.ctx, quiet.traits, quiet.passes, gmail.ctx, gmail.traits, gmail.passes))
        XCTAssertEqual(gmail.text, quiet.text, "tiếng vọng không được đổi chữ gõ ra")
        XCTAssertTrue(gmail.text.lowercased().hasPrefix("việt tôi đi học cá cà cả cã cạ nam tiếng việt"), gmail.text)
        XCTAssertLessThanOrEqual(gmail.passes, quiet.passes + 0.15, "tiếng vọng không được tính lại thanh gợi ý")
        // Một lần đọc context mỗi tiếng vọng để đối chiếu từ đang gõ (bắt chạm chỗ khác / đổi ô);
        // ranh giới từ thêm auto-shift. Trước sửa: 2.45 mỗi phím.
        XCTAssertLessThanOrEqual(gmail.ctx, quiet.ctx + 1.5, "tiếng vọng: chỉ đọc context để đối chiếu từ")
        // Giữa từ: 0 lượt đọc trait; chỉ ở ranh giới từ (không còn từ để đối chiếu) mới đọc lại
        // trait để bắt đổi ô (~1/6 số phím của chuỗi này, 2 callback).
        XCTAssertLessThanOrEqual(gmail.traits, quiet.traits + 0.45, "tiếng vọng giữa từ không đọc lại trait ô")
    }

    /// Tiếng vọng không được nuốt thay đổi THẬT: host xoá ô (gửi tin) giữa lúc đang gõ dở ⇒ từ
    /// bị bỏ, viết hoa đầu câu bật lại, gợi ý tính lại (gộp một lượt).
    @MainActor func testRealHostChangeStillRefreshes() {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        for (i, c) in "xin chaof ban".enumerated() { _ = rig.key(c, index: i + 1, drain: 0.04) }
        XCTAssertEqual(rig.proxy.text, "Xin chào ban")
        rig.proxy.text = ""                                // host xoá ô sau khi gửi
        let passes = rig.vc.debugSuggestionPasses
        hostEcho(rig.vc)
        hostEcho(rig.vc)                                   // hai lượt callback liền ⇒ một lượt tính
        KeyboardBenchTests.spin(0.08)
        // Một lượt gộp cho cả hai tiếng vọng (+ một lượt do Shift tự bật — gợi ý theo Shift).
        XCTAssertGreaterThanOrEqual(rig.vc.debugSuggestionPasses, passes + 1)
        XCTAssertLessThanOrEqual(rig.vc.debugSuggestionPasses, passes + 2)
        _ = rig.key("a", index: 20, drain: 0.04)
        XCTAssertEqual(rig.proxy.text, "A", "từ cũ bị bỏ, chữ đầu ô viết hoa")
    }

    // MARK: 2. Zalo mở lại sau khi kill: bàn phím hiện mà thiếu thanh / rỗng

    func testCycleNormalShowHide() {
        var c = AppearanceCycle()
        c.willAppear()
        XCTAssertFalse(c.didAppear(tornDown: false))
        c.willDisappear()
        XCTAssertTrue(c.didDisappear())
        c.willAppear()
        XCTAssertFalse(c.didAppear(tornDown: false))
    }

    /// Ẩn bị một lần hiện chen ngang: didDisappear tới MUỘN sau willAppear ⇒ không xé.
    func testCycleLateDidDisappearKeepsView() {
        var c = AppearanceCycle()
        c.willAppear(); _ = c.didAppear(tornDown: false)
        c.willDisappear()
        c.willAppear()
        XCTAssertFalse(c.didDisappear(), "đang hiện lại — không được xé")
        XCTAssertFalse(c.didAppear(tornDown: false))
    }

    /// Hiện mà willAppear bị nuốt / view đã xé ⇒ didAppear phải tự cấu hình.
    func testCycleDidAppearWithoutWillAppearConfigures() {
        var c = AppearanceCycle()
        XCTAssertTrue(c.didAppear(tornDown: false), "lần hiện đầu chưa cấu hình")
        c.willDisappear()
        XCTAssertTrue(c.didDisappear())
        XCTAssertTrue(c.didAppear(tornDown: true))
        XCTAssertFalse(c.didAppear(tornDown: false), "đã cấu hình ⇒ không lặp")
        XCTAssertTrue(c.didAppear(tornDown: true), "view bị xé dù đang hiện ⇒ dựng lại")
    }

    /// Controller thật: willDisappear → willAppear → didDisappear (muộn) → didAppear.
    @MainActor func testInterruptedHideKeepsKeyboardAndBar() {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        let vc = rig.vc
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        vc.viewDidDisappear(false)
        vc.viewDidAppear(false)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(vc.debugKeyboard.isTornDown, "bàn phím đang hiện không được bị xé")
        // (_UIInputViewContent của UIKit cũng nằm đây khi gọi thẳng callback — chỉ đếm của mình)
        XCTAssertEqual(vc.view.subviews.filter { $0 is KeyboardView }.count, 1)
        XCTAssertNotNil(vc.debugKeyboard.debugLetterFrame("a"))
        XCTAssertTrue(vc.debugKeyboard.suggestionsShownState, "thanh gợi ý phải hiện")
        _ = rig.key("a", index: 1, drain: 0.01)
        XCTAssertEqual(rig.proxy.text, "A")
    }

    /// Controller thật: hiện lại mà KHÔNG có viewWillAppear (chỉ didAppear) ⇒ dựng + cấu hình.
    @MainActor func testDidAppearWithoutWillAppearRebuildsAndShowsBar() {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        let vc = rig.vc
        vc.viewWillDisappear(false)
        vc.viewDidDisappear(false)
        XCTAssertTrue(vc.debugKeyboard.isTornDown)
        vc.viewDidAppear(false)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(vc.debugKeyboard.isTornDown)
        XCTAssertNotNil(vc.debugKeyboard.debugLetterFrame("a"))
        XCTAssertTrue(vc.debugKeyboard.suggestionsShownState, "thanh gợi ý phải hiện")
    }

    /// Cache controller lệch với view (thanh tắt trên view, controller tưởng đang bật): callback
    /// host kế tiếp phải bật lại thanh dù trait ô không đổi.
    @MainActor func testStaleBarStateReappliedOnHostCallback() {
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = KeyboardBenchTests.makeDefaults("B")
        defer { UserDefaultsProvider.shared = saved }
        let rig = KeyboardBenchTests.Rig()
        defer { rig.close() }
        let kb = rig.vc.debugKeyboard
        XCTAssertTrue(kb.suggestionsShownState)
        kb.setSuggestionsEnabled(false)                 // view lỡ lần áp (dựng mới, chưa cấu hình)
        rig.vc.selectionDidChange(nil)
        XCTAssertTrue(kb.suggestionsShownState, "trait y hệt vẫn phải áp lại thanh")
    }
}
