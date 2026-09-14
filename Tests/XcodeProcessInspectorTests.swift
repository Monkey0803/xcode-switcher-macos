import XCTest
@testable import XcodeSwitcher

final class XcodeProcessInspectorTests: XCTestCase {
    private func installation(name: String, version: String) throws -> XcodeInstallation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeProcessInspector-")
            .appendingPathComponent(name + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return XcodeInstallation(appURL: root, version: version, build: "0")
    }

    func testMatchesRunningXcodesByBundlePath() throws {
        let stable = try installation(name: "Xcode", version: "26.3")
        let beta = try installation(name: "Xcode-beta", version: "27.0")

        // Stable and beta share one bundle identifier, so only the path can tell
        // which of the discovered copies is actually running.
        let running = XcodeProcessInspector.runningInstallations(
            among: [stable, beta],
            runningAppURLs: [beta.appURL]
        )

        XCTAssertEqual(running.map(\.name), [beta.name])
    }

    func testIgnoresUnrelatedAndRenamedCopies() throws {
        let abandoned = try installation(name: "Xcode-old", version: "15.0")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("Safari.app", isDirectory: true)

        XCTAssertTrue(
            XcodeProcessInspector.runningInstallations(among: [abandoned], runningAppURLs: [other]).isEmpty
        )
        XCTAssertTrue(
            XcodeProcessInspector.runningInstallations(among: [abandoned], runningAppURLs: []).isEmpty
        )
    }
}
