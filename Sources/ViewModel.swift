import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenRequest: Identifiable {
    let profile: ProjectProfile
    let currentInstallation: XcodeInstallation
    let recommendedInstallation: XcodeInstallation
    let source: ProjectXcodeResolutionSource

    var id: UUID { profile.id }
}

/// Runtime download progress changes on every line of `xcodebuild` output, so it
/// lives in its own observable object instead of republishing the whole view
/// model and invalidating every view that reads it.
@MainActor
final class RuntimeDownloadState: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress = ""

    func begin(_ message: String) {
        isDownloading = true
        progress = message
    }

    func update(_ message: String) {
        progress = message
    }

    func finish(_ message: String) {
        isDownloading = false
        progress = message
    }
}

@MainActor
final class XcodeViewModel: ObservableObject {
    @Published private(set) var installations: [XcodeInstallation] = []
    @Published var selectedID: String?
    @Published private(set) var activeDeveloperPath: String?
    @Published private(set) var commandLineToolsPath = String(localized: "检测中…")
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var loadingDetailsIDs: Set<String> = []
    @Published private(set) var environmentReportsByID: [String: EnvironmentReport] = [:]
    @Published private(set) var environmentDoctorRunningIDs: Set<String> = []
    @Published private(set) var isGlobalShortcutAvailable = true
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var detailsByID: [String: XcodeDetails] = [:]
    @Published private(set) var runtimesByID: [String: [SimulatorRuntime]] = [:]
    @Published private(set) var devicesByID: [String: [SimulatorDevice]] = [:]
    @Published private(set) var signingCertificates: [SigningCertificate] = []
    @Published private(set) var provisioningProfiles: [ProvisioningProfile] = []
    @Published private(set) var signingReport: ProjectSigningReport?
    @Published private(set) var isRefreshingSigning = false
    @Published private(set) var isLoadingSigningReport = false
    @Published private(set) var isCheckingRelease = false
    @Published private(set) var releaseCheckMessage = ""
    @Published private(set) var cleanupEntriesByID: [String: [XcodeCleanupEntry]] = [:]
    @Published private(set) var cleanupLoadingIDs: Set<String> = []
    @Published private(set) var cleanupRemovingPaths: Set<String> = []
    @Published private(set) var runtimeSizesByID: [String: [DiskUsageReporter.SimulatorRuntime]] = [:]
    @Published private(set) var runtimeSizesLoadingIDs: Set<String> = []
    @Published private(set) var runtimeReclaimPreview: SimulatorRuntimeReclaimPreview?
    /// Which option the preview above belongs to, so 清理 deletes exactly that set.
    private var runtimeReclaimPreviewOption: SimulatorRuntimeReclaim?
    @Published private(set) var releaseCatalog: [XcodeReleaseInfo] = []
    @Published private(set) var releaseCatalogState: ReleaseCatalogState = .idle
    @Published private(set) var installDetailsByID: [String: XcodeInstallDetails] = [:]

    @Published private(set) var isReclaimingRuntimes = false
    @Published var configuration: AppConfiguration
    @Published var pendingProjectOpen: ProjectOpenRequest?
    @Published var statusMessage = String(localized: "正在扫描本机安装的 Xcode…")
    @Published var isError = false
    @Published private(set) var configurationSaveError: String?
    @Published var filter = ""
    @Published private(set) var searchFocusRequest = 0

    /// Deliberately not `@Published`: only the runtime section observes it, so
    /// download progress does not republish the whole view model.
    let runtimeDownload = RuntimeDownloadState()

    private let store: AppConfigurationStore
    private let releaseCatalogStore: XcodeReleaseCatalogStore
    private var refreshTask: Task<Void, Never>?
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var runtimeDownloadTask: Task<Void, Never>?
    private var signingReportTask: Task<Void, Never>?
    private var environmentDoctorTasks: [String: Task<Void, Never>] = [:]
    private var cleanupScanGeneration: [String: Int] = [:]
    private var cleanupScanTasks: [String: Task<Void, Never>] = [:]
    private var cleanupCancellations: [String: XcodeCleanupCancellation] = [:]
    private var cleanupSharedEntries: [XcodeCleanupEntry]?
    private var runtimeSizesTasks: [String: Task<Void, Never>] = [:]
    private var releaseCatalogTask: Task<Void, Never>?

    /// How the release-index fetch is going, so the panel can tell "not fetched yet"
    /// from "network unreachable" from "showing a stale copy".
    enum ReleaseCatalogState: Equatable, Sendable {
        case idle
        case loading
        case loaded(cachedAt: Date?, refreshFailed: Bool)
        case unavailable(String)
    }

    /// Resolving a project reads `.xcode-switcher.json`, `.xcode-version` and
    /// `.tool-versions` from disk. View bodies and the status menu ask for the
    /// result on every render, so it is cached and only re-read when the inputs
    /// change or the short lifetime expires. Actions that change system state
    /// resolve fresh instead of trusting the cache.
    private struct ProjectSnapshot {
        let resolution: ProjectXcodeResolution
        let match: ProjectXcodeMatch?
        let isProjectPresent: Bool
        let computedAt: Date
    }

    private static let projectSnapshotLifetime: TimeInterval = 3
    private var projectSnapshots: [UUID: ProjectSnapshot] = [:]
    private var pendingProjectUpdate: (profile: ProjectProfile, name: String, xcodeID: String?)?
    private var projectUpdateTask: Task<Void, Never>?
    /// `NSWorkspace.icon(forFile:)` goes through LaunchServices, so the result is
    /// cached instead of being re-fetched on every row render.
    private var iconCache: [String: NSImage] = [:]
    private var lastRefreshAt: Date?

    /// Invoked when the folders that should be watched for Xcode installations
    /// change, so the app can re-arm its directory monitors.
    var onSearchPathsChanged: (() -> Void)?

    init(
        store: AppConfigurationStore = .shared,
        releaseCatalogStore: XcodeReleaseCatalogStore = .live,
        configuresSystemServices: Bool = true
    ) {
        self.store = store
        self.releaseCatalogStore = releaseCatalogStore
        configuration = store.load()
        isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
        // Tests construct the model to exercise caching and persistence without
        // registering global event monitors or touching the updater.
        guard configuresSystemServices else { return }
        GlobalShortcutService.shared.onPressed = { [weak self] in
            Task { @MainActor in self?.showMainWindow(focusSearch: true) }
        }
        if configuration.globalShortcutEnabled {
            isGlobalShortcutAvailable = GlobalShortcutService.shared.start(using: configuration.globalShortcut)
        }
        UpdateService.shared.setAutomaticallyChecksForUpdates(configuration.automaticallyChecksForUpdates)
    }

    deinit {
        refreshTask?.cancel()
        detailTasks.values.forEach { $0.cancel() }
        runtimeDownloadTask?.cancel()
        signingReportTask?.cancel()
        environmentDoctorTasks.values.forEach { $0.cancel() }
        projectUpdateTask?.cancel()
    }

    var selectedInstallation: XcodeInstallation? {
        installations.first { $0.id == selectedID }
    }

    var activeInstallation: XcodeInstallation? {
        installations.first { $0.developerURL.path == activeDeveloperPath }
    }

    func isActive(_ installation: XcodeInstallation) -> Bool {
        installation.developerURL.path == activeDeveloperPath
    }

    var filteredInstallations: [XcodeInstallation] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return installations }
        return installations.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.displayVersion.localizedCaseInsensitiveContains(query) ||
            $0.appURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh(silently: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if !silently { statusMessage = String(localized: "正在扫描本机安装的 Xcode…") }
        let searchPaths = configuration.customSearchPaths
        refreshTask?.cancel()
        refreshTask = Task {
            let discovery = await Task.detached(priority: .userInitiated) {
                (
                    XcodeLocator.discover(searchPaths: searchPaths),
                    XcodeLocator.activeDeveloperPath(),
                    XcodeLocator.commandLineToolsPath()
                )
            }.value
            guard !Task.isCancelled else { return }
            installations = discovery.0
            activeDeveloperPath = discovery.1
            commandLineToolsPath = discovery.2
            invalidateProjectSnapshots()
            iconCache.removeAll()
            lastRefreshAt = Date()
            if !installations.contains(where: { $0.id == selectedID }) {
                selectedID = installations.first(where: { $0.developerURL.path == activeDeveloperPath })?.id ?? installations.first?.id
            }
            isRefreshing = false
            isError = installations.isEmpty
            if !silently || installations.isEmpty {
                statusMessage = installations.isEmpty ? String(localized: "未发现 Xcode.app。") : String(localized: "已发现 \(installations.count) 个 Xcode。")
            }
            if let selectedInstallation {
                loadDetails(for: selectedInstallation)
                loadCleanupEntries(for: selectedInstallation)
                loadRuntimeSizes(for: selectedInstallation)
                loadInstallDetails(for: selectedInstallation)
                loadReleaseCatalog()
            }
        }
    }

    /// Refreshes only when the installation list has gone stale. The status menu
    /// and main window call this instead of a repeating timer so the app no
    /// longer re-runs a Spotlight scan every 30 seconds while idle.
    func refreshIfStale(olderThan interval: TimeInterval = 60) {
        guard let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < interval else {
            refresh(silently: true)
            return
        }
    }

    func icon(for installation: XcodeInstallation) -> NSImage {
        if let cached = iconCache[installation.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: installation.appURL.path)
        iconCache[installation.id] = image
        return image
    }

    func select(_ installation: XcodeInstallation) {
        selectedID = installation.id
        loadDetails(for: installation)
        loadCleanupEntries(for: installation)
        loadRuntimeSizes(for: installation)
        loadInstallDetails(for: installation)
        loadReleaseCatalog()
    }

    func cleanupEntries(for installation: XcodeInstallation) -> [XcodeCleanupEntry] {
        cleanupEntriesByID[installation.id] ?? []
    }

    func isCleanupLoading(for installation: XcodeInstallation) -> Bool {
        cleanupLoadingIDs.contains(installation.id)
    }

    func isRemovingCleanupEntry(_ entry: XcodeCleanupEntry) -> Bool {
        cleanupRemovingPaths.contains(entry.path)
    }

    var isAnyXcodeRunning: Bool {
        !XcodeProcessInspector.runningInstallations(among: installations).isEmpty
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
        guard !isAnyXcodeRunning else {
            isError = true
            statusMessage = String(localized: "检测到 Xcode 正在运行。请退出所有 Xcode 后再清理。")
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
                isError = true
                statusMessage = String(localized: "清理失败：\(errorMessage)")
            } else {
                cleanupSharedEntries?.removeAll { $0.id == entry.id }
                for id in Array(cleanupEntriesByID.keys) {
                    cleanupEntriesByID[id]?.removeAll { $0.id == entry.id }
                }
                isError = false
                switch entry.safety {
                case .safe:
                    statusMessage = String(localized: "已清理 \(entry.label)。")
                case .caution:
                    statusMessage = String(localized: "已移到废纸篓：\(entry.label)。")
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
        isError = false
        statusMessage = String(localized: "正在删除 Runtime \(runtime.label)…")
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) { () -> RuntimeRemovalReport in
                let outcome = XcodeTooling.deleteSimulatorRuntimes([runtime.identifier], installation: installation)
                return RuntimeRemovalReport(
                    removed: outcome.succeeded.isEmpty ? [] : [runtime.label],
                    failed: outcome.failed.isEmpty ? [] : [runtime.label]
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
        isError = false
        runtimeReclaimPreview = nil
        statusMessage = String(localized: "正在检查\(reclaim.title)的 Runtime…")
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
                statusMessage = String(localized: "检查完成。")
            } else if SimulatorRuntimeReclaim.matchedNothing(result.0) {
                // Nothing matches. That is information, not a failure: a machine used
                // within 30 days legitimately has nothing "30 天未使用", and reporting
                // that as 检查失败 was wrong.
                runtimeReclaimPreview = SimulatorRuntimeReclaimPreview(lines: [])
                runtimeReclaimPreviewOption = reclaim
                isError = false
                statusMessage = String(localized: "没有需要清理的 Runtime。")
            } else {
                isError = true
                statusMessage = String(localized: "检查失败：\(result.0.failureDescription)")
            }
        }
    }

    func reclaimRuntimes(_ reclaim: SimulatorRuntimeReclaim, for installation: XcodeInstallation) {
        guard !isReclaimingRuntimes else { return }
        isReclaimingRuntimes = true
        isError = false
        // Resolved on the main actor before the work starts, so the deletion set is
        // exactly what the preview showed.
        let previewed = previewedTargets(for: reclaim)
        statusMessage = String(localized: "正在清理\(reclaim.title)的 Runtime…")
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
                        return RuntimeRemovalReport(removed: [], failed: [dryRun.failureDescription])
                    }
                    targets = SimulatorRuntimeReclaim.preview(of: dryRun.stdout, runtimes: runtimes).targets
                }
                guard !targets.isEmpty else { return RuntimeRemovalReport(removed: [], failed: []) }

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
                    failed: outcome.failed.map { labels[$0] ?? $0 }
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
        let failed: [String]
    }

    private func completeRuntimeRemoval(_ report: RuntimeRemovalReport, installation: XcodeInstallation) {
        isReclaimingRuntimes = false
        runtimeReclaimPreview = nil
        runtimeReclaimPreviewOption = nil
        if !report.failed.isEmpty {
            isError = true
            statusMessage = String(localized: "清理失败：\(report.failed.joined(separator: "、"))")
        } else if report.removed.isEmpty {
            isError = false
            statusMessage = String(localized: "没有需要清理的 Runtime。")
        } else {
            isError = false
            statusMessage = String(
                localized: "已清理 \(report.removed.count) 个 Runtime：\(report.removed.joined(separator: "、"))。"
            )
        }
        // Both the measured sizes and the installed-runtime list have changed.
        loadRuntimeSizes(for: installation, force: true)
        Task { [weak self] in
            let runtimes = await Task.detached(priority: .utility) {
                XcodeTooling.simulatorRuntimes(for: installation)
            }.value
            self?.runtimesByID[installation.id] = runtimes
        }
    }

    /// Deletes every device the current Xcode SDK no longer supports. Those rows are
    /// disabled in the UI (they cannot boot or be erased), so without this they can
    /// only accumulate.
    func deleteUnavailableDevices(for installation: XcodeInstallation) {
        let unavailable = simulatorDevices(for: installation).filter { !$0.isAvailable }.count
        guard unavailable > 0 else { return }
        isError = false
        statusMessage = String(localized: "正在删除 \(unavailable) 个不可用 Simulator 设备…")
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let actionResult = XcodeTooling.deleteUnavailableDevices(for: installation)
                let devices = actionResult.succeeded ? XcodeTooling.simulatorDevices(for: installation) : nil
                return (actionResult, devices)
            }.value
            guard let self else { return }
            if result.0.succeeded {
                if let devices = result.1 { devicesByID[installation.id] = devices }
                isError = false
                statusMessage = String(localized: "已删除 \(unavailable) 个不可用 Simulator 设备。")
            } else {
                isError = true
                statusMessage = String(localized: "Simulator 操作失败：\(result.0.failureDescription)")
            }
        }
    }

    // MARK: - 版本详细信息

    /// What the installed bundle says about itself.
    ///
    /// Two plist reads, so it is done on demand rather than inside the toolchain
    /// scan, which shells out to several processes.
    func loadInstallDetails(for installation: XcodeInstallation) {
        guard installDetailsByID[installation.id] == nil else { return }
        installDetailsByID[installation.id] = XcodeInstallDetails.read(
            appURL: installation.appURL,
            fallbackBuild: installation.build
        )
    }

    func installDetails(for installation: XcodeInstallation) -> XcodeInstallDetails? {
        installDetailsByID[installation.id]
    }

    /// The index entry for an installation, matched on Apple's published build.
    func releaseInfo(for installation: XcodeInstallation) -> XcodeReleaseInfo? {
        XcodeReleaseCatalog.release(matchingBuild: installation.build, in: releaseCatalog)
    }

    /// Fetches the release index, served from a cached copy for a day.
    ///
    /// Called when a detail page is opened, which is what makes this automatic; a
    /// loaded or in-flight fetch is not repeated. A previous failure is retried,
    /// since opening the page again is a reasonable way to ask again.
    func loadReleaseCatalog(force: Bool = false) {
        if !force {
            switch releaseCatalogState {
            case .loading, .loaded: return
            case .idle, .unavailable: break
            }
        }
        releaseCatalogTask?.cancel()
        releaseCatalogState = .loading
        let store = releaseCatalogStore
        releaseCatalogTask = Task { [weak self] in
            let result = await store.load(forceRefresh: force)
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                releaseCatalog = snapshot.releases
                releaseCatalogState = .loaded(cachedAt: snapshot.cachedAt, refreshFailed: snapshot.refreshFailed)
            case .failure(let error):
                releaseCatalogState = .unavailable(
                    error.errorDescription ?? String(localized: "无法获取发布信息。")
                )
            }
        }
    }

    func loadDetails(for installation: XcodeInstallation) {
        guard detailsByID[installation.id] == nil, detailTasks[installation.id] == nil else { return }
        loadingDetailsIDs.insert(installation.id)
        detailTasks[installation.id] = Task.detached(priority: .utility) { [weak self] in
            let result = (
                XcodeTooling.details(for: installation),
                XcodeTooling.simulatorRuntimes(for: installation),
                XcodeTooling.simulatorDevices(for: installation)
            )
            guard !Task.isCancelled else {
                await self?.completeDetailsLoad(for: installation.id, result: nil)
                return
            }
            await self?.completeDetailsLoad(for: installation.id, result: result)
        }
    }

    func isLoadingDetails(for installation: XcodeInstallation) -> Bool {
        loadingDetailsIDs.contains(installation.id)
    }

    private func completeDetailsLoad(for id: String, result: (XcodeDetails, [SimulatorRuntime], [SimulatorDevice])?) {
        if let result {
            detailsByID[id] = result.0
            runtimesByID[id] = result.1
            devicesByID[id] = result.2
        }
        loadingDetailsIDs.remove(id)
        detailTasks[id] = nil
    }

    /// A description of the running Xcodes, or nil when a switch needs no confirmation.
    private static func runningXcodeDescription(among installations: [XcodeInstallation]) -> String? {
        let running = XcodeProcessInspector.runningInstallations(among: installations)
        guard !running.isEmpty else { return nil }
        return running.map { "\($0.name) \($0.displayVersion)" }.joined(separator: "、")
    }

    private static func confirmSwitchWhileXcodeRuns(_ running: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Xcode 正在运行")
        alert.informativeText = String(localized: "\(running) 正在运行。切换会改变它正在使用的工具链，可能影响正在进行的构建或调试。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "仍要切换"))
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func activateSelection() {
        guard let installation = selectedInstallation else { return }
        activate(installation)
    }

    /// Switches the active developer directory.
    ///
    /// A running Xcode keeps using the toolchain it was started with, so this asks
    /// first. The confirmation lives here rather than in a view because both the
    /// menu bar and the settings window come through this method, and the settings
    /// window already prompts modally elsewhere.
    func activate(_ installation: XcodeInstallation, thenOpen project: URL? = nil, force: Bool = false) {
        if installation.developerURL.path == activeDeveloperPath {
            statusMessage = String(localized: "所选 Xcode 已处于激活状态。")
            if let project { XcodeActions.open(project, with: installation) }
            return
        }
        guard !isSwitching else { return }
        if !force, let running = Self.runningXcodeDescription(among: installations) {
            guard Self.confirmSwitchWhileXcodeRuns(running) else {
                statusMessage = String(localized: "已取消切换。")
                return
            }
        }
        if let activeInstallation {
            recordActivation(activeInstallation)
        }
        isSwitching = true
        isError = false
        statusMessage = String(localized: "正在请求管理员授权…")
        Task {
            let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try XcodeActivator.activate(installation)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            isSwitching = false
            if let errorMessage {
                isError = true
                statusMessage = String(localized: "切换失败：\(errorMessage)")
                return
            }
            activeDeveloperPath = XcodeLocator.activeDeveloperPath()
            let verified = activeDeveloperPath == installation.developerURL.path
            isError = !verified
            statusMessage = verified ? String(localized: "已激活并验证 Xcode \(installation.displayVersion)。") : String(localized: "切换命令完成，但未能验证当前开发者目录。")
            if verified {
                recordActivation(installation)
            }
            if let project, verified { XcodeActions.open(project, with: installation) }
        }
    }

    func openSelectedXcode() {
        guard let selectedInstallation, XcodeActions.openXcode(selectedInstallation) else {
            statusMessage = String(localized: "无法打开所选 Xcode。")
            isError = true
            return
        }
        statusMessage = String(localized: "已打开 Xcode \(selectedInstallation.displayVersion)。")
        isError = false
    }

    func openTerminal(for installation: XcodeInstallation, directory: URL? = nil) {
        let target = directory ?? FileManager.default.homeDirectoryForCurrentUser
        let success = XcodeActions.openTerminal(at: target, developerPath: installation.developerURL.path)
        isError = !success
        statusMessage = success ? String(localized: "已打开终端，DEVELOPER_DIR 指向 Xcode \(installation.displayVersion)。") : String(localized: "无法打开终端。")
    }

    /// The shell assignment that makes one session use this Xcode without
    /// changing the system-wide developer directory, and therefore without
    /// administrator authorization.
    nonisolated static func developerDirectoryExport(for installation: XcodeInstallation) -> String {
        ProjectEnvironmentOutput.exportDeveloperDirectory(installation.developerURL.path).shellSource
    }

    func copyDeveloperDirectoryExport(for installation: XcodeInstallation) {
        copyToPasteboard(Self.developerDirectoryExport(for: installation))
        statusMessage = String(localized: "已复制 export 命令。粘贴到终端即可让该会话使用 Xcode \(installation.displayVersion)，不会修改系统设置。")
        isError = false
    }

    /// Line the user adds to `.zshrc` so entering a project directory sets
    /// `DEVELOPER_DIR` automatically.
    ///
    /// The trailing `"` needs the doubled quote: in a raw string literal the
    /// first `"#` terminates it, which would silently drop the closing quote.
    nonisolated static var shellIntegrationCommand: String {
        #"eval "$(xcodeswitcher shell-init zsh)""#
    }

    nonisolated static var cliExecutablePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xcodeswitcher").path
    }

    /// Command that puts the CLI bundled inside the app on the user's PATH.
    nonisolated static var cliLinkCommand: String {
        "mkdir -p ~/.local/bin && ln -sf \"\(cliExecutablePath)\" ~/.local/bin/xcodeswitcher"
    }

    func copyShellIntegrationCommand() {
        copyToPasteboard(Self.shellIntegrationCommand)
        statusMessage = String(localized: "已复制 Shell 集成命令，请添加到 ~/.zshrc。")
        isError = false
    }

    func copyCLILinkCommand() {
        copyToPasteboard(Self.cliLinkCommand)
        statusMessage = String(localized: "已复制 CLI 链接命令。")
        isError = false
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func toggleFavorite(_ installation: XcodeInstallation) {
        if configuration.favoriteIDs.contains(installation.id) {
            configuration.favoriteIDs.remove(installation.id)
        } else {
            configuration.favoriteIDs.insert(installation.id)
        }
        persist()
    }

    func isFavorite(_ installation: XcodeInstallation) -> Bool {
        configuration.favoriteIDs.contains(installation.id)
    }

    func alias(for installation: XcodeInstallation) -> String {
        configuration.xcodeAliases[installation.id] ?? ""
    }

    func updateAlias(for installation: XcodeInstallation, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            configuration.xcodeAliases.removeValue(forKey: installation.id)
        } else {
            configuration.xcodeAliases[installation.id] = trimmed
        }
        persist()
    }

    func addProject(_ url: URL) {
        guard url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" else {
            statusMessage = String(localized: "请选择 .xcodeproj 或 .xcworkspace。")
            isError = true
            return
        }
        guard !configuration.projects.contains(where: { $0.path == url.path }) else {
            statusMessage = String(localized: "该项目已经添加。")
            isError = false
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = String(localized: "项目路径不存在：\(url.path)")
            isError = true
            return
        }
        let profile = ProjectProfile(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        configuration.projects.append(profile)
        persist()
        if let match = automaticMatch(for: profile) {
            isError = !match.isInstalled
            statusMessage = match.isInstalled
                ? String(localized: "已添加项目 \(profile.name)，自动匹配 Xcode \(match.requirement.normalizedVersion)。")
                : String(localized: "已添加项目 \(profile.name)，但未安装其要求的 Xcode \(match.requirement.normalizedVersion)。")
        } else {
            statusMessage = String(localized: "已添加项目 \(profile.name)。")
            isError = false
        }
    }

    func removeProject(_ profile: ProjectProfile) {
        configuration.projects.removeAll { $0.id == profile.id }
        persist()
    }

    var invalidProjects: [ProjectProfile] {
        configuration.projects.filter { !snapshot(for: $0).isProjectPresent }
    }

    func removeInvalidProjects() {
        let invalidIDs = Set(invalidProjects.map(\.id))
        configuration.projects.removeAll { invalidIDs.contains($0.id) }
        persist()
        statusMessage = invalidIDs.isEmpty ? String(localized: "没有失效项目。") : String(localized: "已移除 \(invalidIDs.count) 个失效项目。")
        isError = false
    }

    func updateProject(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        guard let index = configuration.projects.firstIndex(where: { $0.id == profile.id }) else { return }
        configuration.projects[index].name = name
        configuration.projects[index].xcodeID = xcodeID
        persist()
    }

    func installation(for profile: ProjectProfile) -> XcodeInstallation? {
        let resolution = snapshot(for: profile).resolution
        return resolution.installationID.flatMap { id in installations.first(where: { $0.id == id }) }
    }

    func applyAndOpen(_ profile: ProjectProfile) {
        // Opening a project changes which Xcode is used, so resolve from disk
        // rather than trusting a cached snapshot.
        let resolution = snapshot(for: profile, refreshing: true).resolution
        if let issue = resolution.issueDescription {
            statusMessage = issue
            isError = true
            return
        }
        guard let installationID = resolution.installationID,
              let installation = installations.first(where: { $0.id == installationID }) else {
            statusMessage = String(localized: "没有可用于打开项目的 Xcode。")
            isError = true
            return
        }
        guard let decision = ProjectXcodeMatcher.openDecision(
            for: resolution,
            activeInstallationID: activeInstallation?.id
        ) else {
            statusMessage = String(localized: "无法解析项目使用的 Xcode。")
            isError = true
            return
        }
        switch decision {
        case .open:
            activate(installation, thenOpen: profile.url)
        case let .requiresConfirmation(_, source):
            guard let activeInstallation else {
                activate(installation, thenOpen: profile.url)
                return
            }
            pendingProjectOpen = ProjectOpenRequest(
                profile: profile,
                currentInstallation: activeInstallation,
                recommendedInstallation: installation,
                source: source
            )
            showMainWindow()
        }
    }

    func switchAndOpenPendingProject() {
        guard let request = pendingProjectOpen else { return }
        pendingProjectOpen = nil
        activate(request.recommendedInstallation, thenOpen: request.profile.url)
    }

    /// Opens the project with the recommended Xcode without touching
    /// `xcode-select`, so no administrator authorization is required and the
    /// rest of the machine keeps using the current developer directory.
    func openPendingProjectWithRecommendedXcode() {
        guard let request = pendingProjectOpen else { return }
        pendingProjectOpen = nil
        XcodeActions.open(request.profile.url, with: request.recommendedInstallation)
        statusMessage = String(localized: "已用 Xcode \(request.recommendedInstallation.displayVersion) 打开 \(request.profile.name)，未修改系统开发者目录。")
        isError = false
    }

    func cancelPendingProjectOpen() {
        pendingProjectOpen = nil
    }

    func automaticMatch(for profile: ProjectProfile) -> ProjectXcodeMatch? {
        snapshot(for: profile).match
    }

    func projectIssue(for profile: ProjectProfile) -> String? {
        snapshot(for: profile).resolution.issueDescription
    }

    /// Drops every cached project resolution. Called whenever the inputs a
    /// resolution depends on change, so the next read is fresh.
    func invalidateProjectSnapshots() {
        projectSnapshots.removeAll()
    }

    private func snapshot(for profile: ProjectProfile, refreshing: Bool = false) -> ProjectSnapshot {
        if !refreshing,
           let cached = projectSnapshots[profile.id],
           Date().timeIntervalSince(cached.computedAt) < Self.projectSnapshotLifetime {
            return cached
        }

        // Walk the ancestor directories once and reuse the result for both the
        // resolution and the automatic match.
        let configurationURL = ProjectLocalConfigurationStore.configurationURL(for: profile.url)
        let localConfiguration = configurationURL.flatMap {
            ProjectLocalConfigurationStore.load(in: $0.deletingLastPathComponent())
        }
        let resolved = ProjectSnapshot(
            resolution: ProjectXcodeMatcher.resolve(
                profile: profile,
                installations: installations,
                aliases: configuration.xcodeAliases,
                activeInstallationID: activeInstallation?.id,
                localConfiguration: localConfiguration
            ),
            match: Self.match(
                for: profile,
                installations: installations,
                aliases: configuration.xcodeAliases,
                localConfiguration: localConfiguration,
                configurationURL: configurationURL
            ),
            isProjectPresent: FileManager.default.fileExists(atPath: profile.path),
            computedAt: Date()
        )
        projectSnapshots[profile.id] = resolved
        return resolved
    }

    private static func match(
        for profile: ProjectProfile,
        installations: [XcodeInstallation],
        aliases: [String: String],
        localConfiguration: ProjectLocalConfiguration?,
        configurationURL: URL?
    ) -> ProjectXcodeMatch? {
        if let selector = localConfiguration?.xcode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selector.isEmpty,
           let installation = installations.first(where: {
               $0.id == selector || $0.appURL.path == selector || $0.developerURL.path == selector ||
               $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame ||
               aliases[$0.id]?.localizedCaseInsensitiveCompare(selector) == .orderedSame
           }),
           let normalized = ProjectXcodeMatcher.normalizeVersion(selector) ?? ProjectXcodeMatcher.normalizeVersion(installation.version) {
            return ProjectXcodeMatch(
                requirement: ProjectXcodeRequirement(
                    source: configurationURL?.path ?? ".xcode-switcher.json",
                    rawValue: selector,
                    normalizedVersion: normalized
                ),
                installationID: installation.id
            )
        }
        return ProjectXcodeMatcher.match(
            projectURL: profile.url,
            installations: installations,
            aliases: aliases
        )
    }

    func addSearchPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !configuration.customSearchPaths.contains(url.path) {
                configuration.customSearchPaths.append(url.path)
            }
            persist()
            refresh()
            onSearchPathsChanged?()
        }
    }

    func removeSearchPath(_ path: String) {
        configuration.customSearchPaths.removeAll { $0 == path }
        persist()
        refresh()
        onSearchPathsChanged?()
    }

    func toggleGlobalShortcut(_ enabled: Bool) {
        configuration.globalShortcutEnabled = enabled
        if enabled {
            isGlobalShortcutAvailable = GlobalShortcutService.shared.start(using: configuration.globalShortcut)
        } else {
            GlobalShortcutService.shared.stop()
            isGlobalShortcutAvailable = true
        }
        persist()
    }

    func updateGlobalShortcut(_ shortcut: GlobalShortcut) {
        configuration.globalShortcut = shortcut
        if configuration.globalShortcutEnabled {
            isGlobalShortcutAvailable = GlobalShortcutService.shared.update(shortcut)
        }
        persist()
    }

    func refreshGlobalShortcutPermission() {
        isGlobalShortcutAvailable = GlobalShortcutService.shared.isAccessibilityTrusted
    }

    var globalShortcutDisplayName: String {
        configuration.globalShortcut.displayName
    }

    var isUpdateServiceAvailable: Bool {
        UpdateService.shared.isAvailable
    }

    var updateServiceMessage: String {
        if !releaseCheckMessage.isEmpty { return releaseCheckMessage }
        if UpdateService.shared.isAvailable { return "Sparkle 自动更新已启用。" }
        return "当前为直接分发构建，可检查 GitHub Releases；Sparkle 自动更新仅在正式签名构建启用。"
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
            configuration.launchAtLoginEnabled = isLaunchAtLoginEnabled
            persist()
            statusMessage = isLaunchAtLoginEnabled ? String(localized: "已启用登录时启动。") : String(localized: "已关闭登录时启动。")
            isError = false
        } catch {
            isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
            statusMessage = String(localized: "无法修改登录项：\(error.localizedDescription)")
            isError = true
        }
    }

    func toggleMenuBarOnly(_ enabled: Bool) {
        configuration.menuBarOnly = enabled
        persist()
        AppDelegate.shared?.applyMenuBarOnly(enabled)
    }

    func toggleAutomaticUpdateChecks(_ enabled: Bool) {
        configuration.automaticallyChecksForUpdates = enabled
        persist()
        UpdateService.shared.setAutomaticallyChecksForUpdates(enabled)
    }

    func checkForUpdates() {
        guard !isCheckingRelease else { return }
        if UpdateService.shared.isAvailable {
            UpdateService.shared.checkForUpdates()
            statusMessage = String(localized: "正在检查更新…")
            isError = false
            return
        }
        isCheckingRelease = true
        releaseCheckMessage = "正在读取 GitHub Releases…"
        statusMessage = String(localized: "正在检查 GitHub Releases…")
        isError = false
        Task { @MainActor in
            let result = await UpdateService.shared.checkGitHubRelease()
            isCheckingRelease = false
            if let error = result.errorMessage {
                releaseCheckMessage = "GitHub Releases 检查失败：\(error)"
                statusMessage = releaseCheckMessage
                isError = true
            } else if result.isUpdateAvailable, let latest = result.latestVersion {
                releaseCheckMessage = "发现新版本 \(latest)，点击右侧按钮下载。"
                statusMessage = releaseCheckMessage
                isError = false
            } else {
                releaseCheckMessage = "当前已是最新版本（\(result.currentVersion)）。"
                statusMessage = releaseCheckMessage
                isError = false
            }
        }
    }

    func openReleasePage() {
        let opened = UpdateService.shared.openReleasePage()
        statusMessage = opened ? String(localized: "已打开 GitHub Releases 下载页。") : String(localized: "无法打开 GitHub Releases。")
        isError = !opened
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xcode-switcher-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(configuration, to: url)
            statusMessage = String(localized: "配置已导出。")
            isError = false
        } catch { statusMessage = String(localized: "导出失败：\(error.localizedDescription)"); isError = true }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            configuration = try store.import(from: url)
            persist()
            refresh()
            onSearchPathsChanged?()
            statusMessage = String(localized: "配置已导入。")
            isError = false
        } catch { statusMessage = String(localized: "导入失败：\(error.localizedDescription)"); isError = true }
    }

    var hasConfigurationBackup: Bool { store.hasBackup }

    func restoreConfigurationBackup() {
        do {
            configuration = try store.restoreBackup()
            refresh()
            onSearchPathsChanged?()
            statusMessage = String(localized: "已恢复上次配置备份。")
            isError = false
        } catch {
            statusMessage = String(localized: "恢复配置失败：\(error.localizedDescription)")
            isError = true
        }
    }

    func hasAvailableRuntime(for installation: XcodeInstallation) -> Bool {
        guard let runtimes = runtimesByID[installation.id] else { return false }
        if let sdkVersion = detailsByID[installation.id]?.sdkVersion,
           !sdkVersion.isEmpty,
           sdkVersion != XcodeDetails.unknownValue {
            return runtimes.contains { $0.isAvailable && $0.version == sdkVersion }
        }
        return runtimes.contains(where: { $0.isAvailable })
    }

    func downloadRuntime() {
        guard let installation = selectedInstallation, !runtimeDownload.isDownloading else { return }
        if hasAvailableRuntime(for: installation) {
            statusMessage = String(localized: "当前 Xcode 已有可用的 iOS Simulator Runtime。")
            isError = false
            return
        }
        runtimeDownload.begin("正在准备下载…")
        statusMessage = String(localized: "正在下载 iOS Simulator Runtime…")
        runtimeDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = XcodeTooling.downloadIOSRuntime(for: installation) { output in
                let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                Task { @MainActor in self.runtimeDownload.update(message) }
            }
            let runtimes = result.succeeded ? XcodeTooling.simulatorRuntimes(for: installation) : nil
            await self.completeRuntimeDownload(result: result, runtimes: runtimes, installationID: installation.id)
        }
    }

    func cancelRuntimeDownload() {
        runtimeDownload.update("正在取消…")
        runtimeDownloadTask?.cancel()
    }

    func simulatorDevices(for installation: XcodeInstallation) -> [SimulatorDevice] {
        devicesByID[installation.id] ?? []
    }

    func performSimulatorAction(_ action: String, device: SimulatorDevice, installation: XcodeInstallation) {
        guard ["boot", "shutdown", "erase", "delete"].contains(action) else { return }
        // One complete sentence per action. Injecting a verb into a shared template
        // ("正在%@ Simulator %@…") cannot be translated: English needs a progressive
        // form ("Booting…") that the imperative button labels ("Boot") cannot supply.
        statusMessage = switch action {
        case "boot":
            String(localized: "正在启动 Simulator \(device.name)…")
        case "shutdown":
            String(localized: "正在关闭 Simulator \(device.name)…")
        case "delete":
            String(localized: "正在删除 Simulator \(device.name)…")
        default:
            String(localized: "正在抹掉 Simulator \(device.name)…")
        }
        isError = false
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                let actionResult = XcodeTooling.simulatorAction(action, device: device, installation: installation)
                let devices = actionResult.succeeded ? XcodeTooling.simulatorDevices(for: installation) : nil
                return (actionResult, devices)
            }.value
            if result.0.succeeded {
                if let devices = result.1 { devicesByID[installation.id] = devices }
                statusMessage = String(localized: "Simulator \(device.name) 操作完成。")
            } else {
                isError = true
                statusMessage = String(localized: "Simulator 操作失败：\(result.0.failureDescription)")
            }
        }
    }

    func rollbackToPreviousXcode() {
        let candidates = configuration.activationHistory.compactMap { id in
            installations.first { $0.id == id }
        }
        guard let previous = candidates.first(where: { !isActive($0) }) else {
            statusMessage = String(localized: "没有可回滚的上一个 Xcode。")
            isError = true
            return
        }
        activate(previous)
    }

    private func recordActivation(_ installation: XcodeInstallation) {
        configuration.activationHistory.removeAll { $0 == installation.id }
        configuration.activationHistory.insert(installation.id, at: 0)
        configuration.activationHistory = Array(configuration.activationHistory.prefix(10))
        persist()
    }

    private func completeRuntimeDownload(result: ProcessResult, runtimes: [SimulatorRuntime]?, installationID: String) {
        runtimeDownloadTask = nil
        isError = !result.succeeded && !result.cancelled
        if result.succeeded {
            statusMessage = String(localized: "iOS Simulator Runtime 下载命令已完成。")
            runtimeDownload.finish("下载完成")
        } else if result.cancelled {
            statusMessage = String(localized: "已取消 iOS Simulator Runtime 下载。")
            runtimeDownload.finish("已取消")
        } else {
            statusMessage = String(localized: "下载失败：\(result.failureDescription)")
            runtimeDownload.finish(result.failureDescription)
        }
        if let runtimes { runtimesByID[installationID] = runtimes }
    }

    func openXcodeSettings(for installation: XcodeInstallation) {
        statusMessage = String(localized: "已打开 \(installation.name)，正在显示 Xcode Settings…")
        isError = false
        // The menu automation runs a second later and can fail (missing
        // Accessibility permission, unexpected menu layout), so the result is
        // reported instead of leaving the user guessing.
        XcodeActions.openXcodeSettings(for: installation) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.statusMessage = String(localized: "已在 \(installation.name) 中打开 Settings。")
                    self.isError = false
                case let .failure(error):
                    self.statusMessage = error.errorDescription ?? String(localized: "无法打开 Xcode Settings。")
                    self.isError = true
                }
            }
        }
    }

    /// Turns a stored value into what the UI shows. The "unknown" sentinel is
    /// stored untranslated (logic compares it) and localized only here.
    private static func displayValue(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return String(localized: "检测中…") }
        return raw == XcodeDetails.unknownValue ? String(localized: "未知") : raw
    }

    func diagnostics(for installation: XcodeInstallation) -> [XcodeDiagnostic] {
        let details = detailsByID[installation.id]
        return [
            XcodeDiagnostic(title: String(localized: "应用路径"), value: installation.appURL.path, isWarning: false),
            XcodeDiagnostic(title: String(localized: "Developer 路径"), value: installation.developerURL.path, isWarning: false),
            XcodeDiagnostic(title: String(localized: "当前激活"), value: installation.developerURL.path == activeDeveloperPath ? String(localized: "是") : String(localized: "否"), isWarning: installation.developerURL.path != activeDeveloperPath),
            XcodeDiagnostic(title: String(localized: "iPhoneOS SDK"), value: Self.displayValue(details?.sdkVersion), isWarning: false),
            XcodeDiagnostic(title: String(localized: "Swift"), value: details?.swiftVersion ?? String(localized: "检测中…"), isWarning: false),
            XcodeDiagnostic(title: String(localized: "xcode-select 当前路径"), value: commandLineToolsPath, isWarning: false)
        ]
    }

    func runEnvironmentDoctor(for installation: XcodeInstallation) {
        guard environmentDoctorTasks[installation.id] == nil else { return }
        environmentDoctorRunningIDs.insert(installation.id)
        statusMessage = String(localized: "正在体检 Xcode \(installation.displayVersion)…")
        isError = false
        let activePath = activeDeveloperPath
        environmentDoctorTasks[installation.id] = Task.detached(priority: .userInitiated) { [weak self] in
            let report = EnvironmentDoctor.inspect(
                installation: installation,
                activeDeveloperPath: activePath
            )
            guard !Task.isCancelled else {
                await self?.completeEnvironmentDoctor(for: installation.id, report: nil)
                return
            }
            await self?.completeEnvironmentDoctor(for: installation.id, report: report)
        }
    }

    func isEnvironmentDoctorRunning(for installation: XcodeInstallation) -> Bool {
        environmentDoctorRunningIDs.contains(installation.id)
    }

    func copyEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = environmentReportsByID[installation.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EnvironmentDoctor.render(report), forType: .string)
        statusMessage = String(localized: "环境诊断报告已复制。")
        isError = false
    }

    func copyRedactedEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = environmentReportsByID[installation.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EnvironmentDoctor.render(report, redacted: true), forType: .string)
        statusMessage = String(localized: "脱敏环境诊断报告已复制。")
        isError = false
    }

    func exportEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = environmentReportsByID[installation.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(installation.name)-environment-report.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EnvironmentDoctor.render(report).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = String(localized: "环境诊断报告已导出。")
            isError = false
        } catch {
            statusMessage = String(localized: "报告导出失败：\(error.localizedDescription)")
            isError = true
        }
    }

    func exportRedactedEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = environmentReportsByID[installation.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(installation.name)-environment-report-redacted.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EnvironmentDoctor.render(report, redacted: true).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = String(localized: "脱敏环境诊断报告已导出。")
            isError = false
        } catch {
            statusMessage = String(localized: "报告导出失败：\(error.localizedDescription)")
            isError = true
        }
    }

    private func completeEnvironmentDoctor(for id: String, report: EnvironmentReport?) {
        if let report {
            environmentReportsByID[id] = report
            isError = report.highestSeverity == .error
            statusMessage = report.issueCount == 0
                ? String(localized: "环境体检完成，未发现问题。")
                : String(localized: "环境体检完成，发现 \(report.issueCount) 项需要关注。")
        }
        environmentDoctorRunningIDs.remove(id)
        environmentDoctorTasks[id] = nil
    }

    func refreshSigning() {
        guard !isRefreshingSigning else { return }
        isRefreshingSigning = true
        Task {
            let result = await Task.detached(priority: .utility) {
                (SigningService.certificates(), SigningService.provisioningProfiles())
            }.value
            signingCertificates = result.0
            provisioningProfiles = result.1
            isRefreshingSigning = false
        }
    }

    func refreshSigningReport(for profile: ProjectProfile) {
        refreshSigningReport(for: profile, scheme: nil, configuration: nil)
    }

    func refreshSigningReport(for profile: ProjectProfile, scheme: String?, configuration: String?) {
        signingReportTask?.cancel()
        if let issue = projectIssue(for: profile) {
            signingReport = ProjectSigningReport(
                projectPath: profile.path,
                scheme: scheme,
                configuration: configuration,
                availableSchemes: signingReport?.availableSchemes ?? [],
                availableConfigurations: signingReport?.availableConfigurations ?? [],
                targets: [],
                errorMessage: issue
            )
            isLoadingSigningReport = false
            return
        }
        guard let installation = installation(for: profile) else { return }
        signingReport = nil
        isLoadingSigningReport = true
        signingReportTask = Task.detached(priority: .utility) { [weak self] in
            let report = SigningService.projectSigningReport(
                for: profile.url,
                developerURL: installation.developerURL,
                scheme: scheme,
                configuration: configuration
            )
            guard !Task.isCancelled else { return }
            await self?.completeSigningReport(report)
        }
    }

    private func completeSigningReport(_ report: ProjectSigningReport) {
        signingReport = report
        isLoadingSigningReport = false
        signingReportTask = nil
    }

    func exportCertificate(_ certificate: SigningCertificate) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(certificate.name.replacingOccurrences(of: "/", with: "-" )).cer"
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SigningService.exportCertificate(certificate, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            statusMessage = String(localized: "公钥证书已导出并在 Finder 中显示。")
            isError = false
        } catch {
            statusMessage = String(localized: "证书导出失败：\(error.localizedDescription)")
            isError = true
        }
    }

    func openKeychainAccess() {
        if SigningService.openKeychainAccess() {
            statusMessage = String(localized: "已打开钥匙串访问。")
            isError = false
        } else {
            statusMessage = String(localized: "无法打开钥匙串访问。")
            isError = true
        }
    }

    func revealProfilesFolder() {
        let directories = SigningService.profileDirectories()
        let directory = directories.first(where: { url in
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.contains(where: { $0.pathExtension == "mobileprovision" }) == true
        }) ?? directories.last!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    func persist() {
        invalidateProjectSnapshots()
        do {
            try store.save(configuration)
            configurationSaveError = nil
        } catch {
            // Losing an alias or project binding silently is worse than a visible
            // error, so keep it on screen until a later save succeeds.
            configurationSaveError = error.localizedDescription
            statusMessage = String(localized: "配置保存失败：\(error.localizedDescription)")
            isError = true
        }
    }

    /// Project name and binding edits arrive per keystroke. Debounce them so
    /// typing does not rewrite the configuration file and its backups on every
    /// character.
    func scheduleProjectUpdate(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        pendingProjectUpdate = (profile, name, xcodeID)
        projectUpdateTask?.cancel()
        projectUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushPendingProjectUpdate()
        }
    }

    /// Applies an edit that is still inside the debounce window.
    func flushPendingProjectUpdate() {
        projectUpdateTask?.cancel()
        projectUpdateTask = nil
        guard let pending = pendingProjectUpdate else { return }
        pendingProjectUpdate = nil
        updateProject(pending.profile, name: pending.name, xcodeID: pending.xcodeID)
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func showMainWindow(focusSearch: Bool = false) {
        AppDelegate.shared?.presentMainWindow(focusSearch: focusSearch)
    }

    func showSettings() {
        AppDelegate.shared?.showSettings()
    }
}
