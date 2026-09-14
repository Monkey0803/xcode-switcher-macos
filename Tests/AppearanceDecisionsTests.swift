import XCTest
@testable import XcodeSwitcher

final class AppearanceDecisionsTests: XCTestCase {
    func testFallsBackToTheBorderedStyleWithoutGlass() {
        // The branch a pre-macOS 26 machine takes, and the one this suite cannot
        // reach through `#available` while running on a newer system.
        XCTAssertEqual(AppearanceDecisions.prominentButtonStyle(glassAvailable: false), .bordered)
        XCTAssertEqual(AppearanceDecisions.prominentButtonStyle(glassAvailable: true), .glass)
    }

    func testInstallsGlassOnlyOnceAndOnlyWhereAvailable() {
        XCTAssertTrue(AppearanceDecisions.shouldInstallGlass(glassAvailable: true, alreadyInstalled: false))
        XCTAssertFalse(AppearanceDecisions.shouldInstallGlass(glassAvailable: true, alreadyInstalled: true))
        XCTAssertFalse(AppearanceDecisions.shouldInstallGlass(glassAvailable: false, alreadyInstalled: false))
        XCTAssertFalse(AppearanceDecisions.shouldInstallGlass(glassAvailable: false, alreadyInstalled: true))
    }

    func testShortcutTitleStaysReadableOnBothPaths() {
        // Recording without glass draws on the flat accent fill, so the title has
        // to switch to white; with glass it must keep the standard colours.
        XCTAssertEqual(
            AppearanceDecisions.shortcutTitleColor(isRecording: true, usesGlass: false, isEnabled: true),
            .white
        )
        XCTAssertEqual(
            AppearanceDecisions.shortcutTitleColor(isRecording: true, usesGlass: true, isEnabled: true),
            .label
        )
        XCTAssertEqual(
            AppearanceDecisions.shortcutTitleColor(isRecording: false, usesGlass: false, isEnabled: true),
            .label
        )
        XCTAssertEqual(
            AppearanceDecisions.shortcutTitleColor(isRecording: false, usesGlass: true, isEnabled: false),
            .disabled
        )
        XCTAssertEqual(
            AppearanceDecisions.shortcutTitleColor(isRecording: true, usesGlass: false, isEnabled: false),
            .white
        )
    }
}
