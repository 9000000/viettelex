// Tester 1.2.10: "Phím sẫm khi bấm" không hiện khi chạm mép trái q / a / 1, mép phải p / l / 0
// và ở ⇧ / ⌫ / 123 / return — còn ô phóng to thì có. Nguyên nhân: phím sát mép màn hình bị
// iOS giữ touch (phân xử cử chỉ hệ thống) rồi giao began + ended CÙNG một vòng runloop ⇒ phím
// sẫm rồi thôi sẫm trước khi lên màn hình. Ô phóng to đã có minVisible (BalloonGeometry), nền
// đè thì chưa. Thêm: ⇧ đổi trạng thái ở touchDown ghi đè nền đè; 123/ABC gỡ phím ngay lúc chạm.
//
// Mỗi điểm chạm: phím SẪM phải đúng là phím NHẬN input (router chữ hoặc nút hitTest chọn), và
// nhấc tay tức thì (giao một lượt như sát mép) vẫn để phím sẫm ≥ minVisible rồi mới thôi.
import XCTest
import UIKit

final class KeyPressHighlightEdgeTests: XCTestCase {
    private let suite = "vt-press-edge-tests"
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor private func withKeyboard(width: CGFloat, numberRow: Bool, highlight: Bool = true,
                                         _ body: (KeyboardView, () -> KeyboardView.Key?) throws -> Void) rethrows {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(highlight, forKey: KeyboardView.keyPressHighlightKey)
        d.set(false, forKey: KeyboardView.keyPreviewKey)
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = d
        defer { UserDefaultsProvider.shared = saved; d.removePersistentDomain(forName: suite) }
        var last: KeyboardView.Key?
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { last = $0 }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.applyAppearance(.light, style: .light)
        kb.numberRowEnabled = numberRow
        kb.keyPressHighlightEnabled = highlight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        try body(kb, { last })
        withExtendedLifetime(host) {}
    }

    private func name(_ b: UIButton?) -> String {
        guard let b else { return "nil" }
        return b.accessibilityLabel ?? b.currentTitle ?? "?"
    }

    /// Chạm tại `p` đi đúng đường thật: hitTest → (router chữ | nút thật). Nhấc tay NGAY (như
    /// touch sát mép bị giao một lượt). Trả phím sẫm lúc đè + phím nhận input.
    @MainActor private func edgeTap(_ kb: KeyboardView, at p: CGPoint, last: () -> KeyboardView.Key?,
                                    expectDeferred: Bool = true, _ ctx: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let hit = kb.debugHitTest(p, time: 1)
        var pressed: [UIButton] = []
        var receiver: UIButton?
        var released: () -> Void = {}
        if hit === kb {
            let token = NSObject(), id = ObjectIdentifier(token)
            kb.debugRouteDown(id, at: p, time: 1)
            pressed = kb.debugPressedKeys()
            guard case .letter(let ch)? = last() else {
                return XCTFail("\(ctx): router không chèn chữ", file: file, line: line)
            }
            receiver = kb.debugLetterButton(String(ch).lowercased())
            released = { kb.debugRouteUp(id, at: p, time: 1); withExtendedLifetime(token) {} }
        } else if let c = hit as? UIButton {
            c.sendActions(for: .touchDown)
            pressed = kb.debugPressedKeys()
            receiver = c
            released = { c.sendActions(for: .touchUpInside) }
        } else {
            return XCTFail("\(ctx): không phím nào nhận chạm (\(String(describing: hit)))", file: file, line: line)
        }
        let r = try XCTUnwrap(receiver, ctx, file: file, line: line)
        if r.isDescendant(of: kb) {
            XCTAssertEqual(pressed.map(name), [name(r)], "\(ctx): phím sẫm ≠ phím nhận input", file: file, line: line)
            XCTAssertTrue(pressed.first === r, "\(ctx): phím sẫm ≠ phím nhận input", file: file, line: line)
        } else {
            // 123/ABC: plane đổi lúc chạm — phím plane mới tại đúng chỗ ngón tay sẫm thay.
            XCTAssertEqual(pressed.count, 1, "\(ctx): phím plane mới phải sẫm", file: file, line: line)
        }
        let shown = pressed
        released()
        if expectDeferred {
            XCTAssertEqual(kb.debugPressedKeys().map(name), shown.map(name),
                           "\(ctx): began+ended một lượt ⇒ vẫn sẫm đủ minVisible", file: file, line: line)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(BalloonGeometry.minVisible + 0.05))
        XCTAssertEqual(kb.debugPressedKeys().map(name), [], "\(ctx): nhả ⇒ hết sẫm", file: file, line: line)
        for b in shown { XCTAssertEqual(kb.debugKeyColors(b).current, kb.debugKeyColors(b).normal, ctx,
                                        file: file, line: line) }
    }

    private func frame(_ kb: KeyboardView, _ c: UIView) -> CGRect { kb.convert(c.bounds, from: c) }

    @MainActor private func runEdgeMatrix(width: CGFloat, numberRow: Bool) throws {
        try withKeyboard(width: width, numberRow: numberRow) { kb, last in
            let ctx = "w=\(width) numberRow=\(numberRow)"
            // Mép trái q / a, mép phải p / l: trong lề, ngoài khung phím (và sát mép màn hình).
            for (s, left) in [("q", true), ("a", true), ("p", false), ("l", false)] {
                let f = try XCTUnwrap(kb.debugLetterFrame(s))
                for x in left ? [f.minX / 2, 0.5, f.minX - 0.5] : [(f.maxX + width) / 2, width - 0.5, f.maxX + 0.5] {
                    try edgeTap(kb, at: CGPoint(x: x, y: f.midY), last: last, "\(ctx) mép \(s) x=\(x)")
                }
            }
            // Khe giữa phím cùng hàng + khe giữa hai hàng.
            let q = try XCTUnwrap(kb.debugLetterFrame("q")), w = try XCTUnwrap(kb.debugLetterFrame("w"))
            let a = try XCTUnwrap(kb.debugLetterFrame("a")), z = try XCTUnwrap(kb.debugLetterFrame("z"))
            let m = try XCTUnwrap(kb.debugLetterFrame("m"))
            try edgeTap(kb, at: CGPoint(x: (q.maxX + w.minX) / 2, y: q.midY), last: last, "\(ctx) khe q|w")
            try edgeTap(kb, at: CGPoint(x: a.midX, y: (q.maxY + a.minY) / 2), last: last, "\(ctx) khe hàng q/a")
            // Phím chức năng: tâm, sát mép màn hình, khe cạnh phím chữ.
            let shift = try XCTUnwrap(kb.debugControl("Shift"))
            let del = try XCTUnwrap(kb.debugControl(L("Xoá")))
            let ret = try XCTUnwrap(kb.debugControl(L("Xuống dòng")))
            let sf = frame(kb, shift), df = frame(kb, del), rf = frame(kb, ret)
            for (f, edgeX, key) in [(sf, CGFloat(0.5), "⇧"), (df, width - 0.5, "⌫"), (rf, width - 0.5, "return")] {
                try edgeTap(kb, at: CGPoint(x: f.midX, y: f.midY), last: last, "\(ctx) \(key) tâm")
                try edgeTap(kb, at: CGPoint(x: edgeX, y: f.midY), last: last, "\(ctx) \(key) mép")
            }
            try edgeTap(kb, at: CGPoint(x: (sf.maxX + z.minX) / 2, y: z.midY), last: last, "\(ctx) khe ⇧|z")
            try edgeTap(kb, at: CGPoint(x: (m.maxX + df.minX) / 2, y: m.midY), last: last, "\(ctx) khe m|⌫")
            // Hàng số: mép trái 1, mép phải 0.
            if numberRow {
                let one = frame(kb, try XCTUnwrap(kb.debugKeyButton("1")))
                let zero = frame(kb, try XCTUnwrap(kb.debugKeyButton("0")))
                try edgeTap(kb, at: CGPoint(x: one.minX / 2, y: one.midY), last: last, "\(ctx) mép 1")
                try edgeTap(kb, at: CGPoint(x: 0.5, y: one.midY), last: last, "\(ctx) mép 1 sát màn hình")
                try edgeTap(kb, at: CGPoint(x: (zero.maxX + width) / 2, y: zero.midY), last: last, "\(ctx) mép 0")
                try edgeTap(kb, at: CGPoint(x: width - 0.5, y: zero.midY), last: last, "\(ctx) mép 0 sát màn hình")
            }
            // 123 (mép trái hàng đáy) ⇒ plane số, ABC tại chỗ ngón sẫm; ABC mép trái ⇒ về chữ.
            let more = try XCTUnwrap(kb.debugControl(L("Số")))
            let mf = frame(kb, more)
            try edgeTap(kb, at: CGPoint(x: 0.5, y: mf.midY), last: last, "\(ctx) 123 mép")
            XCTAssertEqual(kb.debugPlaneName, "numbers", ctx)
            kb.setNeedsLayout(); kb.layoutIfNeeded()   // không window: plane mới cần ép layout
            let abc = try XCTUnwrap(kb.debugControl(L("Chữ")))
            try edgeTap(kb, at: CGPoint(x: 0.5, y: frame(kb, abc).midY), last: last, "\(ctx) ABC mép")
            XCTAssertEqual(kb.debugPlaneName, "letters", ctx)
            kb.setNeedsLayout(); kb.layoutIfNeeded()
            XCTAssertTrue(kb.debugPressedKeys().isEmpty, ctx)
        }
    }

    @MainActor func testEdgeTouchesHighlightTheInputKeyStandardPhone() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        for nr in [false, true] { try runEdgeMatrix(width: 402, numberRow: nr) }
    }

    @MainActor func testEdgeTouchesHighlightTheInputKeyLargePhone() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        for nr in [false, true] { try runEdgeMatrix(width: 440, numberRow: nr) }
    }

    /// Chạm lâu (≥ minVisible) ⇒ thôi sẫm NGAY lúc nhấc, không hẹn giờ.
    @MainActor func testSlowTapReleasesImmediately() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        try withKeyboard(width: 402, numberRow: false) { kb, _ in
            let a = try XCTUnwrap(kb.debugLetterButton("a"))
            a.sendActions(for: .touchDown)
            RunLoop.main.run(until: Date().addingTimeInterval(BalloonGeometry.minVisible + 0.02))
            a.sendActions(for: .touchUpInside)
            XCTAssertFalse(kb.debugReleasePending(a))
            XCTAssertEqual(kb.debugKeyColors(a).current, kb.debugKeyColors(a).normal)
        }
    }

    /// Chạm lại phím đang chờ thôi sẫm ⇒ huỷ hẹn, vẫn sẫm suốt lần đè mới.
    @MainActor func testRepressCancelsPendingRelease() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        try withKeyboard(width: 402, numberRow: false) { kb, _ in
            let a = try XCTUnwrap(kb.debugLetterButton("a"))
            a.sendActions(for: .touchDown)
            a.sendActions(for: .touchUpInside)
            XCTAssertTrue(kb.debugReleasePending(a))
            a.sendActions(for: .touchDown)
            XCTAssertFalse(kb.debugReleasePending(a))
            RunLoop.main.run(until: Date().addingTimeInterval(BalloonGeometry.minVisible + 0.05))
            XCTAssertEqual(kb.debugKeyColors(a).current, kb.debugKeyColors(a).pressed, "đang đè lần 2 ⇒ vẫn sẫm")
            a.sendActions(for: .touchCancel)
            RunLoop.main.run(until: Date().addingTimeInterval(BalloonGeometry.minVisible + 0.05))
            XCTAssertEqual(kb.debugKeyColors(a).current, kb.debugKeyColors(a).normal)
        }
    }

    /// ⇧ đổi trạng thái lúc chạm (applyShiftAppearance) nhưng vẫn sẫm khi đè; nhả ⇒ nền trạng thái mới.
    @MainActor func testShiftKeepsPressedFillWhileHeld() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        try withKeyboard(width: 402, numberRow: false) { kb, _ in
            let shift = try XCTUnwrap(kb.debugControl("Shift") as? UIButton)
            // Hai lần: tự viết hoa đầu câu (bật) → tắt, rồi tắt → bật (cách > 0.3s, không thành caps).
            for _ in 0..<2 {
                let before = kb.debugShiftOn
                shift.sendActions(for: .touchDown)
                XCTAssertNotEqual(kb.debugShiftOn, before)
                XCTAssertEqual(kb.debugKeyColors(shift).current, kb.debugKeyColors(shift).pressed, "đè ⇒ sẫm")
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                shift.sendActions(for: .touchUpInside)
                XCTAssertEqual(kb.debugKeyColors(shift).current, kb.debugKeyColors(shift).normal)
                XCTAssertNotEqual(kb.debugKeyColors(shift).current, kb.debugKeyColors(shift).pressed, "nhả ⇒ hết sẫm")
            }
        }
    }

    /// Công tắc TẮT: phím chữ / số không bao giờ sẫm, kể cả chạm mép.
    @MainActor func testEdgeTouchesNoHighlightWhenOff() throws {
        try XCTSkipIf(isPad, "bố cục iPhone")
        for width: CGFloat in [402, 440] {
            try withKeyboard(width: width, numberRow: true, highlight: false) { kb, last in
                for s in ["q", "a", "p", "l"] {
                    let f = try XCTUnwrap(kb.debugLetterFrame(s))
                    let x = s == "q" || s == "a" ? f.minX / 2 : (f.maxX + width) / 2
                    let p = CGPoint(x: x, y: f.midY)
                    XCTAssertTrue(kb.debugHitTest(p, time: 1) === kb)
                    let token = NSObject(), id = ObjectIdentifier(token)
                    kb.debugRouteDown(id, at: p, time: 1)
                    XCTAssertTrue(kb.debugPressedKeys().isEmpty, "w=\(width) \(s)")
                    kb.debugRouteUp(id, at: p, time: 1)
                    withExtendedLifetime(token) {}
                }
                for d in ["1", "0"] {
                    let b = try XCTUnwrap(kb.debugKeyButton(d))
                    XCTAssertNil(kb.debugKeyColors(b).pressed)
                    b.sendActions(for: .touchDown)
                    XCTAssertTrue(kb.debugPressedKeys().isEmpty, "w=\(width) \(d)")
                    b.sendActions(for: .touchUpInside)
                }
                _ = last
            }
        }
    }
}
