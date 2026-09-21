import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

final class EnvironmentDoctorTests: XCTestCase {
    func testReportCountsWarningsAndErrors() {
        let report = EnvironmentReport(
            installationID: "/Applications/Xcode.app",
            installationName: "Xcode",
            version: "16.4",
            generatedAt: Date(timeIntervalSince1970: 0),
            checks: [
                check(id: "healthy", severity: .healthy),
                check(id: "info", severity: .informational),
                check(id: "warning", severity: .warning),
                check(id: "error", severity: .error),
            ]
        )

        XCTAssertEqual(report.issueCount, 2)
        XCTAssertEqual(report.highestSeverity, .error)
    }

    func testRenderedReportIncludesRemediationAndStableSeverityLabels() {
        let remediation = "下载 iOS Runtime。"
        let report = EnvironmentReport(
            installationID: "/Applications/Xcode.app",
            installationName: "Xcode",
            version: "16.4",
            generatedAt: Date(timeIntervalSince1970: 0),
            checks: [
                EnvironmentCheck(
                    id: "runtime",
                    title: "Simulator Runtime",
                    detail: "未检测到可用 Runtime。",
                    severity: .warning,
                    remediation: remediation
                ),
            ]
        )

        let text = EnvironmentDoctor.render(report)
        // Assert through the same localization lookup the report uses, so the
        // expectation holds whichever language the test process runs in.
        XCTAssertTrue(text.contains("[" + String(localized: "警告") + "] Simulator Runtime"))
        XCTAssertTrue(text.contains(String(localized: "问题数：\(1)")))
        // `render` localizes the prefix and interpolates the remediation, so the
        // expectation has to use the same shape to hit the same key.
        XCTAssertTrue(text.contains(String(localized: "建议：\(remediation)")))
    }

    func testLegacyConfigurationUsesSecondStageDefaults() throws {
        let legacy = """
        {
          "customSearchPaths": [],
          "favoriteIDs": [],
          "xcodeAliases": {},
          "projects": [],
          "globalShortcutEnabled": true,
          "globalShortcut": { "keyCode": 7, "modifierFlags": 1835008 }
        }
        """

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(legacy.utf8))

        XCTAssertFalse(configuration.launchAtLoginEnabled)
        XCTAssertFalse(configuration.menuBarOnly)
        XCTAssertTrue(configuration.automaticallyChecksForUpdates)
    }

    private func check(id: String, severity: EnvironmentCheckSeverity) -> EnvironmentCheck {
        EnvironmentCheck(
            id: id,
            title: id,
            detail: id,
            severity: severity,
            remediation: nil
        )
    }

    func testRedactedReportHidesHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let report = EnvironmentReport(
            installationID: "\(home)/Applications/Xcode.app",
            installationName: "Xcode",
            version: "16.4",
            generatedAt: Date(timeIntervalSince1970: 0),
            checks: [EnvironmentCheck(
                id: "path",
                title: "路径",
                detail: "\(home)/Applications/Xcode.app/Contents/Developer",
                severity: .healthy,
                remediation: "检查 \(home)/Library"
            )]
        )

        let output = EnvironmentDoctor.render(report, redacted: true)
        XCTAssertFalse(output.contains(home))
        XCTAssertTrue(output.contains("~/Applications/Xcode.app"))
        XCTAssertTrue(output.contains("~/Library"))
    }

    // MARK: - 终端与第三方工具链

    func testParsesXcodebuildVersionOutput() {
        XCTAssertEqual(EnvironmentDoctor.parseXcodeVersion("Xcode 26.3\nBuild version 17C529\n"), "26.3 (17C529)")
        XCTAssertEqual(EnvironmentDoctor.parseXcodeVersion("Xcode 16.0"), "16.0", "没有构建号时只报版本")
        XCTAssertNil(EnvironmentDoctor.parseXcodeVersion("command not found"))
    }

    func testParsesCocoaPodsToolchainFromRealOutput() {
        // 真实 `pod env` 输出的节选，字段前的空白是对齐用的。
        let output = """
        ### Stack

        ```
           CocoaPods : 1.17.0
                Ruby : ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM [arm64-darwin25]
                Host : macOS 27.0 (26A428)
               Xcode : 26.3 (17C529)
                 Git : git version 2.50.1 (Apple Git-155)
        ```
        """

        XCTAssertEqual(EnvironmentDoctor.parseCocoaPodsToolchain(output), "26.3 (17C529)")
        XCTAssertNil(EnvironmentDoctor.parseCocoaPodsToolchain("### Stack\n\n```\n```"), "没有 Xcode 行时不猜")
        // CLT 环境下 CocoaPods 会打出空的括号：那等于「没找到 Xcode」，不是一个可比的版本。
        XCTAssertNil(EnvironmentDoctor.parseCocoaPodsToolchain("### Stack\n\n```\n       Xcode :  ()\n```"))
    }

    func testTerminalCheckIsHealthyWhenTheShellAgrees() {
        let check = EnvironmentDoctor.terminalToolchainCheck(
            resolved: "26.3 (17C529)",
            persistentDeveloperDir: "",
            installation: makeInstallation()
        )

        XCTAssertEqual(check.severity, .healthy)
        XCTAssertNil(check.remediation)
    }

    func testTerminalCheckWarnsWhenTheShellUsesAnotherXcode() {
        let check = EnvironmentDoctor.terminalToolchainCheck(
            resolved: "26.2 (17C520)",
            persistentDeveloperDir: "",
            installation: makeInstallation()
        )

        XCTAssertEqual(check.severity, .warning, "终端用的不是体检这台时必须说出来")
        XCTAssertTrue(check.detail.contains("26.2"))
        XCTAssertNotNil(check.remediation)
    }

    func testTerminalCheckFlagsAPersistentDeveloperDir() {
        let stale = EnvironmentDoctor.terminalToolchainCheck(
            resolved: nil,
            persistentDeveloperDir: "/Applications/Xcode_gone.app/Contents/Developer",
            installation: makeInstallation()
        )
        XCTAssertEqual(stale.severity, .error, "指向不存在的路径比版本不一致更严重")
        XCTAssertEqual(stale.id, "terminal-toolchain")

        // 需要一个「存在但不是体检这台」的路径：临时目录最稳妥。
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcode-switcher-developer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let elsewhere = EnvironmentDoctor.terminalToolchainCheck(
            resolved: "26.3 (17C529)",
            persistentDeveloperDir: root.path,
            installation: makeInstallation()
        )
        XCTAssertEqual(elsewhere.severity, .warning, "全局 DEVELOPER_DIR 指向另一台时即便本次一致也要提醒")
        // 用与实现相同的本地化查找来断言整句，这样中英文环境下都成立——CI runner 是英文环境，
        // 直接找中文字串会在那里失败（本项目既有的 render 测试也是这个写法）。
        XCTAssertEqual(
            elsewhere.detail,
            String(localized: "终端里的 DEVELOPER_DIR 指向另一个 Xcode：\(root.path)"),
            "要说清是「指向另一个」而不是「路径不存在」"
        )
    }

    func testThirdPartyCheckComparesWithTheInspectedXcode() {
        let probe = EnvironmentDoctor.ToolchainProbe(
            id: "cocoa",
            title: "CocoaPods",
            executableNames: ["pod"],
            arguments: ["env"],
            parse: { _ in nil }
        )

        XCTAssertEqual(
            EnvironmentDoctor.thirdPartyToolchainCheck(
                probe: probe, reported: "26.3 (17C529)", installation: makeInstallation()
            ).severity,
            .healthy
        )
        XCTAssertEqual(
            EnvironmentDoctor.thirdPartyToolchainCheck(
                probe: probe, reported: "26.2 (17C520)", installation: makeInstallation()
            ).severity,
            .warning
        )
        let unreadable = EnvironmentDoctor.thirdPartyToolchainCheck(
            probe: probe, reported: nil, installation: makeInstallation()
        )
        XCTAssertEqual(unreadable.severity, .informational, "读不出工具链不等于出错")
        XCTAssertEqual(unreadable.id, "toolchain-cocoa")
    }

    func testToolProbesOnlyCoverToolsThatReportAToolchain() {
        // 只有会报出自己 Xcode 的工具才在表里：其余工具的版本号说明不了工具链。
        XCTAssertEqual(EnvironmentDoctor.toolchainProbes.map(\.id), ["cocoapods"])
    }

    private func makeInstallation() -> XcodeInstallation {
        XcodeInstallation(
            appURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            version: "26.3",
            build: "17C529"
        )
    }
}
