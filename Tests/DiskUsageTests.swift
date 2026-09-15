import Darwin
import Foundation
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

    func testCleanupRemovalNeverAcceptsPathsOutsideUserHome() {
        let entry = XcodeCleanupEntry(path: "/tmp/not-an-xcode-cache", label: "test", bytes: 1, safety: .safe, note: "")
        XCTAssertThrowsError(try XcodeCleanupReporter.remove(entry)) { error in
            XCTAssertTrue(error is XcodeCleanupRefusedError)
        }
    }

    /// The security-relevant branch: the path *is* under the home directory, so
    /// only the allowlist can reject it. The guard runs before any filesystem
    /// change, so this never touches the real `~/Documents`.
    func testCleanupRemovalRejectsInHomePathOutsideAllowlist() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let entry = XcodeCleanupEntry(
            path: "\(home)/Documents/not-an-xcode-cache",
            label: "test",
            bytes: 1,
            safety: .safe,
            note: ""
        )
        XCTAssertThrowsError(try XcodeCleanupReporter.remove(entry)) { error in
            XCTAssertTrue(error is XcodeCleanupRefusedError)
        }
    }

    /// A refused path must not surface as "you do not have permission", which is
    /// what the UI would have shown for every rejection before.
    func testCleanupRemovalDoesNotReportRefusalAsPermissionFailure() {
        let entry = XcodeCleanupEntry(path: "/tmp/not-an-xcode-cache", label: "test", bytes: 1, safety: .safe, note: "")
        XCTAssertThrowsError(try XcodeCleanupReporter.remove(entry)) { error in
            XCTAssertFalse(error is CocoaError, "A refused path masqueraded as a permission error")
        }
    }

    func testSymlinkGuardFlagsALinkedAncestorOnly() throws {
        // NSTemporaryDirectory lives under /var, itself a symlink to /private/var,
        // and Foundation's resolvingSymlinksInPath() deliberately leaves /var alone
        // — so the control path would look symlinked too. realpath(3) does resolve
        // it, which is what makes the negative case meaningful.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let basePath = realpath(NSTemporaryDirectory(), &buffer).map { String(cString: $0) }
            ?? NSTemporaryDirectory()
        let base = URL(fileURLWithPath: basePath)
            .appendingPathComponent("xcode-switcher-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertFalse(
            XcodeCleanupReporter.containsSymlinkComponent(real.appendingPathComponent("cache").path),
            "The control path has no symlinked component"
        )
        XCTAssertTrue(
            XcodeCleanupReporter.containsSymlinkComponent(link.appendingPathComponent("cache").path),
            "A symlinked ancestor must be detected, or an allowlisted path could redirect the delete"
        )
    }

    func testCleanupEntryUsesPathAsStableIdentity() {
        let entry = XcodeCleanupEntry(path: "/tmp/cache", label: "Cache", bytes: 1024, safety: .safe, note: "")
        XCTAssertEqual(entry.id, entry.path)
        XCTAssertEqual(entry.displaySize, "1 KB")
    }

    func testParsesRuntimeDeletabilityAndLastUse() throws {
        let json = """
        {
          "AAAA-UUID" : {
            "build" : "24A5380i",
            "deletable" : true,
            "identifier" : "AAAA-UUID",
            "lastUsedAt" : "2026-07-02T06:23:08Z",
            "runtimeBundlePath" : "/x/iOS 27.0.simruntime",
            "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "sizeBytes" : 8000000000,
            "state" : "Ready",
            "version" : "27.0"
          },
          "BBBB-UUID" : {
            "build" : "23D8133",
            "runtimeBundlePath" : "/y/iOS 26.3.simruntime",
            "sizeBytes" : 100
          }
        }
        """

        let runtimes = DiskUsageReporter.parseSimulatorRuntimes(json)
        XCTAssertEqual(runtimes.count, 2)

        let ready = try XCTUnwrap(runtimes.first { $0.identifier == "AAAA-UUID" })
        XCTAssertEqual(ready.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(ready.version, "27.0")
        XCTAssertEqual(ready.state, "Ready")
        XCTAssertTrue(ready.isDeletable)
        XCTAssertEqual(
            ready.lastUsedAt,
            ISO8601DateFormatter().date(from: "2026-07-02T06:23:08Z")
        )

        // This entry declares neither `identifier` (so it falls back to the JSON key)
        // nor `deletable` — and an absent `deletable` must read as "no", not "yes".
        let bare = try XCTUnwrap(runtimes.first { $0.identifier == "BBBB-UUID" })
        XCTAssertFalse(bare.isDeletable)
        XCTAssertNil(bare.lastUsedAt)
    }

    func testRuntimeReclaimSelectorsMatchSimctlInterface() {
        // These are passed straight to `simctl runtime delete`; a typo would silently
        // make the command match nothing instead of failing loudly.
        XCTAssertEqual(SimulatorRuntimeReclaim.outdated.selectorArguments, ["--outdated"])
        XCTAssertEqual(SimulatorRuntimeReclaim.unusable.selectorArguments, ["--unusable"])
        XCTAssertEqual(
            SimulatorRuntimeReclaim.unused.selectorArguments,
            ["--notUsedSinceDays", "\(SimulatorRuntimeReclaim.unusedDays)"]
        )
        XCTAssertEqual(SimulatorRuntimeReclaim.unusedDays, 30)
    }

    func testCleanupCancellationIsOneShot() {
        let cancellation = XcodeCleanupCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testCancelledScanMeasuresNothing() {
        // A superseded rescan must stop rather than merely discard its result, which
        // is only true if the scan honours the flag before measuring anything.
        XCTAssertTrue(XcodeCleanupReporter.entries(isCancelled: { true }).isEmpty)
    }
}
