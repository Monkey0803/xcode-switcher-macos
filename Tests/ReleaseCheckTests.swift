import XCTest
@testable import XcodeSwitcher

final class ReleaseCheckTests: XCTestCase {
    func testComparesReleaseVersions() {
        XCTAssertTrue(UpdateService.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertTrue(UpdateService.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(UpdateService.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(UpdateService.isNewer(nil, than: "1.2.0"))
    }

    func testBuildsUserAgentFromCurrentVersion() {
        XCTAssertEqual(UpdateService.userAgent(for: "1.1.1"), "XcodeSwitcher/1.1.1")
    }
}
