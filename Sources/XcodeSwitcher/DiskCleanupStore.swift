import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// Disk cleanup and simulator-runtime reclamation.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. This is one
/// responsibility, and it needs only three things from the model that holds it:
/// somewhere to report a user-visible result, whether an Xcode is running, and a
/// way to have the installations reload the runtime list it shows. They arrive as
/// a protocol and two closures, so this type never reaches back into
/// `XcodeViewModel`.
@MainActor
final class DiskCleanupStore: ObservableObject {
    /// Set by `XcodeViewModel` at construction.
    weak var status: (any StatusReporting)?
    var isAnyXcodeRunning: () -> Bool = { false }
    /// Refreshes the installed-runtime list the detail pane shows. That list lives
    /// with the installations, so the model that owns it does the reloading.
    var reloadInstalledRuntimes: (XcodeInstallation) -> Void = { _ in }

    @Published private(set) var cleanupEntriesByID: [String: [XcodeCleanupEntry]] = [:]
    @Published private(set) var cleanupLoadingIDs: Set<String> = []
    @Published private(set) var cleanupRemovingPaths: Set<String> = []
    @Published private(set) var runtimeSizesByID: [String: [DiskUsageReporter.SimulatorRuntime]] = [:]
    @Published private(set) var runtimeSizesLoadingIDs: Set<String> = []
    @Published private(set) var runtimeReclaimPreview: SimulatorRuntimeReclaimPreview?
    @Published private(set) var isReclaimingRuntimes = false

    /// The reclaim the current preview belongs to, so the bulk action deletes what
    /// was shown rather than re-running the selector.
    private var runtimeReclaimPreviewOption: SimulatorRuntimeReclaim?
    private var cleanupScanGeneration: [String: Int] = [:]
    private var cleanupScanTasks: [String: Task<Void, Never>] = [:]
    private var cleanupCancellations: [String: XcodeCleanupCancellation] = [:]
    private var cleanupSharedEntries: [XcodeCleanupEntry]?
    private var runtimeSizesTasks: [String: Task<Void, Never>] = [:]

    func cleanupEntries(for installation: XcodeInstallation) -> [XcodeCleanupEntry] {
        cleanupEntriesByID[installation.id] ?? []
    }

    func isCleanupLoading(for installation: XcodeInstallation) -> Bool {
        cleanupLoadingIDs.contains(installation.id)
    }

    func isRemovingCleanupEntry(_ entry: XcodeCleanupEntry) -> Bool {
        cleanupRemovingPaths.contains(entry.path)
    }


    func loadCleanupEntries(for installation: XcodeInstallation, force: Bool = false) {
        let id = installation.id

        // A forced rescan takes over from a scan already in flight instead of
        // silently doing nothing. The superseded scan is told to stop — it polls the
        // flag between measurements — and its generation is superseded, so it can
        // neither publish a stale list nor clear the loading flag that now belongs
        // to the new scan.
        if let cancellation = cleanupCancellations[id] {
            guard force else { return }
            cancellation.cancel()
            cleanupCancellations[id] = nil
            cleanupScanTasks[id]?.cancel()
            cleanupScanTasks[id] = nil
            cleanupLoadingIDs.remove(id)
        }

        guard force || cleanupEntriesByID[id] == nil else { return }
        if !force, let cleanupSharedEntries {
            cleanupEntriesByID[id] = cleanupSharedEntries
            return
        }

        let generation = (cleanupScanGeneration[id] ?? 0) + 1
        cleanupScanGeneration[id] = generation
        let cancellation = XcodeCleanupCancellation()
        cleanupCancellations[id] = cancellation
        cleanupLoadingIDs.insert(id)
        cleanupScanTasks[id] = Task.detached(priority: .utility) { [weak self] in
            let entries = XcodeCleanupReporter.entries(isCancelled: { cancellation.isCancelled })
            await self?.completeCleanupLoad(for: id, generation: generation, entries: entries)
        }
    }

    /// `installation` is deliberately absent: the scan covers every Xcode, so the
    /// operation is global even though it is triggered from one installation's view.
    func removeCleanupEntry(_ entry: XcodeCleanupEntry) {
        // The button is disabled while Xcode runs, but a disabled button is not a
        // guard — it is a rendering of state sampled at the last body evaluation.
        // Removing DerivedData under a live build is the hazard this feature exists
        // to avoid, so re-check at the moment of action.
        guard !isAnyXcodeRunning() else {
            status?.isError = true
            status?.statusMessage = String(localized: "检测到 Xcode 正在运行。请退出所有 Xcode 后再清理。")
            return
        }
        guard !cleanupRemovingPaths.contains(entry.path) else { return }
        cleanupRemovingPaths.insert(entry.path)
        Task { [weak self] in
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try XcodeCleanupReporter.remove(entry)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            cleanupRemovingPaths.remove(entry.path)
            if let errorMessage {
                status?.isError = true
                status?.statusMessage = String(localized: "清理失败：\(errorMessage)")
            } else {
                cleanupSharedEntries?.removeAll { $0.id == entry.id }
                for id in Array(cleanupEntriesByID.keys) {
                    cleanupEntriesByID[id]?.removeAll { $0.id == entry.id }
                }
                status?.isError = false
                switch entry.safety {
                case .safe:
                    status?.statusMessage = String(localized: "已清理 \(entry.label)。")
                case .caution:
                    status?.statusMessage = String(localized: "已移到废纸篓：\(entry.label)。")
                }
            }
        }
    }

    private func completeCleanupLoad(for id: String, generation: Int, entries: [XcodeCleanupEntry]) {
        // A superseded scan returns here without touching `cleanupLoadingIDs`: the
        // newer scan owns that flag and clears it on its own completion, so the
        // installation cannot be left spinning forever.
        guard cleanupScanGeneration[id] == generation else { return }
        cleanupScanTasks[id] = nil
        cleanupCancellations[id] = nil
        cleanupLoadingIDs.remove(id)
        // `entries()` is shared across every Xcode, so a fresh scan replaces the
        // cached list for each installation that already holds one. Refreshing
        // only `id` would leave the others showing directories that are gone.
        cleanupSharedEntries = entries
        for key in Array(cleanupEntriesByID.keys) { cleanupEntriesByID[key] = entries }
        cleanupEntriesByID[id] = entries
    }

    // MARK: - Simulator runtime reclamation

    func runtimeSizes(for installation: XcodeInstallation) -> [DiskUsageReporter.SimulatorRuntime] {
        runtimeSizesByID[installation.id] ?? []
    }

    func isLoadingRuntimeSizes(for installation: XcodeInstallation) -> Bool {
        runtimeSizesLoadingIDs.contains(installation.id)
    }

    /// `simctl runtime list -j` reports each image's size, so this is a single fast
    /// process rather than a traversal.
    func loadRuntimeSizes(for installation: XcodeInstallation, force: Bool = false) {
        let id = installation.id
        if runtimeSizesTasks[id] != nil {
            guard force else { return }
            runtimeSizesTasks[id]?.cancel()
            runtimeSizesTasks[id] = nil
            runtimeSizesLoadingIDs.remove(id)
        }
        guard force || runtimeSizesByID[id] == nil else { return }
        runtimeSizesLoadingIDs.insert(id)
        runtimeSizesTasks[id] = Task.detached(priority: .utility) { [weak self] in
            let runtimes = XcodeTooling.simulatorRuntimeSizes(for: installation)
            await self?.completeRuntimeSizesLoad(for: id, runtimes: runtimes)
        }
    }

    private func completeRuntimeSizesLoad(for id: String, runtimes: [DiskUsageReporter.SimulatorRuntime]) {
        runtimeSizesTasks[id] = nil
        runtimeSizesLoadingIDs.remove(id)
        runtimeSizesByID[id] = runtimes
    }

    func deleteRuntime(_ runtime: DiskUsageReporter.SimulatorRuntime, for installation: XcodeInstallation) {
        guard runtime.isDeletable, !isReclaimingRuntimes else { return }
        isReclaimingRuntimes = true
        status?.isError = false
        status?.statusMessage = String(localized: "正在删除 Runtime \(runtime.label)…")
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) { () -> RuntimeRemovalReport in
                let outcome = XcodeTooling.deleteSimulatorRuntimes([runtime.identifier], installation: installation)
                return RuntimeRemovalReport(
                    removed: outcome.succeeded.isEmpty ? [] : [runtime.label],
                    alreadyGone: outcome.alreadyGone.isEmpty ? [] : [runtime.label],
                    failed: outcome.failures.map { "\(runtime.label) — \($0.reason)" }
                )
            }.value
            self?.completeRuntimeRemoval(report, installation: installation)
        }
    }

    /// Runs simctl's own `--dry-run` and surfaces its output, so the preview is what
    /// simctl reports rather than a locally derived guess about which seeds qualify.
    func previewRuntimeReclaim(_ reclaim: SimulatorRuntimeReclaim, for installation: XcodeInstallation) {
        guard !isReclaimingRuntimes else { return }
        isReclaimingRuntimes = true
        status?.isError = false
        runtimeReclaimPreview = nil
        status?.statusMessage = String(localized: "正在检查\(reclaim.title)的 Runtime…")
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                // simctl decides which images qualify; the listing is read alongside
                // it only so its UUIDs can be shown as the versions and sizes the
                // runtime list already displays.
                let runtimes = XcodeTooling.simulatorRuntimeSizes(for: installation)
                let outcome = XcodeTooling.reclaimSimulatorRuntimes(
                    reclaim,
                    installation: installation,
                    dryRun: true
                )
                return (outcome, runtimes)
            }.value
            guard let self else { return }
            isReclaimingRuntimes = false
            if result.0.succeeded {
                runtimeReclaimPreview = SimulatorRuntimeReclaim.preview(of: result.0.stdout, runtimes: result.1)
                runtimeReclaimPreviewOption = reclaim
                status?.statusMessage = String(localized: "检查完成。")
            } else if SimulatorRuntimeReclaim.matchedNothing(result.0) {
                // Nothing matches. That is information, not a failure: a machine used
                // within 30 days legitimately has nothing "30 天未使用", and reporting
                // that as 检查失败 was wrong.
                runtimeReclaimPreview = SimulatorRuntimeReclaimPreview(lines: [])
                runtimeReclaimPreviewOption = reclaim
                status?.isError = false
                status?.statusMessage = String(localized: "没有需要清理的 Runtime。")
            } else {
                status?.isError = true
                status?.statusMessage = String(localized: "检查失败：\(result.0.failureDescription)")
            }
        }
    }

    func reclaimRuntimes(_ reclaim: SimulatorRuntimeReclaim, for installation: XcodeInstallation) {
        guard !isReclaimingRuntimes else { return }
        isReclaimingRuntimes = true
        status?.isError = false
        // Resolved on the main actor before the work starts, so the deletion set is
        // exactly what the preview showed.
        let previewed = previewedTargets(for: reclaim)
        status?.statusMessage = String(localized: "正在清理\(reclaim.title)的 Runtime…")
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) { () -> RuntimeRemovalReport in
                var targets = previewed
                if targets.isEmpty {
                    // 清理 without a preview first: resolve the set now, so the action
                    // still deletes precisely what a preview would have listed.
                    let runtimes = XcodeTooling.simulatorRuntimeSizes(for: installation)
                    let dryRun = XcodeTooling.reclaimSimulatorRuntimes(
                        reclaim,
                        installation: installation,
                        dryRun: true
                    )
                    guard dryRun.succeeded || SimulatorRuntimeReclaim.matchedNothing(dryRun) else {
                        return RuntimeRemovalReport(
                            removed: [],
                            alreadyGone: [],
                            failed: [dryRun.failureDescription]
                        )
                    }
                    targets = SimulatorRuntimeReclaim.preview(of: dryRun.stdout, runtimes: runtimes).targets
                }
                guard !targets.isEmpty else {
                    return RuntimeRemovalReport(removed: [], alreadyGone: [], failed: [])
                }

                // One `simctl` call per identifier: it accepts exactly one, and a
                // selector deleted only a single image per click.
                let outcome = XcodeTooling.deleteSimulatorRuntimes(
                    targets.map(\.identifier),
                    installation: installation
                )
                let labels = Dictionary(
                    targets.map { ($0.identifier, $0.label) },
                    uniquingKeysWith: { first, _ in first }
                )
                return RuntimeRemovalReport(
                    removed: outcome.succeeded.compactMap { labels[$0] },
                    alreadyGone: outcome.alreadyGone.compactMap { labels[$0] ?? $0 },
                    failed: outcome.failures.map { failure in
                        "\(labels[failure.identifier] ?? failure.identifier) — \(failure.reason)"
                    }
                )
            }.value
            self?.completeRuntimeRemoval(report, installation: installation)
        }
    }

    /// What the current preview would delete, when it belongs to this option.
    private func previewedTargets(for reclaim: SimulatorRuntimeReclaim) -> [SimulatorRuntimeReclaimPreview.Target] {
        guard runtimeReclaimPreviewOption == reclaim, let runtimeReclaimPreview else { return [] }
        return runtimeReclaimPreview.targets
    }

    /// What a bulk removal actually did, by label, so the result can name the
    /// runtimes instead of reporting the selector that was clicked.
    private struct RuntimeRemovalReport: Sendable {
        let removed: [String]
        /// Labels whose image no longer exists. Not a failure: there was nothing
        /// left to delete, which is the usual reason a row looked clickable.
        let alreadyGone: [String]
        /// One `label — simctl 的原话` entry per failure. The reason is kept so the
        /// status line can say *why* a runtime was not removed; naming it alone is
        /// what left 「清理失败：iOS 27.0 (24A5380i)」 unanswerable.
        let failed: [String]
    }

    private func completeRuntimeRemoval(_ report: RuntimeRemovalReport, installation: XcodeInstallation) {
        isReclaimingRuntimes = false
        runtimeReclaimPreview = nil
        runtimeReclaimPreviewOption = nil
        if !report.failed.isEmpty {
            status?.isError = true
            status?.statusMessage = String(localized: "清理失败：\(report.failed.joined(separator: "、"))")
        } else if !report.removed.isEmpty, !report.alreadyGone.isEmpty {
            status?.isError = false
            status?.statusMessage = String(
                localized: "已清理 \(report.removed.count) 个 Runtime：\(report.removed.joined(separator: "、"))；另有 \(report.alreadyGone.count) 个已经不存在。"
            )
        } else if !report.removed.isEmpty {
            status?.isError = false
            status?.statusMessage = String(
                localized: "已清理 \(report.removed.count) 个 Runtime：\(report.removed.joined(separator: "、"))。"
            )
        } else if !report.alreadyGone.isEmpty {
            status?.isError = false
            status?.statusMessage = String(
                localized: "\(report.alreadyGone.joined(separator: "、")) 已经不存在，列表已刷新。"
            )
        } else {
            status?.isError = false
            status?.statusMessage = String(localized: "没有需要清理的 Runtime。")
        }
        // Both the measured sizes and the installed-runtime list have changed.
        loadRuntimeSizes(for: installation, force: true)
        reloadInstalledRuntimes(installation)
    }

    /// Tasks are cancelled here rather than from the model's `deinit`, which is
    /// nonisolated and so cannot call into this actor.
    deinit {
        cleanupScanTasks.values.forEach { $0.cancel() }
        runtimeSizesTasks.values.forEach { $0.cancel() }
    }
}
