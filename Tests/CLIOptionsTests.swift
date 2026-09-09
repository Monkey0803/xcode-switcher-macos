import XCTest
@testable import XcodeSwitcher

final class CLIOptionsTests: XCTestCase {
    func testParsesOutputAndExecutionFlagsInAnyPosition() throws {
        let options = try CLIOptions.parse(["--json", "use", "--dry-run", "16.4"])
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(options.command, "use")
        XCTAssertEqual(options.values, ["16.4"])
    }

    func testDefaultsToHumanOutputAndNoDryRun() throws {
        let options = try CLIOptions.parse(["list"])
        XCTAssertFalse(options.json)
        XCTAssertFalse(options.dryRun)
        XCTAssertEqual(options.command, "list")
    }

    func testParsesEnvironmentCommands() throws {
        let env = try CLIOptions.parse(["--json", "env", "/tmp/App.xcodeproj"])
        XCTAssertEqual(env.command, "env")
        XCTAssertEqual(env.values, ["/tmp/App.xcodeproj"])

        let shellInit = try CLIOptions.parse(["shell-init", "zsh"])
        XCTAssertEqual(shellInit.command, "shell-init")
        XCTAssertEqual(shellInit.values, ["zsh"])
    }
}
