import XCTest
@testable import XcodeSwitcherKit

final class WorkspaceXcodeConflictTests: XCTestCase {
    func testReportsDifferentProjectRequirementsInsideWorkspace() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.addProject(named: "App", version: "15.4")
        try fixture.addProject(named: "Tools", version: "16.0")

        let conflict = WorkspaceXcodeConflictDetector.conflict(
            in: fixture.workspaceURL,
            installations: [fixture.installation(version: "15.4"), fixture.installation(version: "16.0")]
        )

        XCTAssertEqual(conflict?.versions, ["15.4", "16.0"])
        XCTAssertEqual(conflict?.requirements.map(\.projectName).sorted(), ["App", "Tools"])
    }

    func testIgnoresWorkspaceWhenEveryProjectRequiresTheSameVersion() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.addProject(named: "App", version: "16.0")
        try fixture.addProject(named: "Tools", version: "16.0")

        XCTAssertNil(
            WorkspaceXcodeConflictDetector.conflict(
                in: fixture.workspaceURL,
                installations: [fixture.installation(version: "16.0")]
            )
        )
    }
}

private final class WorkspaceFixture {
    let root: URL
    let workspaceURL: URL
    private var projectLocations: [String] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceConflict-\(UUID().uuidString)")
        workspaceURL = root.appendingPathComponent("Demo.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    func addProject(named name: String, version: String) throws {
        let directory = root.appendingPathComponent("Projects/\(name)", isDirectory: true)
        let projectURL = directory.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("{\"xcode\": \"\(version)\"}".utf8)
            .write(to: directory.appendingPathComponent(".xcode-switcher.json"))
        projectLocations.append("Projects/\(name)/\(name).xcodeproj")
        let body = projectLocations.map { "  <FileRef location=\"group:\($0)\"/>" }.joined(separator: "\n")
        try "<Workspace version=\"1.0\">\n\(body)\n</Workspace>\n"
            .write(to: workspaceURL.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
    }

    func installation(version: String) -> XcodeInstallation {
        XcodeInstallation(appURL: root.appendingPathComponent("Xcode \(version).app"), version: version, build: "test-\(version)")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
