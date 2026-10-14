// TextToolsPanelTests — bảng "Công cụ…" (TextToolsPanel.swift): thứ tự nút + phím 1–6,
// dời chọn, toán đặt vị trí cạnh con trỏ, vị trí mục trong menu VietTelex. Chỉ logic
// thuần: không tạo NSPanel, không đăng ký hotkey (test host không được giành phím).
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VietTelex

final class TextToolsPanelTests: XCTestCase {
    typealias L = TextToolsPanelLogic

    func testToolOrderMatchesOldMenu() {
        XCTAssertEqual(L.tools(translate: false), [.addTones, .upper, .lower, .title, .sentence, .stripDiacritics])
        // Dịch (macOS 26+) đứng cuối, phím 7.
        XCTAssertEqual(L.tools(translate: true), L.tools(translate: false) + [.translate])
        XCTAssertEqual(Set(L.tools(translate: true)), Set(TextAction.allCases))
        XCTAssertEqual(L.tools, L.tools(translate: TranslateText.isSupportedOS))
    }

    func testDigitKeysRunTools() {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
                      kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7]
        for count in [6, 7] {                  // không / có Dịch
            let b = L.bindings(toolCount: count)
            for i in 0..<count {
                XCTAssertEqual(L.command(keyCode: digits[i], shift: false, in: b), .run(i))
                XCTAssertEqual(L.command(keyCode: keypad[i], shift: false, in: b), .run(i))
            }
            if count == 6 { XCTAssertNil(L.command(keyCode: kVK_ANSI_7, shift: false, in: b)) }
            XCTAssertNil(L.command(keyCode: kVK_ANSI_8, shift: false, in: b))
            XCTAssertNil(L.command(keyCode: kVK_ANSI_0, shift: false, in: b))
            XCTAssertNil(L.command(keyCode: kVK_ANSI_1, shift: true, in: b))     // ⇧1 = "!" không phải công cụ
            XCTAssertNil(L.command(keyCode: kVK_ANSI_A, shift: false, in: b))    // phím chữ đi thẳng vào app
        }
        XCTAssertEqual(L.bindings.count, L.bindings(toolCount: L.tools.count).count)
    }

    func testNavigationKeys() {
        XCTAssertEqual(L.command(keyCode: kVK_DownArrow, shift: false), .move(1))
        XCTAssertEqual(L.command(keyCode: kVK_UpArrow, shift: false), .move(-1))
        XCTAssertEqual(L.command(keyCode: kVK_Tab, shift: false), .move(1))
        XCTAssertEqual(L.command(keyCode: kVK_Tab, shift: true), .move(-1))
        XCTAssertEqual(L.command(keyCode: kVK_Return, shift: false), .activate)
        XCTAssertEqual(L.command(keyCode: kVK_ANSI_KeypadEnter, shift: false), .activate)
        XCTAssertEqual(L.command(keyCode: kVK_Escape, shift: false), .cancel)
    }

    func testBindingsUnique() {
        // Mỗi (phím, shift) một lệnh: RegisterEventHotKey trùng sẽ fail.
        for count in [6, 7] {
            var seen = Set<String>()
            for b in L.bindings(toolCount: count) {
                XCTAssertTrue(seen.insert("\(b.keyCode)-\(b.shift)").inserted, "\(b)")
            }
        }
    }

    func testMoveWraps() {
        XCTAssertEqual(L.moved(0, by: -1, count: 6), 5)
        XCTAssertEqual(L.moved(5, by: 1, count: 6), 0)
        XCTAssertEqual(L.moved(0, by: -1, count: 7), 6)
        XCTAssertEqual(L.moved(2, by: 1), 3)
        XCTAssertEqual(L.moved(0, by: 1, count: 0), 0)
    }

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)   // visibleFrame
    private let size = NSSize(width: 230, height: 154)

    func testPlacedBelowCaretLeftAligned() {
        let caret = NSRect(x: 400, y: 500, width: 1, height: 18)
        let o = L.origin(caret: caret, panelSize: size, visible: screen)
        XCTAssertEqual(o.x, 400)
        XCTAssertEqual(o.y, 500 - 4 - 154)
    }

    func testFlipsAboveNearBottom() {
        let caret = NSRect(x: 400, y: 60, width: 1, height: 18)
        let o = L.origin(caret: caret, panelSize: size, visible: screen)
        XCTAssertEqual(o.y, 78 + 4)                  // trên dòng, không che chữ
    }

    func testClampedToRightAndTopEdges() {
        let caret = NSRect(x: 1430, y: 870, width: 1, height: 18)
        let o = L.origin(caret: caret, panelSize: size, visible: screen)
        XCTAssertEqual(o.x, 1440 - 6 - 230)
        XCTAssertLessThanOrEqual(o.y + size.height, 875 - 6)
    }

    func testSecondScreenCoordinates() {
        let second = NSRect(x: -1920, y: 200, width: 1920, height: 1055)
        let caret = NSRect(x: -1900, y: 220, width: 0, height: 16)
        let o = L.origin(caret: caret, panelSize: size, visible: second)
        XCTAssertEqual(o.x, -1900)
        XCTAssertEqual(o.y, 236 + 4)                // sát đáy → lật lên
        XCTAssertTrue(second.contains(NSRect(origin: o, size: size)))
        // Con trỏ sát mép trái → kẹp vào trong lề.
        XCTAssertEqual(L.origin(caret: NSRect(x: -1920, y: 600, width: 0, height: 16),
                                panelSize: size, visible: second).x, -1920 + 6)
    }

    func testCaretRectValidity() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(L.isUsableCaretRect(NSRect(x: 100, y: 300, width: 1, height: 18), screens: screens))
        XCTAssertFalse(L.isUsableCaretRect(.zero, screens: screens))
        XCTAssertFalse(L.isUsableCaretRect(NSRect(x: 5000, y: 300, width: 1, height: 18), screens: screens))
        XCTAssertFalse(L.isUsableCaretRect(NSRect(x: CGFloat.nan, y: 300, width: 1, height: 18), screens: screens))
        XCTAssertFalse(L.isUsableCaretRect(NSRect(x: 0, y: 0, width: 1440, height: 900), screens: screens))
    }

    // MARK: #105 — bảng Công cụ ở ô chat Zalo nhảy lên góc trên-trái màn hình
    //
    // Field report #105 (v1.8.3, macOS 27): bấm "Công cụ…" khi ngoài desktop thì bảng ở chỗ
    // hợp lý, khi đang ở ô chat Zalo (Electron) thì bảng ở GÓC TRÊN-TRÁI màn hình. Rect con
    // trỏ Electron trả khi không biết con trỏ là gốc (0,0) AX/view lật sang Cocoa — lọt
    // qua isUsableCaretRect cũ (chỉ loại đúng NSRect.zero) ⇒ bảng neo vào góc.

    private let main = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                        visible: NSRect(x: 0, y: 0, width: 1440, height: 875))

    func testScreenTopLeftCornerIsNotACaret() {
        let screens = [main.frame]
        XCTAssertFalse(L.isUsableCaretRect(NSRect(x: 0, y: 900, width: 0, height: 0), screens: screens))
        XCTAssertFalse(L.isUsableCaretRect(NSRect(x: 0, y: 883, width: 0, height: 17), screens: screens))
        XCTAssertTrue(L.isUsableCaretRect(NSRect(x: 0, y: 500, width: 0, height: 17), screens: screens))
    }

    func testZaloGarbageCaretFallsBackToWindowTopThird() {
        let zalo = NSRect(x: 200, y: 100, width: 1000, height: 700)
        let garbage = [NSRect(x: 0, y: 900, width: 0, height: 0),          // (0,0) AX lật
                       NSRect(x: 200, y: 800, width: 0, height: 0)]        // gốc view = góc cửa sổ
        let r = L.placement(carets: garbage, window: zalo, mouse: NSPoint(x: 1300, y: 890),
                            screens: [main], panelSize: size)
        XCTAssertEqual(r.basis, .window)
        XCTAssertEqual(r.origin.x + size.width / 2, zalo.midX, accuracy: 0.5)          // giữa ngang
        XCTAssertEqual(r.origin.y + size.height / 2, zalo.maxY - zalo.height / 3, accuracy: 0.5)
        XCTAssertTrue(main.visible.contains(NSRect(origin: r.origin, size: size)))
    }

    func testCaretOutsideFrontWindowIsRejected() {
        let win = NSRect(x: 200, y: 100, width: 600, height: 500)
        let outside = NSRect(x: 1000, y: 300, width: 1, height: 18)
        XCTAssertFalse(L.plausibleCaret(outside, window: win, screens: [main.frame]))
        let inside = NSRect(x: 400, y: 300, width: 1, height: 18)
        XCTAssertTrue(L.plausibleCaret(inside, window: win, screens: [main.frame]))
        XCTAssertTrue(L.plausibleCaret(inside, window: nil, screens: [main.frame]))
    }

    func testGoodCaretStillWins() {
        let win = NSRect(x: 200, y: 100, width: 1000, height: 700)
        let caret = NSRect(x: 400, y: 500, width: 1, height: 18)
        let r = L.placement(carets: [.zero, caret], window: win, mouse: .zero, screens: [main], panelSize: size)
        XCTAssertEqual(r.basis, .caret)
        XCTAssertEqual(r.origin, L.origin(caret: caret, panelSize: size, visible: main.visible))
    }

    func testNoCaretNoWindowUsesMouseScreen() {
        let second = (frame: NSRect(x: -1920, y: 0, width: 1920, height: 1080),
                      visible: NSRect(x: -1920, y: 0, width: 1920, height: 1055))
        let r = L.placement(carets: [], window: nil, mouse: NSPoint(x: -500, y: 1070),
                            screens: [main, second], panelSize: size)
        XCTAssertEqual(r.basis, .screen)
        XCTAssertTrue(second.visible.contains(NSRect(origin: r.origin, size: size)))
        XCTAssertEqual(r.origin.x + size.width / 2, second.visible.midX, accuracy: 0.5)
        // Cùng đầu vào ⇒ cùng chỗ (không phụ thuộc chuột trong màn hình).
        let again = L.placement(carets: [], window: nil, mouse: NSPoint(x: -1800, y: 10),
                                screens: [main, second], panelSize: size)
        XCTAssertEqual(again.origin, r.origin)
    }

    func testWindowPartlyOffscreenStillClampedOnScreen() {
        let win = NSRect(x: 1200, y: -300, width: 900, height: 600)
        let r = L.placement(carets: [], window: win, mouse: .zero, screens: [main], panelSize: size)
        XCTAssertEqual(r.basis, .window)
        XCTAssertTrue(main.visible.contains(NSRect(origin: r.origin, size: size)))
        // Cửa sổ vô lý (nằm ngoài mọi màn hình / quá nhỏ) ⇒ bỏ, dùng màn hình.
        let off = L.placement(carets: [], window: NSRect(x: 5000, y: 5000, width: 800, height: 600),
                              mouse: NSPoint(x: 10, y: 10), screens: [main], panelSize: size)
        XCTAssertEqual(off.basis, .screen)
    }

    /// Thứ tự menu (maintainer 14/10/2026): Công cụ… đầu tiên (chỉ khi bật), rồi dòng
    /// Cơ chế gõ, Cài đặt…, Nguồn nhập liệu… (tên mới của "Cài đặt hệ thống…").
    func testMenuOrderToolsFirstThenModeSettingsInputSources() {
        XCTAssertEqual(TelexInputController.menuItemKeys(textToolsInMenu: true),
                       ["Tools…", "Typing mode", "Settings…", "Input Sources…"])
        XCTAssertEqual(TelexInputController.menuItemKeys(textToolsInMenu: false),
                       ["Typing mode", "Settings…", "Input Sources…"])
    }

    func testMenuItemsLocalized() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vi = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(vi.localizedString(forKey: TelexInputController.inputSourcesItemKey, value: nil, table: nil),
                       "Nguồn nhập liệu…")
        for key in TelexInputController.menuItemKeys(textToolsInMenu: true) {
            XCTAssertNotEqual(vi.localizedString(forKey: key, value: "∅", table: nil), "∅", key)
        }
    }

    func testToolsItemLocalized() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vi = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(vi.localizedString(forKey: TelexInputController.toolsItemKey, value: nil, table: nil),
                       "Công cụ…")
    }
}
