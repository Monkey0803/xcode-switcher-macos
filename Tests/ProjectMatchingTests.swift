import Foundation
import XCTest
@testable import XcodeSwitcher

final class ProjectMatchingTests: XCTestCase {
    func testXcodeVersionFileMatchesInstalledVersion() throws {
        let fixture = try Fixture()
        try fixture.write("16.4\n", to: ".xcode-version")
        let installation = fixture.installation(version: "16.4.0", name: "Xcode-16.4.app")

        let match = ProjectXcodeMatcher.match(
            projectURL: fixture.projectURL,
            installations: [installation]
        )

        XCTAssertEqual(match?.requirement.normalizedVersion, "16.4")
        XCTAssertEqual(match?.installationID, installation.id)
    }

    func testToolVersionsIsDetectedFromParentDirectory() throws {
        let fixture = try Fixture(nestedProject: true)
        try fixture.write("ruby 3.3.0\nxcode 15.4\n", to: ".tool-versions")

        let requirement = ProjectXcodeMatcher.requirement(for: fixture.projectURL)

        XCTAssertEqual(requirement?.normalizedVersion, "15.4")
        XCTAssertEqual(URL(fileURLWithPath: requirement?.source ?? "").lastPathComponent, ".tool-versions")
    }

    func testMissingExplicitBindingNeverFallsBack() throws {
        let fixture = try Fixture()
        let installed = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(
            name: "Demo",
            path: fixture.projectURL.path,
            xcodeID: "/Applications/Xcode-15.app"
        )

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [installed],
            activeInstallationID: installed.id
        )

        XCTAssertEqual(result, .missingBoundXcode(path: "/Applications/Xcode-15.app"))
        XCTAssertNil(result.installationID)
    }

    func testMissingRequiredVersionNeverFallsBack() throws {
        let fixture = try Fixture()
        try fixture.write("15.4", to: ".xcode-version")
        let installed = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path)

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [installed],
            activeInstallationID: installed.id
        )

        guard case let .missingRequiredXcode(requirement) = result else {
            return XCTFail("Expected missing required Xcode, got \(result)")
        }
        XCTAssertEqual(requirement.normalizedVersion, "15.4")
        XCTAssertNil(result.installationID)
    }

    func testMissingProjectIsReportedBeforeVersionResolution() throws {
        let fixture = try Fixture()
        let missingPath = fixture.root.appendingPathComponent("Missing.xcodeproj").path
        let profile = ProjectProfile(name: "Missing", path: missingPath)

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [],
            activeInstallationID: nil
        )

        XCTAssertEqual(result, .missingProject(path: missingPath))
    }
}

private final class Fixture {
    let root: URL
    let projectURL: URL

    init(nestedProject: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSwitcherTests-\(UUID().uuidString)", isDirectory: true)
        let projectParent = nestedProject ? root.appendingPathComponent("Sources/App", isDirectory: true) : root
        projectURL = projectParent.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func installation(version: String, name: String) -> XcodeInstallation {
        XcodeInstallation(
            appURL: root.appendingPathComponent(name, isDirectory: true),
            version: version,
            build: ""
        )
    }
}
