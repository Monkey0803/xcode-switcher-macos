import Foundation
import XCTest
@testable import XcodeSwitcher

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
}
