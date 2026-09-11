import AppKit
import Testing
@testable import XcodeSwitcher

/// The Settings-window automation is an AppleScript string that is otherwise only
/// exercised on a user's machine, where a syntax error looks like "nothing
/// happened". Compiling it here validates the script without running it.
@Suite("Xcode Settings 自动化脚本")
struct XcodeSettingsAutomationTests {
    private func compiles(_ source: String) -> (compiled: Bool, error: NSDictionary?) {
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        return (compiled, error)
    }

    @Test("生成的脚本语法正确")
    func scriptCompiles() {
        let result = compiles(XcodeActions.xcodeSettingsScript(processName: "Xcode"))
        #expect(result.compiled, "AppleScript 编译失败：\(String(describing: result.error))")
    }

    @Test("含引号与反斜杠的 Xcode 名称也能生成合法脚本")
    func scriptCompilesForQuotedProcessName() {
        let result = compiles(XcodeActions.xcodeSettingsScript(processName: "Xcode\"s \\ 16.4"))
        #expect(result.compiled, "AppleScript 编译失败：\(String(describing: result.error))")
    }

    @Test("每种失败都给出可操作的中文说明")
    func failuresHaveActionableDescriptions() throws {
        let cases: [XcodeSettingsError] = [
            .cannotLaunch,
            .accessibilityPermissionMissing,
            .settingsItemNotFound,
            .automationFailed("boom")
        ]
        for error in cases {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }

        // Compare against the same localization lookups the errors use, so these
        // expectations hold whichever language the test process runs in.
        #expect(XcodeSettingsError.cannotLaunch.errorDescription == String(localized: "无法打开该 Xcode。"))
        #expect(
            XcodeSettingsError.accessibilityPermissionMissing.errorDescription
                == String(localized: "需要辅助功能权限才能自动打开 Xcode 的 Settings 窗口，请在系统设置中授权后重试。")
        )
        #expect(
            XcodeSettingsError.settingsItemNotFound.errorDescription
                == String(localized: "没有在 Xcode 菜单中找到 Settings 项，请在 Xcode 中手动打开。")
        )
        // The underlying automation error must survive into the message.
        #expect(XcodeSettingsError.automationFailed("boom").errorDescription?.contains("boom") == true)
    }
}
