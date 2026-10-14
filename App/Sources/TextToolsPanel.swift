// TextToolsPanel.swift
// Bảng nổi "Công cụ…" cạnh con trỏ: 6 công cụ văn bản (TextActions.swift) thay cho 6 mục
// phẳng trong menu VietTelex (maintainer 27/09/2026), + "Dịch ↔ …" (phím 7) trên macOS 26+
// (TranslateAction.swift). Menu con NSMenu KHÔNG dùng được:
// TextInputMenuAgent (macOS 27) vẽ menu con nhưng không chuyển action của mục con về IME.
//
// Giữ nguyên focus + vùng chọn của app đang gõ:
//  • NSPanel .nonactivatingPanel, canBecomeKey = false → không bao giờ thành key window,
//    app không activate, app đang gõ vẫn giữ first responder + vùng chọn.
//  • Vì panel không nhận phím, bàn phím đi qua Carbon hotkey KHÔNG modifier (1–6/7, ↑↓←→,
//    Tab/⇧Tab, Return/Enter, Esc) đăng ký CHỈ khi panel đang mở — WindowServer nuốt phím
//    đó trước app, gỡ đăng ký ngay khi đóng.
//  • Click ra ngoài / đổi app / gõ phím khác = đóng, không làm gì.
// Chi phí khi không dùng = 0: panel tạo lười lúc bấm "Công cụ…", thả hết (monitor, hotkey,
// cửa sổ) khi đóng.

import AppKit
import Carbon.HIToolbox
import InputMethodKit

// MARK: - Logic thuần (test ở AppTests/TextToolsPanelTests)

enum TextToolsPanelLogic {
    /// Thứ tự 6 nút = thứ tự cũ trong menu, Dịch cuối cùng (chỉ khi OS dịch được trên
    /// máy — macOS 26+); phím số i+1 chạy tools[i].
    static func tools(translate: Bool) -> [TextAction] {
        [.addTones, .upper, .lower, .title, .sentence, .stripDiacritics] + (translate ? [.translate] : [])
    }
    static let tools = tools(translate: TranslateText.isSupportedOS)

    enum Command: Equatable {
        case run(Int)        // chạy tools[index] ngay (phím số)
        case move(Int)       // dời chọn ±1 (vòng)
        case activate        // chạy mục đang chọn
        case cancel
    }

    /// Phím panel bắt khi đang mở: (keyCode, shift) → lệnh. Nguồn duy nhất cho cả
    /// đăng ký hotkey lẫn xử lý.
    static let bindings = bindings(toolCount: tools.count)

    static func bindings(toolCount: Int) -> [(keyCode: Int, shift: Bool, command: Command)] {
        var b: [(Int, Bool, Command)] = []
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
                      kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7]
        for i in 0..<min(toolCount, digits.count) {
            b.append((digits[i], false, .run(i)))
            b.append((keypad[i], false, .run(i)))
        }
        b.append((kVK_DownArrow, false, .move(1)))
        b.append((kVK_RightArrow, false, .move(1)))
        b.append((kVK_Tab, false, .move(1)))
        b.append((kVK_UpArrow, false, .move(-1)))
        b.append((kVK_LeftArrow, false, .move(-1)))
        b.append((kVK_Tab, true, .move(-1)))
        b.append((kVK_Return, false, .activate))
        b.append((kVK_ANSI_KeypadEnter, false, .activate))
        b.append((kVK_Space, false, .activate))
        b.append((kVK_Escape, false, .cancel))
        return b
    }

    static func command(keyCode: Int, shift: Bool,
                        in bindings: [(keyCode: Int, shift: Bool, command: Command)] = bindings) -> Command? {
        bindings.first { $0.keyCode == keyCode && $0.shift == shift }?.command
    }

    /// Dời chọn có vòng (cuối ↓ → đầu).
    static func moved(_ index: Int, by delta: Int, count: Int = tools.count) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Rect con trỏ có dùng được không (nhiều app trả rect rỗng ở gốc toạ độ, hoặc
    /// khổng lồ / NaN). Toạ độ màn hình Cocoa (gốc dưới-trái). Góc TRÊN-trái của một màn
    /// hình = (0,0) toạ độ AX/CG lật sang Cocoa — Electron (Zalo, #105) trả thế khi không
    /// biết con trỏ; không con trỏ thật nào nằm dưới thanh menu ở đúng góc đó.
    static func isUsableCaretRect(_ r: NSRect, screens: [NSRect]) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite,
              r.width >= 0, r.height >= 0, r.height < 400, r.width < 4000 else { return false }
        if r.origin == .zero && r.size == .zero { return false }
        if screens.contains(where: { abs(r.minX - $0.minX) <= 1 && abs(r.maxY - $0.maxY) <= 1 }) { return false }
        let probe = NSPoint(x: r.minX, y: r.midY)
        return screens.contains { $0.insetBy(dx: -1, dy: -1).contains(probe) }
    }

    /// Rect con trỏ cho bảng Công cụ: dùng được (trên) VÀ, nếu biết cửa sổ đang trước,
    /// nằm trong cửa sổ đó nhưng không dính góc trên-trái của nó (Chromium/Electron trả
    /// gốc view khi không biết con trỏ — #105: bảng hiện ở góc trên-trái màn hình).
    static func plausibleCaret(_ r: NSRect, window: NSRect?, screens: [NSRect]) -> Bool {
        guard isUsableCaretRect(r, screens: screens) else { return false }
        guard let w = window, w.width > 0, w.height > 0 else { return true }
        let probe = NSPoint(x: r.minX, y: r.midY)
        guard w.insetBy(dx: -2, dy: -2).contains(probe) else { return false }
        let atTopLeft = abs(r.minX - w.minX) <= 2 && r.maxY >= w.maxY - 2
        return !atTopLeft
    }

    /// Bảng được đặt theo gì (thứ tự ưu tiên, cố định).
    enum Basis: Equatable { case caret, window, screen }

    /// Quy tắc đặt bảng Công cụ (#105), một thứ tự cố định:
    ///  1. rect con trỏ đầu tiên hợp lệ trong `carets` (firstRect IMK → rect dòng IMK) —
    ///     ngay dưới con trỏ (`origin`);
    ///  2. không có ⇒ cửa sổ đang trước của app: giữa theo chiều ngang, TÂM bảng ở một
    ///     phần ba phía trên cửa sổ;
    ///  3. không biết cửa sổ ⇒ màn hình có chuột, cùng cách đặt trên vùng visibleFrame.
    /// Luôn kẹp TRỌN trong visibleFrame của màn hình chứa điểm neo.
    static func placement(carets: [NSRect], window: NSRect?, mouse: NSPoint,
                          screens: [(frame: NSRect, visible: NSRect)],
                          panelSize: NSSize) -> (origin: NSPoint, basis: Basis) {
        let frames = screens.map(\.frame)
        let fallbackVisible = screens.first?.visible ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        func visible(at p: NSPoint) -> NSRect {
            screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }?.visible ?? fallbackVisible
        }
        let win = window.flatMap { w -> NSRect? in
            guard w.width >= 50, w.height >= 50, w.origin.x.isFinite, w.origin.y.isFinite,
                  frames.contains(where: { $0.intersects(w) }) else { return nil }
            return w
        }
        if let c = carets.first(where: { plausibleCaret($0, window: win, screens: frames) }) {
            return (origin(caret: c, panelSize: panelSize, visible: visible(at: NSPoint(x: c.minX, y: c.midY))), .caret)
        }
        func topThird(of area: NSRect, clampTo vis: NSRect) -> NSPoint {
            let center = NSPoint(x: area.midX, y: area.maxY - area.height / 3)
            return clamp(NSPoint(x: center.x - panelSize.width / 2, y: center.y - panelSize.height / 2),
                         panelSize: panelSize, visible: vis)
        }
        if let w = win {
            let vis = visible(at: NSPoint(x: w.midX, y: w.midY))
            return (topThird(of: w.intersection(vis).isEmpty ? w : w.intersection(vis), clampTo: vis), .window)
        }
        let vis = visible(at: mouse)
        return (topThird(of: vis, clampTo: vis), .screen)
    }

    /// Kẹp góc dưới-trái để bảng nằm trọn trong `visible` (lề `margin`).
    static func clamp(_ o: NSPoint, panelSize: NSSize, visible: NSRect, margin: CGFloat = 6) -> NSPoint {
        var x = min(max(o.x, visible.minX + margin), visible.maxX - margin - panelSize.width)
        var y = min(max(o.y, visible.minY + margin), visible.maxY - margin - panelSize.height)
        if panelSize.width + 2 * margin > visible.width { x = visible.minX }
        if panelSize.height + 2 * margin > visible.height { y = visible.minY }
        return NSPoint(x: x, y: y)
    }

    /// Góc dưới-trái của panel: ngay DƯỚI con trỏ, canh trái theo con trỏ; không đủ chỗ
    /// dưới thì lật lên TRÊN dòng; luôn kẹp trong `visible` (visibleFrame của màn hình)
    /// với lề `margin`.
    static func origin(caret: NSRect, panelSize: NSSize, visible: NSRect,
                       gap: CGFloat = 4, margin: CGFloat = 6) -> NSPoint {
        var x = caret.minX
        var y = caret.minY - gap - panelSize.height                 // dưới
        if y < visible.minY + margin {
            let above = caret.maxY + gap                             // lật lên trên
            if above + panelSize.height <= visible.maxY - margin { y = above }
        }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - panelSize.width)
        y = min(max(y, visible.minY + margin), visible.maxY - margin - panelSize.height)
        // Panel to hơn màn hình (không xảy ra với 6 dòng) → dính mép trái/dưới.
        if panelSize.width + 2 * margin > visible.width { x = visible.minX }
        if panelSize.height + 2 * margin > visible.height { y = visible.minY }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Panel

final class TextToolsPanel {
    /// Panel đang mở (nil = không có gì sống).
    private(set) static var current: TextToolsPanel?

    /// MAIN thread. `client` = client IMK lúc bấm "Công cụ…" (nil được: runner tự dùng AX/⌘C).
    static func show(client: IMKTextInput?) {
        if current != nil { close(); return }        // bấm lại = đóng
        let p = TextToolsPanel(client: client)
        current = p
        p.present()
    }

    static func close() {
        guard let p = current else { return }
        current = nil
        p.teardown()
    }

    private let client: IMKTextInput?
    private var window: ToolsWindow?
    private var rows: [ToolRowView] = []
    private var selected = 0
    private var monitors: [Any] = []
    private var hotKeys: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var workspaceObserver: NSObjectProtocol?
    private static let signature: OSType = 0x5654_5450   // "VTTP" (≠ "VTTH" của TextActionHotkey)

    private init(client: IMKTextInput?) { self.client = client }

    // MARK: Layout

    private static let rowHeight: CGFloat = 24
    private static let width: CGFloat = 250
    private static let pad: CGFloat = 5

    private func present() {
        let n = TextToolsPanelLogic.tools.count
        let size = NSSize(width: Self.width, height: CGFloat(n) * Self.rowHeight + 2 * Self.pad)
        let w = ToolsWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        w.isFloatingPanel = true
        w.becomesKeyOnlyIfNeeded = true
        w.hidesOnDeactivate = false
        w.level = .popUpMenu
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        w.animationBehavior = .utilityWindow

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .popover
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        fx.setAccessibilityRole(.list)
        fx.setAccessibilityLabel(VTLocalized("Tools…"))

        for (i, action) in TextToolsPanelLogic.tools.enumerated() {
            let y = size.height - Self.pad - CGFloat(i + 1) * Self.rowHeight
            let title = action == .translate ? TranslateUI.toolTitle() : VTLocalized(action.titleKey)
            let row = ToolRowView(frame: NSRect(x: Self.pad, y: y, width: size.width - 2 * Self.pad,
                                                height: Self.rowHeight),
                                  title: title, shortcut: "\(i + 1)")
            row.onHover = { [weak self] in self?.select(i) }
            row.onClick = { [weak self] in self?.run(i) }
            fx.addSubview(row)
            rows.append(row)
        }
        w.contentView = fx
        window = w
        select(0)

        w.setFrameOrigin(Self.anchorOrigin(client: client, panelSize: size))
        w.orderFrontRegardless()                   // KHÔNG makeKey / activate
        installInputHooks()
    }

    /// Góc dưới-trái cho một ô nổi cạnh con trỏ (bảng Công cụ, ô báo của Dịch).
    static func anchorOrigin(client: IMKTextInput?, panelSize: NSSize) -> NSPoint {
        var carets: [NSRect] = []
        if let client {
            let sel = client.selectedRange()
            if sel.location != NSNotFound {
                var actual = NSRange(location: NSNotFound, length: 0)
                carets.append(client.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0),
                                               actualRange: &actual))
                var line = NSRect.zero
                _ = client.attributes(forCharacterIndex: sel.location, lineHeightRectangle: &line)
                carets.append(line)
            }
        }
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        let r = TextToolsPanelLogic.placement(carets: carets, window: frontWindowFrame(),
                                              mouse: NSEvent.mouseLocation, screens: screens,
                                              panelSize: panelSize)
        DebugLog.log("tools panel: placed by \(r.basis)")
        return r.origin
    }

    private static func frontWindowFrame() -> NSRect? { FrontWindow.frame() }

    // MARK: Selection / run

    private func select(_ i: Int) {
        selected = i
        for (j, r) in rows.enumerated() { r.highlighted = (j == i) }
    }

    private func run(_ i: Int) {
        guard TextToolsPanelLogic.tools.indices.contains(i) else { return }
        let action = TextToolsPanelLogic.tools[i]
        let c = client
        Self.close()
        // Async: để panel tắt hẳn (và phím hotkey nhả) trước khi runner đọc AX/⌘C.
        DispatchQueue.main.async { TextActionRunner.run(action, client: c) }
    }

    private func perform(_ cmd: TextToolsPanelLogic.Command) {
        switch cmd {
        case .run(let i): run(i)
        case .move(let d): select(TextToolsPanelLogic.moved(selected, by: d))
        case .activate: run(selected)
        case .cancel: Self.close()
        }
    }

    // MARK: Input hooks (sống đúng lúc panel mở)

    private func installInputHooks() {
        // Click ra ngoài (sự kiện gửi app KHÁC — click trong panel không tới đây).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { _ in TextToolsPanel.close() }) {
            monitors.append(m)
        }
        // Gõ phím khác (không phải phím panel bắt) = user bỏ panel, gõ tiếp. Cần quyền
        // Accessibility; không có thì chỉ mất tiện ích này.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            // Phím tắt mở Công cụ (TextActionHotkey) tự bật/tắt bảng — đóng ở đây thì
            // handler hotkey lại mở ra, thành "bấm lại không đóng được".
            if TextActionHotkey.isToolsPanelHotkey(keyCode: Int(e.keyCode), flags: e.modifierFlags,
                                                   choice: AppState.shared.toolsPanelHotkey) { return }
            let shift = e.modifierFlags.contains(.shift)
            if TextToolsPanelLogic.command(keyCode: Int(e.keyCode), shift: shift) == nil
                || !e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                TextToolsPanel.close()
            }
        }) { monitors.append(m) }
        // Đổi sang app KHÁC = đóng (client IMK đã chụp không còn đúng chỗ).
        let hostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != hostPid { TextToolsPanel.close() }
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr, hk.signature == TextToolsPanel.signature else { return OSStatus(eventNotHandledErr) }
            let idx = Int(hk.id)
            DispatchQueue.main.async {
                guard let p = TextToolsPanel.current,
                      TextToolsPanelLogic.bindings.indices.contains(idx) else { return }
                p.perform(TextToolsPanelLogic.bindings[idx].command)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        var failed = 0
        for (idx, b) in TextToolsPanelLogic.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(idx))
            let st = RegisterEventHotKey(UInt32(b.keyCode), b.shift ? UInt32(shiftKey) : 0, id,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { hotKeys.append(ref) } else { failed += 1 }
        }
        if failed > 0 { DebugLog.log("tools panel: \(failed) hotkey(s) failed to register") }
    }

    private func teardown() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys = []
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObserver = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        rows = []
    }
}

/// Panel không bao giờ thành key/main: app đang gõ giữ focus + vùng chọn.
private final class ToolsWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Một dòng kiểu mục menu: tên công cụ + phím số mờ bên phải; nền accent khi chọn.
private final class ToolRowView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var highlighted = false { didSet { if highlighted != oldValue { updateColors() } } }
    private let titleField: NSTextField
    private let keyField: NSTextField
    private let bg = NSView()

    init(frame: NSRect, title: String, shortcut: String) {
        titleField = NSTextField(labelWithString: title)
        keyField = NSTextField(labelWithString: shortcut)
        super.init(frame: frame)
        bg.frame = bounds
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        addSubview(bg)
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        keyField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        keyField.alignment = .right
        let h = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: 10, y: (frame.height - h) / 2, width: frame.width - 44, height: h)
        let kh = keyField.intrinsicContentSize.height
        keyField.frame = NSRect(x: frame.width - 30, y: (frame.height - kh) / 2, width: 20, height: kh)
        addSubview(titleField)
        addSubview(keyField)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // cgColor phải resolve theo appearance của panel (sáng/tối), không theo process.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bg.layer?.backgroundColor = highlighted ? NSColor.selectedContentBackgroundColor.cgColor
                                                    : NSColor.clear.cgColor
        }
        titleField.textColor = highlighted ? .alternateSelectedControlTextColor : .labelColor
        keyField.textColor = highlighted ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
                                         : .tertiaryLabelColor
    }
}

// MARK: - Front window

/// Khung cửa sổ trên cùng (lớp thường) của app đang trước, toạ độ Cocoa. Đọc qua
/// CGWindowList (chỉ khung — không cần AX, không cần quyền ghi màn hình), nên dùng được
/// cả ở app Electron không lộ AX (Zalo) và Firefox. Chỉ gọi lúc SẮP hiện một ô (bảng Công
/// cụ, gợi ý cạnh con trỏ — #104/#105), không bao giờ mỗi phím; nhớ 0,5 s theo pid để hai
/// lần đọc sát nhau không quét lại. MAIN thread.
enum FrontWindow {
    private static var cache: (pid: pid_t, at: TimeInterval, frame: NSRect?)?

    static func frame() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let c = cache, c.pid == pid, now - c.at < 0.5 { return c.frame }
        let f = scan(pid: pid)
        cache = (pid, now, f)
        return f
    }

    private static func scan(pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {                                   // thứ tự trước → sau
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: b), cg.width >= 50, cg.height >= 50 else { continue }
            return AXTextEdit.flip(cg)
        }
        return nil
    }
}
