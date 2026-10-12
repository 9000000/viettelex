import XCTest
@testable import VietTelex

final class SettingsSuiteResolutionTests: XCTestCase {
    func testTestSuiteTakesPrecedenceForEitherBundle() {
        XCTAssertEqual(
            AppState.resolveSettingsSuiteName(
                isTestHost: true,
                bundleIdentifier: AppState.developmentBundleIdentifier
            ),
            AppState.testSettingsSuiteName
        )
        XCTAssertEqual(
            AppState.resolveSettingsSuiteName(
                isTestHost: true,
                bundleIdentifier: AppState.stableBundleIdentifier
            ),
            AppState.testSettingsSuiteName
        )
    }

    func testDevelopmentBundleUsesItsOwnSuite() {
        XCTAssertEqual(
            AppState.resolveSettingsSuiteName(
                isTestHost: false,
                bundleIdentifier: AppState.developmentBundleIdentifier
            ),
            AppState.developmentSettingsSuiteName
        )
    }

    func testStableAndUnknownBundlesKeepTheProductionSuite() {
        XCTAssertEqual(
            AppState.resolveSettingsSuiteName(
                isTestHost: false,
                bundleIdentifier: AppState.stableBundleIdentifier
            ),
            AppState.stableSettingsSuiteName
        )
        XCTAssertEqual(
            AppState.resolveSettingsSuiteName(isTestHost: false, bundleIdentifier: nil),
            AppState.stableSettingsSuiteName
        )
    }

    func testSelfUpdaterOnlyTargetsTheStableBundle() {
        XCTAssertTrue(SelfUpdater.canInstallUpdate(bundleIdentifier: AppState.stableBundleIdentifier))
        XCTAssertFalse(SelfUpdater.canInstallUpdate(bundleIdentifier: AppState.developmentBundleIdentifier))
        XCTAssertFalse(SelfUpdater.canInstallUpdate(bundleIdentifier: nil))
    }
}
