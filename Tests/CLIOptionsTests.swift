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
}
