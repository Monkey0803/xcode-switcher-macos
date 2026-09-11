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

        #expect(XcodeSettingsError.cannotLaunch.errorDescription?.contains("无法打开") == true)
        #expect(XcodeSettingsError.accessibilityPermissionMissing.errorDescription?.contains("辅助功能") == true)
        #expect(XcodeSettingsError.settingsItemNotFound.errorDescription?.contains("手动") == true)
        // The underlying automation error must survive into the message.
        #expect(XcodeSettingsError.automationFailed("boom").errorDescription?.contains("boom") == true)
    }
}
