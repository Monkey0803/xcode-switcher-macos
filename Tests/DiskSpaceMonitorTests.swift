import XCTest
@testable import XcodeSwitcherKit

final class DiskSpaceMonitorTests: XCTestCase {
    func testNormalizesThresholdIntoSupportedRange() {
        XCTAssertEqual(DiskSpaceMonitor.normalizedThresholdGB(-1), DiskSpaceMonitor.minimumThresholdGB)
        XCTAssertEqual(DiskSpaceMonitor.normalizedThresholdGB(20), 20)
        XCTAssertEqual(DiskSpaceMonitor.normalizedThresholdGB(999), DiskSpaceMonitor.maximumThresholdGB)
    }

    func testWarningTriggersOnlyBelowConfiguredCapacity() {
        XCTAssertTrue(DiskSpaceMonitor.isBelowWarningThreshold(availableBytes: 19_999_999_999, thresholdGB: 20))
        XCTAssertFalse(DiskSpaceMonitor.isBelowWarningThreshold(availableBytes: 20_000_000_000, thresholdGB: 20))
        XCTAssertFalse(DiskSpaceMonitor.isBelowWarningThreshold(availableBytes: -1, thresholdGB: 20))
    }
}
