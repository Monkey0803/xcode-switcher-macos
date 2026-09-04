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
                    remediation: "下载 iOS Runtime。"
                ),
            ]
        )

        let text = EnvironmentDoctor.render(report)
        XCTAssertTrue(text.contains("[警告] Simulator Runtime"))
        XCTAssertTrue(text.contains("问题数：1"))
        XCTAssertTrue(text.contains("建议：下载 iOS Runtime。"))
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
}
