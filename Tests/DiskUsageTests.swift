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

    // MARK: - 删除策略

    /// A remover whose allowlist is one directory inside a fresh scratch tree, so
    /// the delete and trash paths can be driven without touching the real
    /// `~/Library` cleanup targets. Before the scope was injectable this behaviour —
    /// the part of the feature that can destroy data — had no coverage at all.
    ///
    /// Deliberately not `NSTemporaryDirectory()`: that lives under `/var`, which is
    /// a symlink to `/private/var`, and a symlinked ancestor is refused by design —
    /// so a *successful* removal can never be driven from there. The real home has no
    /// symlinked ancestor, so a scratch directory under its `Caches` exercises the
    /// path the way it actually runs.
    private func makeRemovalScope() throws -> (root: String, remover: XcodeCleanupRemover) {
        let home = XcodeCleanupReporter.home
        let root = "\(home)/Library/Caches/xcode-switcher-removal-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return (root, XcodeCleanupRemover(allowedRootTemplates: ["\(root)/cache"], home: home))
    }

    func testRemovalDeletesASafeEntry() throws {
        let (root, remover) = try makeRemovalScope()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = "\(root)/cache"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: URL(fileURLWithPath: "\(target)/file"))

        let entry = XcodeCleanupEntry(path: target, label: "Cache", bytes: 1, safety: .safe, note: "")
        let trashed = try remover.remove(entry)

        XCTAssertNil(trashed, "可自动重建的缓存应直接删除，而不是移入废纸篓")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testRemovalMovesACautionEntryToTheTrash() throws {
        let (root, remover) = try makeRemovalScope()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = "\(root)/cache"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

        let entry = XcodeCleanupEntry(path: target, label: "Archive", bytes: 1, safety: .caution, note: "")
        let trashed = try XCTUnwrap(try remover.remove(entry))

        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "原路径应已不在")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashed.path),
            "谨慎清理项必须仍可在废纸篓中找到，否则「无法自动重建」的提示就是假的"
        )
        try? FileManager.default.removeItem(at: trashed)
    }

    func testRemovalRefusesAPathOutsideTheScopeHome() throws {
        let (root, remover) = try makeRemovalScope()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let entry = XcodeCleanupEntry(
            path: "/tmp/xcode-switcher-not-allowed",
            label: "nope",
            bytes: 1,
            safety: .safe,
            note: ""
        )
        XCTAssertThrowsError(try remover.remove(entry)) { error in
            XCTAssertTrue(error is XcodeCleanupRefusedError)
        }
    }

    func testRemovalRefusesAnAllowedHomeButDisallowedSubpath() throws {
        // The path is inside the scope's home, so only the allowlist can reject it.
        // That branch was unreachable while the allowlist was compiled in.
        let (root, remover) = try makeRemovalScope()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inside = "\(root)/Documents"
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)

        let entry = XcodeCleanupEntry(path: inside, label: "Documents", bytes: 1, safety: .safe, note: "")
        XCTAssertThrowsError(try remover.remove(entry)) { error in
            XCTAssertTrue(error is XcodeCleanupRefusedError)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inside),
            "被拒绝的路径不能被改动"
        )
    }

    func testRemovalRefusesASymlinkedAncestor() throws {
        // An allowlisted path that is a symlink must not redirect the delete.
        let (root, remover) = try makeRemovalScope()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = "\(root)/real-cache"
        let link = "\(root)/cache"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let entry = XcodeCleanupEntry(path: link, label: "Cache", bytes: 1, safety: .safe, note: "")
        XCTAssertThrowsError(try remover.remove(entry)) { error in
            XCTAssertTrue(error is XcodeCleanupRefusedError)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: real),
            "链接指向的目标不能被删除"
        )
    }

    func testStandardPolicyPermitsEveryRootTheReporterOffers() {
        // The offered set and the permitted set come from one table; this fails if
        // that ever stops being the case.
        let templates = XcodeCleanupReporter.allowedRootTemplates
        XCTAssertEqual(templates.count, 13)
        let remover = XcodeCleanupRemover.standard
        for template in templates {
            let root = XcodeCleanupRemover.expand(template, home: XcodeCleanupReporter.home)
            XCTAssertTrue(remover.isAllowed(root), "枚举出的根必须可被删除：\(root)")
            XCTAssertTrue(remover.isAllowed(root + "/child"))
        }
        XCTAssertFalse(remover.isAllowed("/etc"))
        XCTAssertFalse(remover.isAllowed("/tmp"))
    }

    // MARK: - 回收预览的可读化

    private func makeRuntime(
        identifier: String,
        name: String,
        build: String,
        bytes: Int64
    ) -> DiskUsageReporter.SimulatorRuntime {
        DiskUsageReporter.SimulatorRuntime(
            identifier: identifier,
            name: name,
            build: build,
            version: "27.0",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            path: "/x/\(name).simruntime",
            bytes: bytes,
            isDeletable: true,
            state: "Ready",
            lastUsedAt: nil
        )
    }

    func testReclaimPreviewResolvesSimctlUUIDsIntoReadableRows() {
        let runtime = makeRuntime(
            identifier: "C04E2269-5D69-49B7-8BFD-2FECDC949FFA",
            name: "iOS 27.0",
            build: "24A5380i",
            bytes: 8_400_000_000
        )
        // Exactly what simctl prints.
        let output = "Would delete P: C04E2269-5D69-49B7-8BFD-2FECDC949FFA iOS (27.0 - 24A5380i) (Ready)\n"

        let preview = SimulatorRuntimeReclaim.preview(of: output, runtimes: [runtime])

        XCTAssertEqual(preview.lines.count, 1)
        let line = preview.lines[0]
        XCTAssertTrue(line.isResolved)
        XCTAssertEqual(line.label, "iOS 27.0 (24A5380i)")
        XCTAssertEqual(line.summary, "iOS 27.0 (24A5380i) — 8.4 GB")
        XCTAssertEqual(preview.totalBytes, 8_400_000_000)
        XCTAssertEqual(preview.resolvedCount, 1)
        // What the user reads must not be simctl's log line.
        XCTAssertFalse(line.summary.contains("Would delete"))
        XCTAssertFalse(line.summary.contains("C04E2269"))
        XCTAssertFalse(line.summary.contains("P:"))
    }

    func testReclaimPreviewSumsEveryResolvedSize() {
        let first = makeRuntime(
            identifier: "AAAAAAAA-0000-0000-0000-000000000000",
            name: "iOS 27.0",
            build: "24A434",
            bytes: 1_000_000_000
        )
        let second = makeRuntime(
            identifier: "BBBBBBBB-0000-0000-0000-000000000000",
            name: "iOS 26.3",
            build: "23D8133",
            bytes: 2_000_000_000
        )
        let output = """
        Would delete P: AAAAAAAA-0000-0000-0000-000000000000 iOS (27.0 - 24A434) (Ready)
        Would delete P: BBBBBBBB-0000-0000-0000-000000000000 iOS (26.3 - 23D8133) (Ready)
        """

        let preview = SimulatorRuntimeReclaim.preview(of: output, runtimes: [first, second])

        XCTAssertEqual(preview.resolvedCount, 2)
        XCTAssertEqual(preview.totalBytes, 3_000_000_000)
        XCTAssertEqual(preview.lines.map(\.label), ["iOS 27.0 (24A434)", "iOS 26.3 (23D8133)"])
    }

    func testReclaimPreviewKeepsUnresolvableLinesVerbatim() {
        // Dropping a line would understate what is about to be removed.
        let output = """
        Would delete P: 00000000-0000-0000-0000-000000000000 iOS (26.0 - 1A1) (Ready)
        No matching images found to delete
        """

        let preview = SimulatorRuntimeReclaim.preview(of: output, runtimes: [])

        XCTAssertEqual(preview.lines.count, 2)
        XCTAssertEqual(preview.resolvedCount, 0)
        XCTAssertEqual(preview.totalBytes, 0)
        XCTAssertFalse(preview.lines[0].isResolved)
        XCTAssertTrue(preview.lines[0].label.contains("00000000-0000"))
        XCTAssertEqual(preview.lines[1].label, "No matching images found to delete")
    }

    func testReclaimPreviewOfEmptyOutputIsEmpty() {
        XCTAssertTrue(SimulatorRuntimeReclaim.preview(of: "", runtimes: []).isEmpty)
        XCTAssertTrue(SimulatorRuntimeReclaim.preview(of: "\n   \n", runtimes: []).isEmpty)
    }

    func testNothingMatchedIsNotTreatedAsAFailure() {
        // Exactly what `simctl runtime delete --unusable --dry-run` returns when
        // nothing matches: exit 2, marker on stderr. Reporting that as 检查失败 was
        // the bug — a machine used within 30 days legitimately has nothing to reclaim.
        let nothing = ProcessResult(status: 2, stdout: "", stderr: "No matching images found to delete\n")
        XCTAssertTrue(SimulatorRuntimeReclaim.matchedNothing(nothing))

        // A real failure must still be a failure.
        let real = ProcessResult(status: 1, stdout: "", stderr: "Invalid runtime: bogus\n")
        XCTAssertFalse(SimulatorRuntimeReclaim.matchedNothing(real))

        // A successful run is never "nothing matched", even if it printed nothing.
        let ok = ProcessResult(
            status: 0,
            stdout: "Would delete P: AAAAAAAA-0000-0000-0000-000000000000 iOS (27.0 - 24A434) (Ready)\n",
            stderr: ""
        )
        XCTAssertFalse(SimulatorRuntimeReclaim.matchedNothing(ok))
    }

    func testReclaimPreviewTargetsAreTheDeletableSet() {
        // The bulk action deletes from `targets`, so an unresolved line must not end
        // up in it: its identifier is unknown, and its raw text is not one.
        let runtime = makeRuntime(
            identifier: "AAAAAAAA-0000-0000-0000-000000000000",
            name: "iOS 27.0",
            build: "24A434",
            bytes: 1_000_000_000
        )
        let output = """
        Would delete P: AAAAAAAA-0000-0000-0000-000000000000 iOS (27.0 - 24A434) (Ready)
        No matching images found to delete
        """

        let preview = SimulatorRuntimeReclaim.preview(of: output, runtimes: [runtime])

        XCTAssertEqual(preview.lines.count, 2)
        XCTAssertEqual(preview.targets.map(\.identifier), ["AAAAAAAA-0000-0000-0000-000000000000"])
        XCTAssertEqual(preview.targets.map(\.label), ["iOS 27.0 (24A434)"])
    }
}
