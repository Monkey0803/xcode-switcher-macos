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

    func testMapsReleaseErrorsToActionableMessages() {
        XCTAssertEqual(
            UpdateService.userFacingError(URLError(.timedOut)),
            "GitHub Releases 请求超时，请稍后重试。"
        )
        XCTAssertEqual(
            UpdateService.userFacingHTTPError(statusCode: 403),
            "GitHub Releases 请求受到限流，请稍后重试。"
        )
    }

    func testRejectsInvalidReleaseTags() {
        XCTAssertNil(UpdateService.version(from: "release/latest"))
        XCTAssertEqual(UpdateService.version(from: "v1.4.0"), "1.4.0")
    }
}
