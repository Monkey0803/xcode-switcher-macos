import Foundation
import Testing
@testable import XcodeSwitcher

/// These strings are copied to the pasteboard and pasted into a shell, so a
/// quoting mistake would hand the user a broken (or unsafe) command.
@Suite("免授权 DEVELOPER_DIR 命令")
struct DeveloperDirectoryCommandTests {
    private func installation(at path: String) -> XcodeInstallation {
        XcodeInstallation(appURL: URL(fileURLWithPath: path), version: "16.4", build: "16F6")
    }

    @Test("export 命令引用普通路径")
    func exportCommandQuotesPlainPath() {
        let value = XcodeViewModel.developerDirectoryExport(for: installation(at: "/Applications/Xcode 16.4.app"))
        #expect(value == "export DEVELOPER_DIR='/Applications/Xcode 16.4.app/Contents/Developer'")
    }

    @Test("export 命令处理含单引号的路径")
    func exportCommandQuotesApostrophePath() {
        let value = XcodeViewModel.developerDirectoryExport(for: installation(at: "/Applications/Xcode's.app"))
        #expect(value == "export DEVELOPER_DIR='/Applications/Xcode'\"'\"'s.app/Contents/Developer'")
    }

    @Test("Shell 集成命令是可直接粘贴的 eval 行，且不修改全局设置")
    func shellIntegrationCommandIsPasteable() {
        let command = XcodeViewModel.shellIntegrationCommand
        #expect(command == #"eval "$(xcodeswitcher shell-init zsh)""#)
        #expect(!command.contains("xcode-select --switch"))
    }

    @Test("CLI 链接命令指向 App 包内的可执行文件")
    func cliLinkCommandTargetsBundledCLI() {
        let command = XcodeViewModel.cliLinkCommand
        #expect(command.hasPrefix("mkdir -p ~/.local/bin && ln -sf \""))
        #expect(command.contains("Contents/MacOS/xcodeswitcher"))
        #expect(command.hasSuffix("\" ~/.local/bin/xcodeswitcher"))
    }
}
