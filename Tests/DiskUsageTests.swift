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

    func testParsesSimctlRuntimesAndTheirSizes() {
        // Trimmed from real `xcrun simctl runtime list -j` output: a dictionary
        // keyed by identifier, with the bundle path and size already reported.
        let json = """
        {
          "0B798FD4-7B92-4EEA-A59B-518484D74016" : {
            "build" : "24A434",
            "identifier" : "0B798FD4-7B92-4EEA-A59B-518484D74016",
            "runtimeBundlePath" : "/private/var/run/mnt/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime",
            "sizeBytes" : 8067000161,
            "state" : "Ready",
            "version" : "27.0"
          },
          "67B1C06F-8026-4A01-AD48-418107262BA9" : {
            "build" : "23D8133",
            "identifier" : "67B1C06F-8026-4A01-AD48-418107262BA9",
            "runtimeBundlePath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.3.simruntime",
            "sizeBytes" : 1234567890,
            "version" : "26.3"
          }
        }
        """

        let runtimes = DiskUsageReporter.parseSimulatorRuntimes(json)
        XCTAssertEqual(runtimes.map(\.name), ["iOS 26.3", "iOS 27.0"])
        XCTAssertEqual(runtimes.map(\.build), ["23D8133", "24A434"])
        // Two seeds of one version must stay distinguishable.
        XCTAssertEqual(runtimes.map(\.label), ["iOS 26.3 (23D8133)", "iOS 27.0 (24A434)"])
        XCTAssertEqual(runtimes.first?.bytes, 1234567890)
        XCTAssertEqual(DiskUsageFormatter.humanReadable(bytes: runtimes.last?.bytes ?? 0), "8.1 GB")
    }

    func testSkipsSimctlEntriesWithoutAPathOrSize() {
        let json = """
        { "A" : { "runtimeBundlePath" : "/x/iOS 27.0.simruntime" },
          "B" : { "sizeBytes" : 100 } }
        """
        XCTAssertTrue(DiskUsageReporter.parseSimulatorRuntimes(json).isEmpty)
        XCTAssertTrue(DiskUsageReporter.parseSimulatorRuntimes("not json").isEmpty)
    }

    func testRejectsUnparsableDuOutput() {
        XCTAssertNil(DiskUsageReporter.parseDuOutput(""))
        XCTAssertNil(DiskUsageReporter.parseDuOutput("du: cannot access '/nope'\n"))
    }
}
