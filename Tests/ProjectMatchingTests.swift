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

    func testExplicitBindingIsReportedAsResolutionSource() throws {
        let fixture = try Fixture()
        let installation = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(
            name: "Demo",
            path: fixture.projectURL.path,
            xcodeID: installation.id
        )

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [installation],
            activeInstallationID: nil
        )

        XCTAssertEqual(
            result,
            .resolved(installationID: installation.id, source: .explicitBinding)
        )
    }

    func testVersionFileRequirementIsReportedAsResolutionSource() throws {
        let fixture = try Fixture()
        try fixture.write("16.4\n", to: ".xcode-version")
        let installation = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path)

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [installation],
            activeInstallationID: nil
        )

        guard case let .resolved(installationID, source) = result else {
            return XCTFail("Expected a resolved Xcode, got \(result)")
        }
        XCTAssertEqual(installationID, installation.id)
        XCTAssertEqual(source, .automaticRequirement(ProjectXcodeRequirement(
            source: fixture.root.appendingPathComponent(".xcode-version").path,
            rawValue: "16.4",
            normalizedVersion: "16.4"
        )))
    }

    func testDifferingExplicitBindingRequiresOpenConfirmation() {
        let result = ProjectXcodeMatcher.openDecision(
            for: .resolved(installationID: "xcode-16", source: .explicitBinding),
            activeInstallationID: "xcode-15"
        )

        XCTAssertEqual(result, .requiresConfirmation(installationID: "xcode-16", source: .explicitBinding))
    }

    func testDifferingVersionRequirementRequiresOpenConfirmation() {
        let requirement = ProjectXcodeRequirement(source: "/tmp/.xcode-version", rawValue: "16.4", normalizedVersion: "16.4")

        let result = ProjectXcodeMatcher.openDecision(
            for: .resolved(installationID: "xcode-16", source: .automaticRequirement(requirement)),
            activeInstallationID: "xcode-15"
        )

        XCTAssertEqual(result, .requiresConfirmation(installationID: "xcode-16", source: .automaticRequirement(requirement)))
    }

    func testActiveRecommendationOpensWithoutConfirmation() {
        let result = ProjectXcodeMatcher.openDecision(
            for: .resolved(installationID: "xcode-16", source: .explicitBinding),
            activeInstallationID: "xcode-16"
        )

        XCTAssertEqual(result, .open(installationID: "xcode-16"))
    }

    func testCurrentXcodeFallbackOpensWithoutConfirmation() {
        let result = ProjectXcodeMatcher.openDecision(
            for: .resolved(installationID: "xcode-16", source: .currentInstallationFallback),
            activeInstallationID: "xcode-15"
        )

        XCTAssertEqual(result, .open(installationID: "xcode-16"))
    }

    func testResolutionSourceProvidesUserFacingDescription() {
        let requirement = ProjectXcodeRequirement(source: "/tmp/.tool-versions", rawValue: "xcode 16.4", normalizedVersion: "16.4")

        XCTAssertEqual(ProjectXcodeResolutionSource.explicitBinding.displayName, "项目固定绑定")
        XCTAssertEqual(ProjectXcodeResolutionSource.automaticRequirement(requirement).displayName, ".tool-versions")
    }

    func testDirectoryLocatorFindsProject() throws {
        let fixture = try Fixture()
        XCTAssertEqual(
            ProjectDirectoryLocator.resolve(startingAt: fixture.root),
            .project(fixture.projectURL.standardizedFileURL)
        )
    }

    func testDirectoryLocatorPrefersWorkspace() throws {
        let fixture = try Fixture()
        let workspace = fixture.root.appendingPathComponent("Demo.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        XCTAssertEqual(
            ProjectDirectoryLocator.resolve(startingAt: fixture.root),
            .project(workspace.standardizedFileURL)
        )
    }

    func testDirectoryLocatorFindsAncestorProject() throws {
        let fixture = try Fixture(nestedProject: true)
        let nestedDirectory = fixture.root.appendingPathComponent("Sources/App/Child", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(
            ProjectDirectoryLocator.resolve(startingAt: nestedDirectory),
            .project(fixture.projectURL.standardizedFileURL)
        )
    }

    func testDirectoryLocatorReturnsNoneWithoutProject() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.projectURL)
        XCTAssertEqual(ProjectDirectoryLocator.resolve(startingAt: fixture.root), .none)
    }

    func testDirectoryLocatorRejectsAmbiguousWorkspaces() throws {
        let fixture = try Fixture()
        for name in ["One.xcworkspace", "Two.xcworkspace"] {
            try FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        XCTAssertEqual(
            ProjectDirectoryLocator.resolve(startingAt: fixture.root),
            .ambiguous(directory: fixture.root.path)
        )
    }

    func testProjectEnvironmentExportsExplicitBinding() throws {
        let fixture = try Fixture()
        let installation = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path, xcodeID: installation.id)

        let result = ProjectEnvironmentResolver.resolve(
            for: profile,
            installations: [installation],
            activeInstallationID: nil
        )

        XCTAssertEqual(
            result,
            .output(.exportDeveloperDirectory(installation.developerURL.path))
        )
        if case let .output(output) = result {
            XCTAssertEqual(output.shellSource, "export DEVELOPER_DIR='\(installation.developerURL.path)'")
        }
    }

    func testProjectEnvironmentRestoresForUnboundProject() throws {
        let fixture = try Fixture()
        let installation = fixture.installation(version: "16.4", name: "Xcode.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path)

        let result = ProjectEnvironmentResolver.resolve(
            for: profile,
            installations: [installation],
            activeInstallationID: installation.id
        )

        XCTAssertEqual(result, .output(.restoreOriginal))
        XCTAssertEqual(ProjectEnvironmentOutput.restoreOriginal.shellSource, "unset DEVELOPER_DIR")
    }

    func testProjectEnvironmentEscapesApostropheInPath() throws {
        let fixture = try Fixture()
        let installation = fixture.installation(version: "16.4", name: "Xcode's.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path, xcodeID: installation.id)

        let result = ProjectEnvironmentResolver.resolve(
            for: profile,
            installations: [installation],
            activeInstallationID: nil
        )

        guard case let .output(output) = result else { return XCTFail("Expected environment output") }
        XCTAssertEqual(
            output.shellSource,
            "export DEVELOPER_DIR='\(installation.developerURL.path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        )
    }

    func testZshHookIsIdempotentAndDoesNotChangeGlobalSelection() {
        let source = ZshProjectEnvironmentHook.source
        XCTAssertTrue(source.contains("chpwd_functions"))
        // Registering the hook as a prompt hook would spawn the CLI once per
        // command, while DEVELOPER_DIR only ever depends on PWD.
        XCTAssertFalse(source.contains("precmd_functions"))
        XCTAssertTrue(source.contains("__xcodeswitcher_last_directory"))
        XCTAssertTrue(source.contains("xcodeswitcher env \"$PWD\""))
        XCTAssertTrue(source.contains("__xcodeswitcher_original_developer_dir"))
        XCTAssertTrue(source.contains("__xcodeswitcher_restore_developer_dir"))
        XCTAssertFalse(source.contains("xcode-select"))
    }

    func testLocalConfigurationOverridesVersionFile() throws {
        let fixture = try Fixture()
        try fixture.write("16.4\n", to: ".xcode-version")
        try fixture.write("{\"xcode\":\"15.4\"}\n", to: ".xcode-switcher.json")
        let preferred = fixture.installation(version: "15.4", name: "Xcode-15.4.app")
        let fallback = fixture.installation(version: "16.4", name: "Xcode-16.4.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path)

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [fallback, preferred],
            activeInstallationID: fallback.id,
            localConfiguration: ProjectLocalConfigurationStore.load(for: fixture.projectURL)
        )

        XCTAssertEqual(result, .resolved(installationID: preferred.id, source: .localConfiguration("15.4")))
    }

    func testLocalConfigurationOverridesAppBindingAndAcceptsAppPath() throws {
        let fixture = try Fixture()
        let preferred = fixture.installation(version: "15.4", name: "Preferred.app")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path, xcodeID: "missing")
        try fixture.write("{\"xcode\":\"\(preferred.appURL.path)\"}\n", to: ".xcode-switcher.json")

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [preferred],
            activeInstallationID: nil,
            localConfiguration: ProjectLocalConfigurationStore.load(for: fixture.projectURL)
        )

        XCTAssertEqual(result, .resolved(installationID: preferred.id, source: .localConfiguration(preferred.appURL.path)))
    }

    func testLocalConfigurationStoreLoadsFromAncestor() throws {
        let fixture = try Fixture(nestedProject: true)
        try fixture.write("{\"xcode\":\"16.4\",\"workspace\":\"Demo.xcworkspace\"}\n", to: ".xcode-switcher.json")

        XCTAssertEqual(
            ProjectLocalConfigurationStore.load(for: fixture.projectURL),
            ProjectLocalConfiguration(xcode: "16.4", workspace: "Demo.xcworkspace")
        )
    }

    func testLocalConfigurationSelectsWorkspaceInAmbiguousDirectory() throws {
        let fixture = try Fixture()
        let first = fixture.root.appendingPathComponent("One.xcworkspace", isDirectory: true)
        let second = fixture.root.appendingPathComponent("Two.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try fixture.write("{\"workspace\":\"Two.xcworkspace\"}\n", to: ".xcode-switcher.json")

        XCTAssertEqual(
            ProjectDirectoryLocator.resolve(startingAt: fixture.root),
            .project(second.standardizedFileURL)
        )
    }

    func testInvalidLocalConfigurationIsReported() throws {
        let fixture = try Fixture()
        try fixture.write("{invalid\n", to: ".xcode-switcher.json")
        let profile = ProjectProfile(name: "Demo", path: fixture.projectURL.path)

        let result = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: [],
            activeInstallationID: nil
        )

        XCTAssertEqual(
            result,
            .invalidProjectConfiguration(path: fixture.root.appendingPathComponent(".xcode-switcher.json").path)
        )
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
