import XCTest
@testable import XcodeSwitcher

final class CLIOptionsTests: XCTestCase {
    func testParsesOutputAndExecutionFlagsInAnyPosition() throws {
        let options = try CLIOptions.parse(["--json", "use", "--dry-run", "16.4"])
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(options.command, "use")
        XCTAssertEqual(options.values, ["16.4"])
        XCTAssertFalse(options.force)
    }

    func testDefaultsToHumanOutputAndNoDryRun() throws {
        let options = try CLIOptions.parse(["list"])
        XCTAssertFalse(options.json)
        XCTAssertFalse(options.dryRun)
        XCTAssertEqual(options.command, "list")
    }

    func testParsesForceFlag() throws {
        let options = try CLIOptions.parse(["use", "--force", "16.4"])
        XCTAssertTrue(options.force)
        XCTAssertFalse(options.dryRun)
        XCTAssertEqual(options.command, "use")
        XCTAssertEqual(options.values, ["16.4"])
    }

    func testAllFlagIsOffUnlessRequested() throws {
        // `clean` uses --all to opt into the entries Xcode cannot rebuild, so the
        // default has to stay conservative.
        let plain = try CLIOptions.parse(["clean"])
        XCTAssertFalse(plain.all)
        XCTAssertFalse(plain.force)
        XCTAssertEqual(plain.command, "clean")

        let all = try CLIOptions.parse(["clean", "--force", "--all"])
        XCTAssertTrue(all.all)
        XCTAssertTrue(all.force)
        XCTAssertEqual(all.values, [])
    }

    func testParsesEnvironmentCommands() throws {
        let env = try CLIOptions.parse(["--json", "env", "/tmp/App.xcodeproj"])
        XCTAssertEqual(env.command, "env")
        XCTAssertEqual(env.values, ["/tmp/App.xcodeproj"])

        let shellInit = try CLIOptions.parse(["shell-init", "zsh"])
        XCTAssertEqual(shellInit.command, "shell-init")
        XCTAssertEqual(shellInit.values, ["zsh"])
    }

    func testSubcommandListIsUniqueAndComplete() throws {
        let all = CLISubcommands.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all).count, all.count, "重复的子命令会让补全脚本出现重复项")
        // `clean` was added to the dispatcher and the help text but missed by all
        // three completion scripts, which each kept their own copy of this list.
        for command in ["clean", "sizes", "completions", "workspace"] {
            XCTAssertTrue(all.contains(command), "补全脚本缺少子命令：\(command)")
        }
        // Guards against a command being dropped from completions by accident.
        XCTAssertEqual(all.count, 18, "子命令数量变了；请同时确认帮助文本与补全脚本")
    }

    func testErrorOutputIsCodableForMachineClients() throws {
        let data = try JSONEncoder().encode(CLIErrorOutput(code: "failed", message: "测试错误"))
        let decoded = try JSONDecoder().decode(CLIErrorOutput.self, from: data)
        XCTAssertEqual(decoded, CLIErrorOutput(code: "failed", message: "测试错误"))
    }
}
