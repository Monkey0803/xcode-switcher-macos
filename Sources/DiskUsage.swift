import Foundation

/// Human-readable byte sizes. Pure, so the formatting is covered on every machine
/// even though the numbers it prints come from the filesystem.
enum DiskUsageFormatter {
    /// `du -k` reports kibibytes; the rest of the app talks in bytes.
    static func bytes(fromDuKilobytes kilobytes: Int64) -> Int64 {
        kilobytes * 1024
    }

    /// One decimal for gigabytes and up, none below, so the CLI columns stay
    /// readable without pulling in a locale-dependent formatter.
    static func humanReadable(bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let units: [(threshold: Double, divisor: Double, suffix: String, decimals: Int)] = [
            (1_000_000_000_000, 1_000_000_000_000, "TB", 1),
            (1_000_000_000, 1_000_000_000, "GB", 1),
            (1_000_000, 1_000_000, "MB", 0),
            (1_000, 1_000, "KB", 0),
        ]
        for unit in units where value >= unit.threshold {
            return String(format: "%.\(unit.decimals)f %@", value / unit.divisor, unit.suffix)
        }
        return String(format: "%.0f B", value)
    }
}

/// Measures how much disk an Xcode installation or a simulator runtime occupies.
///
/// `du` rather than a `FileManager` walk: an Xcode bundle holds hundreds of
/// thousands of files, and enumeration there takes far longer than a single
/// process. Its output is parsed by a pure function, so the parsing is tested
/// without touching the filesystem.
enum DiskUsageReporter {
    struct Entry: Equatable, Sendable {
        let label: String
        let path: String
        let bytes: Int64
    }

    /// `du -sk <path>` prints one line: "<kibibytes>\t<path>".
    static func parseDuOutput(_ output: String) -> Int64? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first,
              let kilobytes = Int64(firstLine.split(whereSeparator: \.isWhitespace).first ?? "")
        else { return nil }
        return DiskUsageFormatter.bytes(fromDuKilobytes: kilobytes)
    }

    static func allocatedBytes(ofPath path: String) -> Int64? {
        guard let output = ProcessRunner.output(executable: "/usr/bin/du", arguments: ["-sk", path]) else {
            return nil
        }
        return parseDuOutput(output)
    }

    /// A simulator runtime as `simctl` reports it.
    struct SimulatorRuntime: Equatable, Sendable {
        /// The UUID `simctl runtime delete` takes. The dictionary key and the
        /// `identifier` field agree, but only the field is guaranteed to be a string
        /// so the key is the fallback.
        let identifier: String
        let name: String
        /// Several seeds of the same version can be installed side by side, so the
        /// version alone does not identify an image — the build does.
        let build: String
        let version: String
        /// Groups seeds of the same platform+version, e.g. `…SimRuntime.iOS-27-0`.
        let runtimeIdentifier: String
        let path: String
        let bytes: Int64
        /// Defaults to `false`: when simctl does not say a runtime is deletable, the
        /// safe reading is that it is not.
        let isDeletable: Bool
        let state: String
        /// Absent for some seeds, which is not the same as "never used".
        let lastUsedAt: Date?

        var label: String { build.isEmpty ? name : "\(name) (\(build))" }
    }

    /// `xcrun simctl runtime list -j` is a dictionary keyed by runtime identifier.
    /// It reports the bundle path *and* the size, which matters on current Xcode:
    /// newer runtimes are cryptex images mounted under
    /// `/Library/Developer/CoreSimulator/Volumes`, not directories inside
    /// `~/Library/Developer/CoreSimulator/Profiles/Runtimes`, so scanning that
    /// folder finds nothing at all.
    static func parseSimulatorRuntimes(_ json: String) -> [SimulatorRuntime] {
        struct Entry: Decodable {
            let runtimeBundlePath: String?
            let sizeBytes: Int64?
            let build: String?
            let identifier: String?
            let version: String?
            let runtimeIdentifier: String?
            let deletable: Bool?
            let state: String?
            let lastUsedAt: String?
        }
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [] }
        let formatter = ISO8601DateFormatter()
        return entries.compactMap { key, entry -> SimulatorRuntime? in
            guard let path = entry.runtimeBundlePath, let bytes = entry.sizeBytes else { return nil }
            let name = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".simruntime", with: "")
            return SimulatorRuntime(
                identifier: entry.identifier ?? key,
                name: name,
                build: entry.build ?? "",
                version: entry.version ?? "",
                runtimeIdentifier: entry.runtimeIdentifier ?? "",
                path: path,
                bytes: bytes,
                isDeletable: entry.deletable ?? false,
                state: entry.state ?? "",
                lastUsedAt: entry.lastUsedAt.flatMap(formatter.date(from:))
            )
        }
        .sorted { $0.label < $1.label }
    }

    static func simulatorRuntimes() -> [SimulatorRuntime] {
        guard let output = ProcessRunner.output(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "runtime", "list", "-j"]
        ) else { return [] }
        return parseSimulatorRuntimes(output)
    }
}

/// The bulk reclaim operations `simctl runtime delete` accepts.
///
/// Which images qualify is left entirely to `simctl`, on purpose. Its `--outdated`
/// keeps the newest build of each runtime identifier, and a locally reimplemented
/// rule would eventually disagree with it about which seed is newer — on this
/// machine five iOS 27.0 seeds are installed and simctl judges four of them
/// outdated, keeping `24A5380i`. Deriving that here would be a second, worse
/// implementation of Apple's build ordering, so the preview runs simctl's own
/// `--dry-run` and shows its output verbatim.
enum SimulatorRuntimeReclaim: String, CaseIterable, Identifiable, Sendable {
    case outdated
    case unused
    case unusable

    var id: Self { self }

    /// Days without use before `simctl` treats a runtime as reclaimable.
    static let unusedDays = 30

    var title: String {
        switch self {
        case .outdated: return String(localized: "已过时")
        case .unused: return String(localized: "30 天未使用")
        case .unusable: return String(localized: "不可用")
        }
    }

    var note: String {
        switch self {
        case .outdated: return String(localized: "同一 Runtime 已有更新的构建，只保留最新的一个。")
        case .unused: return String(localized: "最近 30 天没有使用过。")
        case .unusable: return String(localized: "已被标记为不可用。")
        }
    }

    /// Arguments following `simctl runtime delete`, before an optional `--dry-run`.
    var selectorArguments: [String] {
        switch self {
        case .outdated: return ["--outdated"]
        case .unused: return ["--notUsedSinceDays", "\(Self.unusedDays)"]
        case .unusable: return ["--unusable"]
        }
    }
}

enum XcodeCleanupSafety: Int, CaseIterable, Identifiable, Sendable {
    case safe
    case caution

    var id: Self { self }

    /// Names the risk rather than the flow: every entry is confirmed before it is
    /// removed, so neither label may read as "this one is not confirmed".
    var title: String {
        switch self {
        case .safe: return String(localized: "可安全清理")
        case .caution: return String(localized: "需谨慎清理")
        }
    }
}

struct XcodeCleanupEntry: Identifiable, Equatable, Sendable {
    let path: String
    let label: String
    let bytes: Int64
    let safety: XcodeCleanupSafety
    let note: String

    var id: String { path }
    var displaySize: String { DiskUsageFormatter.humanReadable(bytes: bytes) }
}

/// Raised when removal is asked for a path outside the home directory, outside
/// the allowlist, or behind a symlinked component. Kept distinct from a real
/// filesystem permission failure so the UI can name the rule that refused it
/// instead of claiming the user lacks permission.
struct XcodeCleanupRefusedError: LocalizedError {
    let path: String

    var errorDescription: String? {
        String(localized: "拒绝清理不在允许列表中的路径：\(path)")
    }
}

/// Lets a caller stop a scan that is already running.
///
/// The scan measures on `DispatchQueue.concurrentPerform`, where `Task.isCancelled`
/// cannot be observed, so cancellation is an explicit flag the scan polls between
/// measurements. One-shot by design: a scan is never un-cancelled.
final class XcodeCleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Collects measurements from concurrent `du` runs without racing on a shared array.
private final class XcodeCleanupCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [XcodeCleanupEntry] = []

    func add(_ measured: [XcodeCleanupEntry]) {
        guard !measured.isEmpty else { return }
        lock.lock()
        entries += measured
        lock.unlock()
    }

    var collected: [XcodeCleanupEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Finds only known, user-level Xcode data directories. Xcode application
/// bundles and signing data are deliberately excluded from this list.
enum XcodeCleanupReporter {
    /// One directory the cleanup feature knows how to remove.
    ///
    /// `roots` below is the single source of truth: `entries()` offers exactly
    /// these paths and `isKnownCleanupPath` permits exactly these paths, so the
    /// set the UI shows and the set removal accepts cannot drift apart.
    private struct Root: Sendable {
        let template: String
        let label: String
        let safety: XcodeCleanupSafety
        let note: String
        /// Archives and DeviceSupport hold one removable directory per entry;
        /// every other root is removed whole.
        let expandsChildren: Bool

        init(
            _ template: String,
            _ label: String,
            _ safety: XcodeCleanupSafety,
            _ note: String,
            expandsChildren: Bool = false
        ) {
            self.template = template
            self.label = label
            self.safety = safety
            self.note = note
            self.expandsChildren = expandsChildren
        }
    }

    private static let roots: [Root] = [
        Root("~/Library/Developer/Xcode/DerivedData", "DerivedData", .safe,
             String(localized: "编译中间产物，Xcode 会自动重建。")),
        Root("~/Library/Developer/Xcode/Products", "Products", .safe,
             String(localized: "构建产物，删除后会重新生成。")),
        Root("~/Library/Developer/Xcode/DeviceLogs", "DeviceLogs", .safe,
             String(localized: "真机调试日志。")),
        Root("~/Library/Developer/Xcode/DocumentationCache", "DocumentationCache", .safe,
             String(localized: "文档缓存，删除后会重新下载。")),
        Root("~/Library/Developer/Xcode/DocumentationIndex", "DocumentationIndex", .safe,
             String(localized: "文档索引，删除后会重新建立。")),
        Root("~/Library/Developer/CoreSimulator/Caches", "CoreSimulator/Caches", .safe,
             String(localized: "Simulator 缓存。")),
        Root("~/Library/Developer/DVTDownloads/Assets", "DVTDownloads/Assets", .safe,
             String(localized: "未完成的开发者资源下载。")),
        Root("~/Library/Developer/Packages", "Developer/Packages", .caution,
             String(localized: "Swift/Xcode 包缓存，删除后会重新下载。")),
        Root("~/Library/Caches/com.apple.dt.Xcode", "Xcode 缓存", .safe,
             String(localized: "Xcode 用户缓存。")),
        Root("~/Library/Caches/com.apple.dt.xcodebuild", "xcodebuild 缓存", .safe,
             String(localized: "命令行构建缓存。")),
        Root("~/Library/Caches/org.swift.swiftpm", "SwiftPM 缓存", .caution,
             String(localized: "Swift Package Manager 缓存。")),
        Root("~/Library/Developer/Xcode/Archives", "Archive", .caution,
             String(localized: "删除后无法从 Xcode Organizer 恢复归档。"), expandsChildren: true),
        Root("~/Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", .caution,
             String(localized: "连接对应系统的真机调试时会重新准备。"), expandsChildren: true),
    ]

    /// Standardized once and reused by both the home-prefix check and the
    /// allowlist, so the two checks can never compare against different strings.
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Expands only a *leading* `~`. A `~` anywhere else is a literal character,
    /// which `replacingOccurrences` would have rewritten.
    private static func expand(_ template: String) -> String {
        guard template.hasPrefix("~/") else { return template }
        return home + "/" + String(template.dropFirst(2))
    }

    /// Measures every root concurrently.
    ///
    /// Each root costs at least one `du` process, so a sequential pass makes the
    /// caller wait for the sum of all of them; the CLI's `sizes` command already
    /// measures Xcode bundles in parallel for the same reason.
    ///
    /// `isCancelled` is polled between measurements so a superseded scan stops
    /// instead of measuring every remaining directory. It is an explicit signal
    /// rather than `Task.isCancelled` because this runs on
    /// `DispatchQueue.concurrentPerform`, where the current task is not observable —
    /// and because it keeps the scan callable from the synchronous CLI.
    static func entries(isCancelled: @Sendable () -> Bool = { false }) -> [XcodeCleanupEntry] {
        // A box class rather than a captured local: a `@Sendable` closure may not
        // mutate captured state, which is the same reason the CLI's `sizes` command
        // collects its concurrent `du` results this way.
        let collector = XcodeCleanupCollector()
        let roots = Self.roots

        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            guard !isCancelled() else { return }
            collector.add(measure(roots[index], isCancelled: isCancelled))
        }

        return collector.collected.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func measure(
        _ root: Root,
        isCancelled: @Sendable () -> Bool
    ) -> [XcodeCleanupEntry] {
        let path = expand(root.template)
        if root.expandsChildren {
            return childEntries(
                at: path,
                label: root.label,
                safety: root.safety,
                note: root.note,
                isCancelled: isCancelled
            )
        }
        guard FileManager.default.fileExists(atPath: path),
              let bytes = DiskUsageReporter.allocatedBytes(ofPath: path) else { return [] }
        return [
            XcodeCleanupEntry(path: path, label: root.label, bytes: bytes, safety: root.safety, note: root.note)
        ]
    }

    private static func childEntries(
        at path: String,
        label: String,
        safety: XcodeCleanupSafety,
        note: String,
        isCancelled: @Sendable () -> Bool
    ) -> [XcodeCleanupEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var result: [XcodeCleanupEntry] = []
        for child in children {
            // Finder's own metadata is not a cleanup target, and offering a
            // `.DS_Store` next to a 13 GB DeviceSupport folder is just noise.
            guard !child.hasPrefix(".") else { continue }
            // Archives and DeviceSupport can each hold many entries and every one
            // costs its own `du`, so this is where cancellation has to be observed
            // for it to mean anything.
            if isCancelled() { break }
            let childPath = (path as NSString).appendingPathComponent(child)
            guard let bytes = DiskUsageReporter.allocatedBytes(ofPath: childPath) else { continue }
            result.append(
                XcodeCleanupEntry(path: childPath, label: "\(label)/\(child)", bytes: bytes, safety: safety, note: note)
            )
        }
        return result
    }

    /// Removes one entry, refusing anything outside the home directory, outside the
    /// allowlist, or behind a symlinked path component.
    ///
    /// `.safe` entries are caches Xcode rebuilds on demand, so they are deleted
    /// outright — trashing them would only move the space elsewhere. `.caution`
    /// entries are things Xcode cannot regenerate by itself: an archive, the device
    /// support for an OS, a package cache. Those go to the Trash so the user can
    /// still recover them, which is what the Archive note promises.
    static func remove(_ entry: XcodeCleanupEntry) throws {
        let target = URL(fileURLWithPath: entry.path).standardizedFileURL.path
        guard target.hasPrefix(home + "/"), isKnownCleanupPath(target), !containsSymlinkComponent(target) else {
            throw XcodeCleanupRefusedError(path: target)
        }
        switch entry.safety {
        case .safe:
            try FileManager.default.removeItem(atPath: target)
        case .caution:
            try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
        }
    }

    /// Derived from the same `roots` table `entries()` reads, so what the UI
    /// offers and what removal accepts cannot disagree.
    private static func isKnownCleanupPath(_ target: String) -> Bool {
        roots.map { expand($0.template) }.contains { target == $0 || target.hasPrefix($0 + "/") }
    }

    /// `standardizedFileURL` collapses `..` but does **not** resolve symlinks, so
    /// a symlinked ancestor would otherwise let an allowlisted path redirect the
    /// delete somewhere else. Every component is checked, leaf included.
    static func containsSymlinkComponent(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                return true
            }
        }
        return false
    }
}
