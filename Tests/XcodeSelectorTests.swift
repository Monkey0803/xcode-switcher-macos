import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

/// The selector is the one place a command can act on the wrong Xcode: on 2026-09-28
/// `xcodeswitcher uninstall 27.0` resolved to `/Applications/Xcode-beta.app` while the user
/// meant `/Applications/Xcode.app`, because two installations shared the version and the
/// lookup took the first match. These tests pin the refusal, the precedence of the unique
/// forms over the ambiguous ones, and the order the candidates are reported in.
final class XcodeSelectorTests: XCTestCase {
    private func installation(_ path: String, _ version: String, _ build: String) -> XcodeInstallation {
        XcodeInstallation(appURL: URL(fileURLWithPath: path), version: version, build: build)
    }

    /// The arrangement that caused it: a beta and a release of the same version.
    private var sameVersion: [XcodeInstallation] {
        [
            installation("/Applications/Xcode-beta.app", "27.0", "27A5218g"),
            installation("/Applications/Xcode.app", "27.0", "27A266a")
        ]
    }

    func testResolvesAnAppPath() {
        XCTAssertEqual(
            XcodeSelector.resolve("/Applications/Xcode.app", among: sameVersion),
            .resolved("/Applications/Xcode.app")
        )
    }

    func testResolvesADeveloperPath() {
        XCTAssertEqual(
            XcodeSelector.resolve("/Applications/Xcode.app/Contents/Developer", among: sameVersion),
            .resolved("/Applications/Xcode.app")
        )
    }

    func testResolvesATildePath() {
        let home = XcodeCleanupReporter.home
        let installations = [installation("\(home)/Applications/Xcode.app", "26.3", "17C529")]
        XCTAssertEqual(
            XcodeSelector.resolve("~/Applications/Xcode.app", among: installations),
            .resolved("\(home)/Applications/Xcode.app")
        )
    }

    func testResolvesAnAppNameCaseInsensitively() {
        XCTAssertEqual(
            XcodeSelector.resolve("xcode-beta", among: sameVersion),
            .resolved("/Applications/Xcode-beta.app")
        )
    }

    func testResolvesAnAlias() {
        XCTAssertEqual(
            XcodeSelector.resolve(
                "stable",
                among: sameVersion,
                aliases: ["/Applications/Xcode.app": "stable"]
            ),
            .resolved("/Applications/Xcode.app")
        )
    }

    func testResolvesASingleVersionMatch() {
        let installations = sameVersion + [installation("/Applications/Xcode_26.3.app", "26.3", "17C529")]
        XCTAssertEqual(
            XcodeSelector.resolve("26.3", among: installations),
            .resolved("/Applications/Xcode_26.3.app")
        )
    }

    /// The regression this whole type exists for. Both candidates are reported, in the order
    /// the caller passed them, so the message can name each build and path.
    func testRefusesAVersionThatMatchesTwoInstallations() {
        XCTAssertEqual(
            XcodeSelector.resolve("27.0", among: sameVersion),
            .ambiguous(["/Applications/Xcode-beta.app", "/Applications/Xcode.app"])
        )
    }

    /// A release and a beta can share both the version *and* the file's base name ("Xcode"
    /// after stripping the extension would have to collide, so this uses two directories).
    func testRefusesANameThatMatchesTwoInstallations() {
        let installations = [
            installation("/Applications/Xcode.app", "27.0", "27A266a"),
            installation("/Volumes/Extra/Xcode.app", "26.3", "17C529")
        ]
        XCTAssertEqual(
            XcodeSelector.resolve("Xcode", among: installations),
            .ambiguous(["/Applications/Xcode.app", "/Volumes/Extra/Xcode.app"])
        )
    }

    /// The unique forms must still win: refusing "/Applications/Xcode.app" because another
    /// installation happens to share the name would make the disambiguation impossible.
    func testAPathWinsOverAnAmbiguousName() {
        let installations = [
            installation("/Applications/Xcode.app", "27.0", "27A266a"),
            installation("/Volumes/Extra/Xcode.app", "26.3", "17C529")
        ]
        XCTAssertEqual(
            XcodeSelector.resolve("/Applications/Xcode.app", among: installations),
            .resolved("/Applications/Xcode.app")
        )
    }

    func testReportsSomethingThatMatchesNothing() {
        XCTAssertEqual(XcodeSelector.resolve("99.9", among: sameVersion), .notFound)
        XCTAssertEqual(XcodeSelector.resolve("Nothing", among: sameVersion), .notFound)
    }

    func testAnEmptyListResolvesNothing() {
        XCTAssertEqual(XcodeSelector.resolve("/Applications/Xcode.app", among: []), .notFound)
        XCTAssertEqual(XcodeSelector.resolve("27.0", among: []), .notFound)
    }
}
