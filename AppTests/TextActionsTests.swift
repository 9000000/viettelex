// TextActionsTests — công cụ văn bản + Thêm dấu trên macOS: cùng fixture với iOS/Android
// (iOS/KeyboardTests/Fixtures) để bản biên dịch chung trong app Mac cho đúng kết quả;
// process con --add-tones; clipboard trả lại nguyên vẹn; hotkey.
import AppKit
import XCTest
import Carbon.HIToolbox
@testable import VietTelex

final class TextActionsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("iOS/KeyboardTests/Fixtures")

    private func fixtureLines(_ name: String) throws -> [String] {
        let s = try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
        return s.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func testTextToolsSharedFixture() throws {
        let lines = try fixtureLines("text-tools.txt")
        XCTAssertGreaterThan(lines.count, 10)
        func unesc(_ s: String) -> String {
            s.replacingOccurrences(of: "␣", with: " ").replacingOccurrences(of: "⏎", with: "\n")
        }
        for line in lines {
            let c = line.components(separatedBy: "|")
            XCTAssertEqual(c.count, 3, line)
            let nfd = c[0].hasSuffix("@nfd")
            guard let tool = TextTool(rawValue: nfd ? String(c[0].dropLast(4)) : c[0]) else {
                XCTFail("op lạ: \(line)"); continue
            }
            var input = unesc(c[1])
            if nfd { input = input.decomposedStringWithCanonicalMapping }
            XCTAssertTrue(TextTools.apply(tool, input).unicodeScalars.elementsEqual(unesc(c[2]).unicodeScalars), line)
        }
    }

    func testAddTonesSharedFixture() throws {
        for line in try fixtureLines("add-tones.txt") {
            let c = line.components(separatedBy: "\t")
            guard c.count == 2 else { continue }
            XCTAssertEqual(TextActionTransform.addTonesInProcess(c[0]), c[1], line)
        }
    }

    func testApplyMapsActionsAndRejectsNoOps() {
        let noHelper: (String) -> String? = { _ in XCTFail("không được gọi Thêm dấu"); return nil }
        XCTAssertEqual(TextActionTransform.apply(.upper, "tiếng việt", addTones: noHelper), "TIẾNG VIỆT")
        XCTAssertEqual(TextActionTransform.apply(.lower, "TIẾNG Việt", addTones: noHelper), "tiếng việt")
        XCTAssertEqual(TextActionTransform.apply(.title, "tiếng việt", addTones: noHelper), "Tiếng Việt")
        XCTAssertEqual(TextActionTransform.apply(.sentence, "xin chào. tạm biệt", addTones: noHelper),
                       "Xin chào. Tạm biệt")
        XCTAssertEqual(TextActionTransform.apply(.stripDiacritics, "Đường phố", addTones: noHelper), "Duong pho")
        // Không đổi gì ⇒ nil (không đụng vào ô, không đụng clipboard).
        XCTAssertNil(TextActionTransform.apply(.upper, "ABC", addTones: noHelper))
        XCTAssertNil(TextActionTransform.apply(.upper, "", addTones: noHelper))
        XCTAssertNil(TextActionTransform.apply(.lower, String(repeating: "A", count: TextActionTransform.maxLength + 1),
                                               addTones: noHelper))
        XCTAssertEqual(TextActionTransform.apply(.addTones, "toi di", addTones: { _ in "tôi đi" }), "tôi đi")
        XCTAssertNil(TextActionTransform.apply(.addTones, "hello", addTones: { $0 }))
        XCTAssertNil(TextActionTransform.apply(.addTones, "toi", addTones: { _ in nil }))
    }

    /// Process con thật (chính binary app, cờ --add-tones): cùng kết quả với bản trong process.
    func testAddTonesHelperProcess() {
        let input = "Toi di hoc, hom nay troi dep!\nkhong co gi"
        XCTAssertEqual(TextActionTransform.addTonesViaHelper(input),
                       "Tôi đi học, hôm nay trời đẹp!\nkhông có gì")
        XCTAssertEqual(TextActionTransform.addTonesViaHelper(""), "")
    }

    func testPasteboardSnapshotRestoresAllTypes() {
        let pb = NSPasteboard(name: NSPasteboard.Name("vt.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.viettelex.test")
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("gốc", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        pb.writeObjects([item])
        let snap = PasteboardBridge.Snapshot(pb)
        pb.clearContents()
        pb.setString("tạm", forType: .string)
        snap.restore(pb)
        XCTAssertEqual(pb.string(forType: .string), "gốc")
        XCTAssertEqual(pb.data(forType: custom), Data([1, 2, 3]))
        // Clipboard rỗng lúc chụp ⇒ trả lại rỗng.
        pb.clearContents()
        let empty = PasteboardBridge.Snapshot(pb)
        pb.setString("x", forType: .string)
        empty.restore(pb)
        XCTAssertNil(pb.string(forType: .string))
    }

    func testHotkeyChoices() {
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "off"))
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "rác"))
        for c in TextActionHotkey.choices where c.id != "off" {
            XCTAssertNotNil(TextActionHotkey.carbonModifiers(for: c.id), c.id)
            XCTAssertFalse(c.label.isEmpty)
        }
    }

    /// Phím tắt mở Công cụ: mỗi lựa chọn ↔ đúng modifier Carbon, phím C; id của slot này
    /// không lọt sang slot kia (một id Thêm dấu lưu nhầm không được đăng ký phím C).
    func testToolsPanelHotkeyChoices() {
        XCTAssertEqual(TextActionHotkey.toolsChoices.map(\.id),
                       ["off", "ctrl-opt-c", "ctrl-shift-c", "ctrl-opt-cmd-c"])
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "off", slot: .toolsPanel))
        XCTAssertEqual(TextActionHotkey.carbonModifiers(for: "ctrl-opt-c", slot: .toolsPanel),
                       UInt32(controlKey | optionKey))
        XCTAssertEqual(TextActionHotkey.carbonModifiers(for: "ctrl-shift-c", slot: .toolsPanel),
                       UInt32(controlKey | shiftKey))
        XCTAssertEqual(TextActionHotkey.carbonModifiers(for: "ctrl-opt-cmd-c", slot: .toolsPanel),
                       UInt32(controlKey | optionKey | cmdKey))
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "ctrl-opt-t", slot: .toolsPanel))
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "ctrl-opt-c", slot: .addTones))
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: "ctrl-opt-c"))   // API cũ = Thêm dấu
        XCTAssertEqual(TextActionHotkey.keyCode(for: .toolsPanel), kVK_ANSI_C)
        XCTAssertEqual(TextActionHotkey.keyCode(for: .addTones), kVK_ANSI_T)
        // Hai slot không bao giờ trùng tổ hợp (khác phím).
        XCTAssertNotEqual(TextActionHotkey.keyCode(for: .toolsPanel), TextActionHotkey.keyCode(for: .addTones))
        XCTAssertEqual(TextActionHotkey.cocoaModifiers(for: "ctrl-opt-cmd-c", slot: .toolsPanel),
                       [.control, .option, .command])
    }

    /// Handler chung định tuyến theo (chữ ký, id): VTTH/1 → Thêm dấu, VTTH/2 → Công cụ;
    /// phím số của bảng Công cụ (chữ ký VTTP, id 0…) và id lạ thì bỏ qua.
    func testHotkeyRouting() {
        let sig = TextActionHotkey.signature
        XCTAssertEqual(TextActionHotkey.route(signature: sig, id: 1), .addTones)
        XCTAssertEqual(TextActionHotkey.route(signature: sig, id: 2), .toolsPanel)
        XCTAssertNil(TextActionHotkey.route(signature: sig, id: 0))
        XCTAssertNil(TextActionHotkey.route(signature: sig, id: 99))
        let panelSig: OSType = 0x5654_5450   // "VTTP" — TextToolsPanel
        for id in UInt32(0)..<UInt32(TextToolsPanelLogic.bindings.count) {
            XCTAssertNil(TextActionHotkey.route(signature: panelSig, id: id))
        }
    }

    /// Bảng đang mở nhận ra phím tắt của chính nó (để không tự đóng rồi bị mở lại).
    func testIsToolsPanelHotkey() {
        XCTAssertTrue(TextActionHotkey.isToolsPanelHotkey(keyCode: kVK_ANSI_C, flags: [.control, .option],
                                                          choice: "ctrl-opt-c"))
        XCTAssertTrue(TextActionHotkey.isToolsPanelHotkey(keyCode: kVK_ANSI_C, flags: [.control, .option, .capsLock],
                                                          choice: "ctrl-opt-c"))
        XCTAssertFalse(TextActionHotkey.isToolsPanelHotkey(keyCode: kVK_ANSI_C, flags: [.control, .option, .command],
                                                           choice: "ctrl-opt-c"))
        XCTAssertFalse(TextActionHotkey.isToolsPanelHotkey(keyCode: kVK_ANSI_T, flags: [.control, .option],
                                                           choice: "ctrl-opt-c"))
        XCTAssertFalse(TextActionHotkey.isToolsPanelHotkey(keyCode: kVK_ANSI_C, flags: [.control, .option],
                                                           choice: "off"))
    }

    /// Mặc định tắt (khoá vắng ⇒ "off" ⇒ không đăng ký gì); giá trị đặt đọc lại đúng.
    func testToolsPanelHotkeyDefaultOff() {
        let s = AppState.shared
        let saved = s.defaults.object(forKey: "toolsPanelHotkey")
        defer {
            if let saved { s.defaults.set(saved, forKey: "toolsPanelHotkey") }
            else { s.defaults.removeObject(forKey: "toolsPanelHotkey") }
        }
        s.defaults.removeObject(forKey: "toolsPanelHotkey")
        XCTAssertEqual(s.toolsPanelHotkey, "off")
        XCTAssertNil(TextActionHotkey.carbonModifiers(for: s.toolsPanelHotkey, slot: .toolsPanel))
        s.toolsPanelHotkey = "ctrl-shift-c"
        XCTAssertEqual(s.toolsPanelHotkey, "ctrl-shift-c")
    }

    /// Mọi nhãn menu có bản tiếng Việt (thiếu thì menu hiện tiếng Anh giữa UI Việt).
    func testMenuTitlesHaveVietnamese() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vi = try XCTUnwrap(Bundle(path: path))
        for a in TextAction.allCases {
            XCTAssertNotEqual(vi.localizedString(forKey: a.titleKey, value: "∅", table: nil), "∅", a.titleKey)
        }
        XCTAssertEqual(vi.localizedString(forKey: "Add tones to selection", value: nil, table: nil),
                       "Thêm dấu cho vùng chọn")
        XCTAssertEqual(TextAction.allCases.compactMap(\.textTool).count, TextTool.allCases.count)
    }
}
