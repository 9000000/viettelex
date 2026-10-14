// TextActionHotkey.swift
// Phím tắt toàn hệ thống (mặc định TẮT) cho "Thêm dấu cho vùng chọn" và "mở bảng Công
// cụ…". Carbon RegisterEventHotKey: WindowServer tự so khớp tổ hợp — process mình không
// thấy phím nào khác, không đi qua event tap, không tốn gì theo phím gõ. Tắt = gỡ đăng ký.
//
// Hai phím dùng CHUNG một chữ ký "VTTH" + một event handler, phân biệt bằng
// EventHotKeyID.id (`Slot`). Bảng Công cụ… (TextToolsPanel) đăng ký phím số 1–7 tạm thời
// dưới chữ ký RIÊNG "VTTP" — handler này bỏ qua chúng (`route` trả nil).

import AppKit
import Carbon.HIToolbox

enum TextActionHotkey {
    /// Phím tắt nào — cũng là EventHotKeyID.id khi đăng ký.
    enum Slot: UInt32, CaseIterable {
        case addTones = 1     // Thêm dấu cho vùng chọn (phím T)
        case toolsPanel = 2   // mở/đóng bảng Công cụ… (phím C)
    }

    /// Giá trị lưu (AppState.addTonesHotkey) → nhãn hiển thị. Phím T theo vị trí QWERTY.
    static let choices: [(id: String, label: String)] = [
        ("off", ""), ("ctrl-opt-t", "⌃⌥T"), ("ctrl-shift-t", "⌃⇧T"), ("opt-cmd-t", "⌥⌘T"),
    ]

    /// Giá trị lưu (AppState.toolsPanelHotkey) → nhãn. Phím C (vị trí QWERTY) — khác chữ
    /// với Thêm dấu nên hai phím không bao giờ trùng tổ hợp.
    static let toolsChoices: [(id: String, label: String)] = [
        ("off", ""), ("ctrl-opt-c", "⌃⌥C"), ("ctrl-shift-c", "⌃⇧C"), ("ctrl-opt-cmd-c", "⌃⌥⌘C"),
    ]

    static func choices(for slot: Slot) -> [(id: String, label: String)] {
        switch slot {
        case .addTones: return choices
        case .toolsPanel: return toolsChoices
        }
    }

    static func keyCode(for slot: Slot) -> Int {
        switch slot {
        case .addTones: return kVK_ANSI_T
        case .toolsPanel: return kVK_ANSI_C
        }
    }

    /// Modifier Carbon của lựa chọn Thêm dấu; nil = tắt / giá trị lạ.
    static func carbonModifiers(for choice: String) -> UInt32? {
        carbonModifiers(for: choice, slot: .addTones)
    }

    /// Modifier Carbon của `choice` cho `slot`; nil = tắt / giá trị không thuộc slot đó
    /// (một id của Thêm dấu lưu nhầm vào khoá Công cụ không được đăng ký phím C).
    static func carbonModifiers(for choice: String, slot: Slot) -> UInt32? {
        guard choice != "off", choices(for: slot).contains(where: { $0.id == choice }) else { return nil }
        switch choice {
        case "ctrl-opt-t", "ctrl-opt-c": return UInt32(controlKey | optionKey)
        case "ctrl-shift-t", "ctrl-shift-c": return UInt32(controlKey | shiftKey)
        case "opt-cmd-t": return UInt32(optionKey | cmdKey)
        case "ctrl-opt-cmd-c": return UInt32(controlKey | optionKey | cmdKey)
        default: return nil
        }
    }

    /// Cùng tổ hợp dưới dạng cờ NSEvent (bảng Công cụ đang mở dùng để nhận ra phím tắt
    /// của chính nó và không tự đóng trước khi handler kịp bật/tắt).
    static func cocoaModifiers(for choice: String, slot: Slot) -> NSEvent.ModifierFlags? {
        guard let c = carbonModifiers(for: choice, slot: slot) else { return nil }
        var f: NSEvent.ModifierFlags = []
        if c & UInt32(controlKey) != 0 { f.insert(.control) }
        if c & UInt32(optionKey) != 0 { f.insert(.option) }
        if c & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if c & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// True khi phím (keyCode + modifier) chính là phím tắt mở Công cụ đang đặt.
    static func isToolsPanelHotkey(keyCode: Int, flags: NSEvent.ModifierFlags, choice: String) -> Bool {
        guard keyCode == kVK_ANSI_C, let want = cocoaModifiers(for: choice, slot: .toolsPanel) else { return false }
        return flags.intersection([.control, .option, .shift, .command]) == want
    }

    static let signature: OSType = 0x5654_5448   // "VTTH"

    /// Định tuyến một sự kiện hotkey: chỉ chữ ký của mình + id đã biết. Thuần — test được.
    static func route(signature sig: OSType, id: UInt32) -> Slot? {
        sig == signature ? Slot(rawValue: id) : nil
    }

    private static var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private static var handlerRef: EventHandlerRef?

    /// MAIN thread. Gọi lúc khởi động và khi đổi lựa chọn Thêm dấu trong Cài đặt.
    static func apply(_ choice: String) { apply(choice, slot: .addTones) }

    /// MAIN thread. Phím tắt mở bảng Công cụ… — lúc khởi động và khi đổi trong Cài đặt.
    static func applyToolsPanel(_ choice: String) { apply(choice, slot: .toolsPanel) }

    static func apply(_ choice: String, slot: Slot) {
        if let ref = hotKeyRefs[slot] { UnregisterEventHotKey(ref); hotKeyRefs[slot] = nil }
        guard let mods = carbonModifiers(for: choice, slot: slot) else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode(for: slot)), mods, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeyRefs[slot] = ref }
        else { DebugLog.log("hotkey \(slot) \(choice): register failed \(status)") }
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Chỉ nhận hotkey CỦA MÌNH: bảng Công cụ… (TextToolsPanel) đăng ký phím riêng
        // lúc đang mở trên cùng event target — không lọc thì phím 1–7 cũng chạy Thêm dấu.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr, let slot = TextActionHotkey.route(signature: hk.signature, id: hk.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                switch slot {
                case .addTones: TextActionRunner.run(.addTones, client: nil)
                // nil client: bảng tự neo theo AX/cửa sổ/chuột; bấm lại khi đang mở = đóng.
                case .toolsPanel: TextToolsPanel.show(client: nil)
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
