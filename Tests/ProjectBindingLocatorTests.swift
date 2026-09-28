import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

/// `README.md` documents saving `.xcode-switcher.json` in a repository so that everyone who
/// clones it inherits the pin. The removal guard only read the App's project list, so that
/// documented arrangement pinned nothing: the version could be moved to the Trash while a
/// repository said otherwise. These tests pin both stores and the ways they combine.
final class ProjectBindingLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-switcher-bindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    private func installation(_ path: String, _ version: String, _ build: String) -> XcodeInstallation {
        XcodeInstallation(appURL: URL(fileURLWithPath: path), version: version, build: build)
    }

    /// The arrangement that makes a version selector ambiguous: a beta and a release.
    private var release: XcodeInstallation { installation("/Applications/Xcode.app", "27.0", "27A266a") }
    private var beta: XcodeInstallation { installation("/Applications/Xcode-beta.app", "27.0", "27A5218g") }
    private var older: XcodeInstallation { installation("/Applications/Xcode_26.3.app", "26.3", "17C529") }

    /// A project package plus the local configuration the case asks for.
    @discardableResult
    private func makeProject(_ relativePath: String, configuration: String? = nil) throws -> URL {
        let project = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if let configuration {
            let file = project.deletingLastPathComponent().appendingPathComponent(".xcode-switcher.json")
            try configuration.write(to: file, atomically: true, encoding: .utf8)
        }
        return project
    }

    private func writeConfiguration(_ json: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(
            to: directory.appendingPathComponent(".xcode-switcher.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func bindings(
        to target: XcodeInstallation,
        profiles: [ProjectProfile] = [],
        discovered: [URL] = [],
        aliases: [String: String] = [:],
        among installations: [XcodeInstallation]? = nil
    ) -> [XcodeRemovalBinding] {
        ProjectBindingLocator.bindings(
            to: target,
            among: installations ?? [release, beta, older],
            profiles: profiles,
            discoveredProjects: discovered,
            aliases: aliases
        )
    }

    // MARK: - App 内绑定

    func testReportsAProfileThatPinsTheInstallation() throws {
        let profiles = [
            ProjectProfile(name: "Aligned", path: "/tmp/Aligned.xcodeproj", xcodeID: release.id),
            ProjectProfile(name: "Unpinned", path: "/tmp/Unpinned.xcodeproj"),
            ProjectProfile(name: "Other", path: "/tmp/Other.xcodeproj", xcodeID: older.id)
        ]

        XCTAssertEqual(
            bindings(to: release, profiles: profiles),
            [XcodeRemovalBinding(projectName: "Aligned", origin: .appProfile)]
        )
    }

    // MARK: - 仓库里的本地绑定

    func testReportsALocalConfigurationThatPinsByVersion() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "26.3"}"#)

        XCTAssertEqual(
            bindings(to: older, profiles: [], discovered: [project]),
            [
                XcodeRemovalBinding(
                    projectName: "repo",
                    origin: .localConfiguration(project.deletingLastPathComponent()
                        .appendingPathComponent(".xcode-switcher.json").path)
                )
            ]
        )
    }

    /// The file covers everything below the directory it sits in, so a repository pins all of
    /// its projects with one file — and is reported once, not once per project.
    func testReportsARootConfigurationOnceForSeveralProjectsBelowIt() throws {
        try writeConfiguration(#"{"xcode": "27.0"}"#, in: root.appendingPathComponent("monorepo"))
        let first = try makeProject("monorepo/A/A.xcodeproj")
        let second = try makeProject("monorepo/B/B.xcodeproj")
        let third = try makeProject("monorepo/C/C.xcworkspace")

        let reported = bindings(to: release, discovered: [first, second, third])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.projectName, "monorepo")
        XCTAssertEqual(
            reported.first?.origin,
            .localConfiguration(root.appendingPathComponent("monorepo/.xcode-switcher.json").path)
        )
    }

    func testIgnoresALocalConfigurationThatPinsSomethingElse() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "26.3"}"#)

        XCTAssertTrue(bindings(to: release, discovered: [project]).isEmpty)
    }

    /// A repository saying `"27.0"` while a beta and a release of 27.0 are installed does not
    /// say which one it means, so it pins both: refusing either removal is the only answer
    /// that cannot be wrong. The same rule governs the command line since 2.2.2.
    func testTreatsAnAmbiguousSelectorAsPinningEveryCandidate() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "27.0"}"#)

        let forRelease = bindings(to: release, discovered: [project])
        let forBeta = bindings(to: beta, discovered: [project])

        XCTAssertEqual(forRelease.count, 1)
        XCTAssertEqual(forBeta, forRelease)
    }

    func testResolvesAliasesInALocalConfiguration() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "stable"}"#)

        XCTAssertEqual(bindings(to: release, discovered: [project], aliases: [release.id: "stable"]).count, 1)
        XCTAssertTrue(bindings(to: older, discovered: [project], aliases: [release.id: "stable"]).isEmpty)
    }

    func testResolvesAnAppPathInALocalConfiguration() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "/Applications/Xcode.app"}"#)

        XCTAssertEqual(bindings(to: release, discovered: [project]).count, 1)
        XCTAssertTrue(bindings(to: beta, discovered: [project]).isEmpty)
    }

    func testIgnoresAWorkspaceOnlyConfigurationAndACorruptFile() throws {
        let workspaceOnly = try makeProject("a/App.xcodeproj", configuration: #"{"workspace": "App.xcworkspace"}"#)
        let corrupt = try makeProject("b/App.xcodeproj", configuration: "{ not json")

        XCTAssertTrue(bindings(to: release, discovered: [workspaceOnly, corrupt]).isEmpty)
    }

    func testReportsBothStoresForTheSameProject() throws {
        let project = try makeProject("repo/App.xcodeproj", configuration: #"{"xcode": "26.3"}"#)
        let profiles = [ProjectProfile(name: "App", path: project.path, xcodeID: older.id)]

        XCTAssertEqual(
            bindings(to: older, profiles: profiles, discovered: [project]),
            [
                XcodeRemovalBinding(projectName: "App", origin: .appProfile),
                XcodeRemovalBinding(
                    projectName: "repo",
                    origin: .localConfiguration(root.appendingPathComponent("repo/.xcode-switcher.json").path)
                )
            ]
        )
    }
}
