import XCTest
@testable import VietTelex

// The app must recognize its OWN input source, whatever bundle id this build was
// installed under. The Debug configuration uses a separate development namespace
// (docs/MACOS_IME_NOTES.md), and while the ship id was hardcoded
// in isVietTelexSelected() the dev build answered "VietTelex is not selected" about
// itself — so the TIS notification, deactivateServer and the per-key reconcile all
// put the tap DORMANT mid-word. Tester log 2026-08-13: "biết" in Terminal came out
// "biêts" (the tone key passed through raw during a dormant window), and ⌫ back to
// "bi" then `s` gave "bis" instead of "bí" (dormancy also resets the engine).
//
// Everything here drives `inputSourceIsOurs` through its explicit `own:` seam. A test
// that compared OwnBundle.id against Bundle.main would be tautological — both sides
// read the same property, and CI builds under the ship id, so re-hardcoding that
// literal would still pass. Exact bundle/mode matching keeps sibling Debug IDs apart.
final class OwnBundleIdentityTests: XCTestCase {

    private let ship = "com.viettelex.inputmethod.telex"
    private let dev = "com.viettelex.inputmethod.viettelexdev"

    /// The regression itself: a dev build asking the SHIP prefix disowns its own input
    /// source; asking its own id recognizes it. The ship build is unaffected.
    func testDevBuildRecognizesItsOwnInputSource() {
        XCTAssertFalse(TelexInputController.inputSourceIsOurs(dev + ".vi", own: ship))
        XCTAssertTrue(TelexInputController.inputSourceIsOurs(dev + ".vi", own: dev))
        XCTAssertTrue(TelexInputController.inputSourceIsOurs(ship + ".vi", own: ship))
    }

    func testDebugAndReleaseIdentitiesRemainDisjoint() {
        XCTAssertNotEqual(dev, ship)
        XCTAssertNotEqual(dev + ".vi", ship + ".vi")
        XCTAssertNotEqual(dev + "_Connection", ship + "_Connection")
    }

    func testAccessibilityPromptIsOnlyShownForSignedUntrustedBuildsOnce() {
        XCTAssertTrue(TelexInputController.shouldPromptAccessibility(
            trusted: false, alreadyPrompted: false, isOurSignedBuild: true))
        XCTAssertFalse(TelexInputController.shouldPromptAccessibility(
            trusted: true, alreadyPrompted: false, isOurSignedBuild: true))
        XCTAssertFalse(TelexInputController.shouldPromptAccessibility(
            trusted: false, alreadyPrompted: true, isOurSignedBuild: true))
        XCTAssertFalse(TelexInputController.shouldPromptAccessibility(
            trusted: false, alreadyPrompted: false, isOurSignedBuild: false),
            "ad-hoc Debug cannot receive a durable grant and must not nag")
    }

    /// UX 14/10/2026: the first-run prompt waits for a ≥2s typing pause and Return in
    /// flight must not hit "Open Settings".
    func testFirstRunAccessibilityPromptWaitsForTypingPause() {
        typealias P = TelexInputController.AXPromptPause
        var p = P()
        let s: UInt64 = 1_000_000_000
        XCTAssertFalse(p.tick(gen: 10, nowNs: 0))            // seed
        XCTAssertFalse(p.tick(gen: 11, nowNs: s))            // typing
        XCTAssertFalse(p.tick(gen: 12, nowNs: 2 * s))        // still typing
        XCTAssertFalse(p.tick(gen: 12, nowNs: 3 * s))        // 1s idle
        XCTAssertFalse(p.tick(gen: 13, nowNs: 3 * s + 900_000_000))   // a key restarts the wait
        XCTAssertFalse(p.tick(gen: 13, nowNs: 5 * s))
        XCTAssertTrue(p.tick(gen: 13, nowNs: 3 * s + 900_000_000 + P.idleNs))

        let k = TelexInputController.axPromptKeyEquivalents(firstRun: true)
        XCTAssertEqual(k?.open, "", "Return must not open Settings on the first-run prompt")
        XCTAssertEqual(k?.close, "\u{1b}")
        XCTAssertNil(TelexInputController.axPromptKeyEquivalents(firstRun: false),
                     "user-requested prompt keeps NSAlert defaults")
    }

    func testBundlePlistUsesConfigurationSpecificIdentityEverywhere() {
        #if DEBUG
        let expected = dev
        #else
        let expected = ship
        #endif
        let appBundle = Bundle(for: TelexInputController.self)
        let info = try! XCTUnwrap(appBundle.infoDictionary)
        XCTAssertEqual(appBundle.bundleIdentifier, expected)
        #if DEBUG
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       "VietTelex Dev")
        #else
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       "VietTelex")
        #endif
        XCTAssertEqual(info["TISInputSourceID"] as? String, expected)
        XCTAssertEqual(info["InputMethodConnectionName"] as? String, expected + "_Connection")

        let component = try! XCTUnwrap(info["ComponentInputModeDict"] as? [String: Any])
        let modes = try! XCTUnwrap(component["tsInputModeListKey"] as? [String: Any])
        let mode = try! XCTUnwrap(modes[expected + ".vi"] as? [String: Any],
                                  "available mode ids: \(modes.keys.sorted())")
        XCTAssertEqual(mode["TISInputSourceID"] as? String, expected + ".vi")
        XCTAssertEqual(component["tsVisibleInputModeOrderedArrayKey"] as? [String],
                       [expected + ".vi"])
    }

    /// The bundle id itself and its `.vi` input mode both match; a sibling id that
    /// merely shares the namespace does not.
    func testInputSourceAndModeMatchButSiblingsDoNot() {
        XCTAssertTrue(TelexInputController.inputSourceIsOurs(ship, own: ship))
        XCTAssertTrue(TelexInputController.inputSourceIsOurs(ship + ".vi", own: ship))
        XCTAssertFalse(TelexInputController.inputSourceIsOurs(ship, own: dev))
        XCTAssertFalse(TelexInputController.inputSourceIsOurs(dev + ".vi", own: ship))
    }

    func testForeignInputSourceDoesNotMatch() {
        XCTAssertFalse(TelexInputController.inputSourceIsOurs("com.apple.keylayout.ABC"))
        XCTAssertFalse(TelexInputController.inputSourceIsOurs("com.apple.keylayout.ABC", own: ship))
        XCTAssertFalse(
            TelexInputController.inputSourceIsOurs("com.apple.inputmethod.VietnameseIM.VietnameseTelex",
                                                   own: ship))
    }

    /// An empty prefix must match NOTHING. Bare `hasPrefix("")` is true for every id,
    /// which would report VietTelex selected while the user types in ABC and leave the
    /// tap composing Vietnamese over English.
    func testEmptyPrefixMatchesNothing() {
        XCTAssertFalse(TelexInputController.inputSourceIsOurs("com.apple.keylayout.ABC", own: ""))
        XCTAssertFalse(TelexInputController.inputSourceIsOurs(ship + ".vi", own: ""))
    }

    /// …and OwnBundle never hands one out, so the guard above is belt-and-braces.
    func testOwnBundleIDIsNeverEmpty() {
        XCTAssertFalse(OwnBundle.id.isEmpty)
    }

    /// Debug-Info.plist is a hand-kept copy of Info.plist: Xcode expands build
    /// variables in plist VALUES but not KEYS, and tsInputModeListKey is keyed by the
    /// mode id — so one shared plist can't carry both identities (measured 24/09/2026).
    /// Pin that the copy never drifts: after mapping the development identity back onto the
    /// shipping one, the two files must be identical except for version numbers
    /// (bumped on Info.plist only) and the development display name.
    func testDevPlistStaysInSyncWithReleasePlist() throws {
        let res = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources")
        func load(_ name: String) throws -> String {
            try String(contentsOf: res.appendingPathComponent(name), encoding: .utf8)
        }
        func normalize(_ xml: String) throws -> NSDictionary {
            let data = Data(xml.replacingOccurrences(of: dev,
                                                     with: "com.viettelex.inputmethod.telex").utf8)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let d = try XCTUnwrap(plist as? [String: Any])
            var out = d
            for k in ["CFBundleShortVersionString", "CFBundleVersion", "CFBundleName",
                      "CFBundleDisplayName"] { out.removeValue(forKey: k) }
            return try XCTUnwrap(stripNames(out) as? [String: Any]) as NSDictionary
        }
        // Display titles differ by design ("VietTelex Dev"): bundle name and the
        // input mode's menu title. Everything else — ids, connection, icons, modes —
        // must match.
        let titleKeys: Set<String> = ["tsInputModeAlternateMenuTitleStringKey"]
        func stripNames(_ v: Any) -> Any {
            if let d = v as? [String: Any] {
                var o: [String: Any] = [:]
                for (k, x) in d where !titleKeys.contains(k) {
                    o[k] = stripNames(x)
                }
                return o
            }
            if let a = v as? [Any] { return a.map(stripNames) }
            return v
        }
        let release = try normalize(load("Info.plist"))
        let development = try normalize(load("Debug-Info.plist"))
        XCTAssertEqual(release, development,
                       "Debug-Info.plist drifted from Info.plist — mirror the change (only ids/name/version may differ)")
    }
}
