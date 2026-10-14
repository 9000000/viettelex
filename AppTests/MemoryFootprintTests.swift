import XCTest
import AppKit
import Darwin
@testable import VietTelex

// RAM của process IME (Activity Monitor "Memory" = phys_footprint). Field 04/10/2026: 1.8.10
// chạy 4h, đã mở Cài đặt một lần ⇒ 54 MB, trong đó ~17 MB là trang malloc đã free nhưng
// chưa trả (49% fragmentation) — đỉnh tạm thời do cửa sổ Cài đặt SwiftUI để lại.
//
// Các test đo trong test host (cùng binary, không IMKServer/tap — xem main.swift). Cửa sổ
// Cài đặt được dựng KHÔNG kích hoạt app (alpha 0, orderFrontRegardless) — không cướp focus.
final class MemoryFootprintTests: XCTestCase {

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func mallocInUse() -> (inUse: Int, allocated: Int) {
        var st = malloc_statistics_t()
        malloc_zone_statistics(nil, &st)
        return (st.size_in_use, st.size_allocated)
    }

    private func log(_ label: String) {
        let f = MemoryFootprint.sample(), m = mallocInUse()
        print(String(format: "MEM %-34@ footprint %7.1f MB  peak %7.1f MB  malloc live %6.1f MB  held %6.1f MB",
                     label as NSString,
                     Double(f.current) / 1_048_576, Double(f.peak) / 1_048_576,
                     Double(m.inUse) / 1_048_576, Double(m.allocated) / 1_048_576))
    }

    /// In bảng số (grep "MEM") để so trước/sau; chỉ assert chiều: các lượt relief trễ
    /// (cách hiện tại) trả về ít nhất bằng một lượt ngay sau đóng (cách cũ).
    func testPrintFootprintBreakdown() {
        log("0 test host start")
        _ = AppState.shared.engineFlags()
        _ = TypoFixLogic.isKnown("the")
        _ = TypoFixLogic.lexiconCorrection(raw: "tooi", flags: AppState.shared.engineFlags())
        _ = TypoFixLogic.lexiconCorrection(raw: "nhuwng", flags: AppState.shared.engineFlags())
        log("1 typing data warm")
        // Không giữ biến local tới window/model qua lúc đóng — giữ thì graph sống lâu hơn
        // đường thật (controller là chủ duy nhất) và số đo sai.
        let c = SettingsWindowController()
        autoreleasepool {
            c.buildWindowIfNeeded(tab: .typing)
            c.currentWindow?.alphaValue = 0
            c.currentWindow?.ignoresMouseEvents = true
            c.currentWindow?.orderFrontRegardless()
            for tab in SettingsTab.allCases {
                c.currentModel?.selectedTab = tab
                spin(0.3)
                c.currentWindow?.displayIfNeeded()
            }
            log("2 settings open, all tabs drawn")
            c.currentWindow?.close()
        }
        spin(0.05)
        let t0 = DispatchTime.now().uptimeNanoseconds
        malloc_zone_pressure_relief(nil, 0)            // cách cũ: một lượt, một hop sau đóng
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let old = MemoryFootprint.sample().current
        log(String(format: "3 closed, one-hop relief (%.1fms)", ms))
        spin((MemoryFootprint.reliefDelays.max() ?? 10) + 1)   // các lượt trễ do windowWillClose lên lịch
        let new = MemoryFootprint.sample().current
        log("4 closed, delayed relief passes")
        XCTAssertLessThanOrEqual(new, old + 1_048_576)
        // Mở lại lần hai: heap sống không được cộng thêm một graph nữa (issue #59).
        let live1 = mallocInUse().inUse
        autoreleasepool {
            c.buildWindowIfNeeded(tab: .apps)
            c.currentWindow?.alphaValue = 0
            c.currentWindow?.orderFrontRegardless()
            spin(0.3)
            c.currentWindow?.displayIfNeeded()
            c.currentWindow?.close()
        }
        spin((MemoryFootprint.reliefDelays.max() ?? 10) + 1)
        log("5 second open/close + relief")
        XCTAssertLessThan(mallocInUse().inUse - live1, 4 << 20, "re-opening Settings must not retain another graph")
    }

    func testFootprintSampleAndDebugHeaderLine() {
        let s = MemoryFootprint.sample()
        XCTAssertGreaterThan(s.current, 1 << 20)
        XCTAssertGreaterThanOrEqual(s.peak, s.current)
        XCTAssertTrue(DebugHeader.build().contains { $0.hasPrefix("memory: ") && $0.contains("peak") })
    }

    /// Chi phí từng tab (cửa sổ mới cho mỗi tab, relief giữa các lần) — chỉ in, không assert.
    func testPrintPerTabCost() {
        let c = SettingsWindowController()
        for tab in SettingsTab.allCases + [.typing] {
            malloc_zone_pressure_relief(nil, 0)
            let before = MemoryFootprint.sample().current, liveBefore = mallocInUse().inUse
            var open: UInt64 = 0, liveOpen = 0
            autoreleasepool {
                c.buildWindowIfNeeded(tab: tab)
                c.currentModel?.selectedTab = tab
                c.currentWindow?.alphaValue = 0
                c.currentWindow?.orderFrontRegardless()
                spin(0.4)
                c.currentWindow?.displayIfNeeded()
                open = MemoryFootprint.sample().current; liveOpen = mallocInUse().inUse
                c.currentWindow?.close()
            }
            spin(1)
            print(String(format: "MEMTAB %-14@ open +%6.1f MB footprint, +%6.1f MB live",
                         "\(tab)" as NSString, Double(Int64(open) - Int64(before)) / 1_048_576,
                         Double(liveOpen - liveBefore) / 1_048_576))
        }
    }

    /// Đóng Cài đặt phải giải phóng TOÀN BỘ đồ thị SwiftUI (window, hosting controller,
    /// model) — không thì mỗi lần mở lại cộng thêm một graph (issue #59).
    func testSettingsWindowDeallocatesOnClose() {
        assertDeallocates(tab: .typing)
    }

    func testEachTabDeallocatesOnClose() {
        for tab in SettingsTab.allCases where tab != .typing {
            assertDeallocates(tab: tab)
        }
    }

    func testSwitchingAllTabsDeallocatesOnClose() {
        assertDeallocates(tab: .typing, visitAll: true)
    }

    private func assertDeallocates(tab: SettingsTab, visitAll: Bool = false, line: UInt = #line) {
        let c = SettingsWindowController()
        weak var weakWin: NSWindow?
        weak var weakModel: SettingsModel?
        weak var weakHosting: NSViewController?
        autoreleasepool {
            c.buildWindowIfNeeded(tab: tab)
            c.currentModel?.selectedTab = tab
            weakWin = c.currentWindow
            weakModel = c.currentModel
            weakHosting = c.currentWindow?.contentViewController
            c.currentWindow?.alphaValue = 0
            c.currentWindow?.orderFrontRegardless()
            spin(0.3)
            if visitAll {
                for t in SettingsTab.allCases.dropFirst() + [.typing] {
                    c.currentModel?.selectedTab = t
                    spin(0.3)
                    c.currentWindow?.displayIfNeeded()
                }
            }
            c.currentWindow?.close()
        }
        spin(0.5)
        XCTAssertNil(c.currentWindow, "\(tab)", line: line)
        XCTAssertNil(weakModel, "SettingsModel must die with the window (\(tab))", line: line)
        XCTAssertNil(weakHosting, "NSHostingController must die with the window (\(tab))", line: line)
        XCTAssertNil(weakWin, "NSWindow must deallocate after close (\(tab))", line: line)
    }
}
