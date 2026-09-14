import XCTest
@testable import XcodeSwitcher

final class DiskUsageTests: XCTestCase {
    func testFormatsEveryUnit() {
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 0), "0 B")
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 999), "999 B")
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 1_500), "2 KB")
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 12_400_000), "12 MB")
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 12_400_000_000), "12.4 GB")
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: 2_000_000_000_000), "2.0 TB")
    }

    func testNegativeValuesDoNotProduceNegativeSizes() {
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: -1), "0 B")
    }

    func testParsesDuOutput() {
        XCTAssertEqual(
            DiskUsageReporter.parseDuOutput("12345\t/Applications/Xcode.app\n"),
            DiskUsageFormatter.bytes(fromDuKilobytes: 12345)
        )
        // Trailing noise on later lines must not change the answer.
        XCTAssertEqual(
            DiskUsageReporter.parseDuOutput("7\t/tmp/a\n7\t/tmp/a/b\n"),
            DiskUsageFormatter.bytes(fromDuKilobytes: 7)
        )
    }

    func testRejectsUnparsableDuOutput() {
        XCTAssertNil(DiskUsageReporter.parseDuOutput(""))
        XCTAssertNil(DiskUsageReporter.parseDuOutput("du: cannot access '/nope'\n"))
    }
}
