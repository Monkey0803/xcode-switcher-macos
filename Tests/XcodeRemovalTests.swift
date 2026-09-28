import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

final class XcodeRemovalTests: XCTestCase {
    /// A fake bundle in a real, symlink-free tree.
    ///
    /// Deliberately not `NSTemporaryDirectory()`: that lives under `/var`, which is a
    /// symlink to `/private/var`, and this policy refuses a path that is not its own
    /// resolution. A *successful* removal can therefore never be driven from there —
    /// the same reason `DiskUsageTests.makeRemovalScope` puts its scratch tree under
    /// the real home.
    private func makeFixture() throws -> (root: String, installation: XcodeInstallation) {
        let root = "\(XcodeCleanupReporter.home)/Library/Caches/xcode-switcher-removal-tests-\(UUID().uuidString)"
        let appURL = URL(fileURLWithPath: root).appendingPathComponent("Xcode 26.3.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/Developer", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (root, XcodeInstallation(appURL: appURL, version: "26.3", build: "17C529"))
    }

    private func context(
        _ installation: XcodeInstallation,
        known: [XcodeInstallation]? = nil,
        active: String? = nil,
        running: Bool = false,
        bound: [XcodeRemovalBinding] = [],
        force: Bool = false
    ) -> XcodeRemovalContext {
        XcodeRemovalContext(
            knownInstallations: known ?? [installation],
            activeDeveloperPath: active,
            isRunning: running,
            boundProjects: bound,
            force: force
        )
    }

    // MARK: - 判定

    func testAllowsRemovalWhenNothingHoldsTheBundleBack() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            XcodeRemoval.decide(installation, in: context(installation, active: "/Applications/Other.app/Contents/Developer")),
            .allowed
        )
    }

    func testRefusesAPathThatIsNotADiscoveredInstallation() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Nothing below this check is trustworthy: the path could be a stale row, or
        // something that was never validated as an Xcode at all.
        XCTAssertEqual(
            XcodeRemoval.decide(installation, in: context(installation, known: [])),
            .refused(.notADiscoveredInstallation)
        )
    }

    func testRefusesTheActiveDeveloperDirectory() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Also bound and running, to pin the order: the remedy for "it is the system
        // default" is the one worth showing.
        let decision = XcodeRemoval.decide(
            installation,
            in: context(installation, active: installation.developerURL.path, running: true, bound: [XcodeRemovalBinding(projectName: "Demo", origin: .appProfile)])
        )
        XCTAssertEqual(decision, .refused(.activeDeveloperDirectory))
    }

    func testRefusesAProjectThatPinsTheVersion() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let bindings = [
            XcodeRemovalBinding(projectName: "Demo", origin: .appProfile),
            XcodeRemovalBinding(projectName: "Tools", origin: .localConfiguration("/repo/Tools/.xcode-switcher.json"))
        ]
        let decision = XcodeRemoval.decide(installation, in: context(installation, bound: bindings))
        XCTAssertEqual(decision, .refused(.boundProjects(bindings)))

        // Force relaxes the running check only: silently rewriting a binding the user
        // made is not something a flag should be able to do.
        let forced = XcodeRemoval.decide(
            installation,
            in: context(installation, bound: [bindings[0]], force: true)
        )
        XCTAssertEqual(forced, .refused(.boundProjects([bindings[0]])))
        let message = XcodeRemovalRefusal.boundProjects(bindings).message
        XCTAssertTrue(message.contains("Demo"))
        // 两个来源指的路不同，所以消息要分别说出来。前者必须和消息用同一次查找：
        // 直写中文在英文 runner 上会失败（AGENTS.md 记过的那个坑，2026-09-28 又踩了一次）。
        XCTAssertTrue(message.contains(String(localized: "App 内绑定")))
        XCTAssertTrue(message.contains("/repo/Tools/.xcode-switcher.json"))
    }

    func testRefusesARunningXcodeUnlessForced() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            XcodeRemoval.decide(installation, in: context(installation, running: true)),
            .refused(.running)
        )
        XCTAssertTrue(XcodeRemovalRefusal.running.isOverridableByForce)
        XCTAssertEqual(
            XcodeRemoval.decide(installation, in: context(installation, running: true, force: true)),
            .allowed
        )
    }

    func testRefusesAPathThatIsASymbolicLink() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let link = URL(fileURLWithPath: root).appendingPathComponent("Xcode-beta.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installation.appURL)
        let linked = XcodeInstallation(appURL: link, version: "26.3", build: "17C529")

        // Trashing the link would free nothing and leave the real bundle in place,
        // which is the opposite of what the button promises.
        XCTAssertEqual(
            XcodeRemoval.decide(linked, in: context(linked)),
            .refused(.symbolicLinkComponent)
        )
    }

    func testEveryRefusalExplainsItself() throws {
        let refusals: [XcodeRemovalRefusal] = [
            .notADiscoveredInstallation,
            .symbolicLinkComponent,
            .activeDeveloperDirectory,
            .boundProjects([XcodeRemovalBinding(projectName: "Demo", origin: .appProfile)]),
            .running,
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal) 必须给出理由")
        }
    }

    // MARK: - 执行

    func testARefusalTouchesNothing() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertThrowsError(try XcodeRemoval.remove(installation, in: context(installation, running: true))) { error in
            XCTAssertEqual(error as? XcodeRemovalRefusedError, XcodeRemovalRefusedError(refusal: .running))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installation.appURL.path),
            "被拒绝时不能动文件"
        )
    }

    func testRemovalMovesTheBundleToTheTrash() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outcome = try XcodeRemoval.remove(installation, in: context(installation))
        guard case let .trashed(trashed) = outcome else {
            return XCTFail("应报告已移入废纸篓，实际 \(outcome)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installation.appURL.path),
            "原路径应已不在"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashed.path),
            "必须能在废纸篓中找到，否则「需要时可以恢复」就是假的"
        )
        try? FileManager.default.removeItem(at: trashed)
    }

    func testABundleThatIsAlreadyGoneIsNotAFailure() throws {
        let (root, installation) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.removeItem(atPath: installation.appURL.path)

        XCTAssertEqual(try XcodeRemoval.remove(installation, in: context(installation)), .alreadyGone)
    }

    // MARK: - 配置

    func testForgettingAnInstallationDropsOnlyItsOwnReferences() {
        var configuration = AppConfiguration()
        configuration.favoriteIDs = ["/A/Xcode.app", "/B/Xcode.app"]
        configuration.xcodeAliases = ["/A/Xcode.app": "stable", "/B/Xcode.app": "beta"]
        configuration.activationHistory = ["/B/Xcode.app", "/A/Xcode.app"]
        configuration.notifiedXcodeUpdateKeys = ["/A/Xcode.app|17C529", "/B/Xcode.app|17C530"]
        configuration.projects = [
            ProjectProfile(name: "Demo", path: "/tmp/Demo.xcodeproj", xcodeID: "/A/Xcode.app")
        ]

        configuration.forgetInstallation(id: "/A/Xcode.app")

        XCTAssertEqual(configuration.favoriteIDs, ["/B/Xcode.app"])
        XCTAssertEqual(configuration.xcodeAliases, ["/B/Xcode.app": "beta"])
        XCTAssertEqual(configuration.activationHistory, ["/B/Xcode.app"])
        XCTAssertEqual(configuration.notifiedXcodeUpdateKeys, ["/B/Xcode.app|17C530"])
        // A removal is refused while a project pins the version, so the binding is
        // never silently rewritten — someone who forces a removal by hand still gets
        // the automatic matching they had before they pinned anything.
        XCTAssertEqual(configuration.projects.first?.xcodeID, "/A/Xcode.app")
    }
}
