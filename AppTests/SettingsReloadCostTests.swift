import XCTest
@testable import VietTelex

// The Settings window lives in the INPUT METHOD's process, on the same main thread that
// serves keystrokes — so its work is typing latency. Tester report 2026-07-28: "mở settings
// lên lâu là bị đơ đơ, tắt đi thì trở lại bình thường". Cause: the mode table rebuilt on
// EVERY NSWindow.didBecomeKey (which fires for every window in the process, and the user's
// flow is alt-tabbing between Settings and the app under test), and each rebuild ran ~50
// LaunchServices lookups. These tests pin both guards.
final class SettingsReloadCostTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The table's labels ask about Accessibility; pin it so the rows are deterministic.
        Accessibility.testTrustOverride = true
    }

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        super.tearDown()
    }

    /// "Installed?" is a LaunchServices round trip per bundle id; apps do not come and go
    /// while a window is open, so each id must be looked up at most once per session.
    func testInstalledLookupsAreMemoized() {
        SettingsModel.installedCache.removeAll()
        let model = SettingsModel(selected: .apps)
        model.reloadModeTable()
        let afterFirst = SettingsModel.installedCache.count
        XCTAssertGreaterThan(afterFirst, 0, "the reload must populate the cache")

        model.reloadModeTable()
        XCTAssertEqual(SettingsModel.installedCache.count, afterFirst,
                       "a second reload must not add lookups — every id was already known")
    }

    /// Same story for the display name: `urlForApplication` + `displayName(atPath:)` per
    /// ROW (~20-60 of them) on every reload. One resolve per bundle id per session.
    func testAppNameLookupsAreMemoized() {
        SettingsModel.nameCache.removeAll()
        let model = SettingsModel(selected: .apps)
        model.reloadModeTable()
        let afterFirst = SettingsModel.nameCache.count
        XCTAssertGreaterThan(afterFirst, 0, "the reload must populate the name cache")
        XCTAssertEqual(afterFirst, model.modeRows.count,
                       "one cache entry per row — every row's name came from a lookup")

        model.reloadModeTable()
        XCTAssertEqual(SettingsModel.nameCache.count, afterFirst,
                       "a second reload must not add lookups — every name was already known")
    }

    /// A cached name must be the one actually shown, not just stored — otherwise the
    /// memoization would be dead weight next to a live lookup.
    func testAppNameReturnsTheCachedValue() {
        SettingsModel.nameCache.removeAll()
        SettingsModel.nameCache["com.example.nonexistent"] = "Sentinel"
        XCTAssertEqual(SettingsModel.appName(for: "com.example.nonexistent"), "Sentinel")
        SettingsModel.nameCache.removeAll()
        // Unknown id (nothing installed under it) falls back to the raw id — and caches it.
        XCTAssertEqual(SettingsModel.appName(for: "com.example.nonexistent"),
                       "com.example.nonexistent")
        XCTAssertEqual(SettingsModel.nameCache["com.example.nonexistent"],
                       "com.example.nonexistent", "the miss must be cached too")
    }

    /// Throttled reload: at most one rebuild per second, no matter how many windows become
    /// key. Observed through `modeRows`: a skipped reload leaves the emptied rows empty.
    func testThrottledReloadSkipsWithinTheWindow() {
        let model = SettingsModel(selected: .apps)
        model.reloadModeTable()
        XCTAssertFalse(model.modeRows.isEmpty, "a direct reload always rebuilds")

        model.modeRows = []                       // make a rebuild observable
        model.reloadModeTableThrottled()          // immediately after → must be skipped
        XCTAssertTrue(model.modeRows.isEmpty, "a second reload inside the window must be skipped")
    }

    func testThrottledReloadRunsOnceTheWindowHasPassed() {
        let model = SettingsModel(selected: .apps)
        model.reloadModeTable()
        model.modeRows = []
        model.lastModeReloadAt -= 2               // pretend the last rebuild was 2s ago
        model.reloadModeTableThrottled()
        XCTAssertFalse(model.modeRows.isEmpty, "outside the window the rebuild must happen")
    }

    /// A direct (unthrottled) reload must also RESET the throttle clock, or the next
    /// window-focus reload would fire immediately after it and undo the guard.
    func testDirectReloadStampsTheThrottleClock() {
        let model = SettingsModel(selected: .apps)
        model.lastModeReloadAt = 0
        model.reloadModeTable()
        XCTAssertGreaterThan(model.lastModeReloadAt, 0, "reloadModeTable must stamp the clock")
    }
}

// The bug-report debug header (Save debug log…) is what testers paste into chat —
// it must reflect EVERY setting that can make one machine misbehave and another not.
// Gap found 2026-08-05 (J2TeamNNL "chỉ mỗi em bị"): tapNativeFastPath (a hidden
// Terminal-only flag on the tap hot path) and custom gõ tắt shortcuts were both
// completely absent from the file testers actually send.
final class DebugHeaderCoverageTests: XCTestCase {
    func testHeaderIncludesHiddenTapFlagAndShortcutCount() {
        let saved = (AppState.shared.tapNativeFastPath, AppState.shared.shortcuts)
        defer { AppState.shared.setShortcuts(saved.1) }

        AppState.shared.setShortcuts(["vn": "Việt Nam", "ko": "không", "cty": "công ty"])
        let header = DebugHeader.build().joined(separator: "\n")

        // Hidden flag must be visible even though there's no UI toggle for it.
        XCTAssertTrue(header.contains("nativeFastPath=\(saved.0)"), header)
        // Count only — never the trigger/expansion text itself.
        XCTAssertTrue(header.contains("custom shortcuts: 3"), header)
        XCTAssertFalse(header.contains("Việt Nam"), "debug header must never carry shortcut content")
        XCTAssertFalse(header.contains("công ty"), "debug header must never carry shortcut content")
    }

    func testZeroShortcutsStillReportsTheCount() {
        let saved = AppState.shared.shortcuts
        defer { AppState.shared.setShortcuts(saved) }
        AppState.shared.setShortcuts([:])
        XCTAssertTrue(DebugHeader.build().contains("custom shortcuts: 0"))
    }
}
