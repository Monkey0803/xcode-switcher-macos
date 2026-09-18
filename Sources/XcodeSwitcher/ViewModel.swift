import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XcodeSwitcherKit

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
final class XcodeViewModel: ObservableObject, StatusReporting {
    @Published private(set) var installations: [XcodeInstallation] = []
    @Published var selectedID: String?
    @Published private(set) var activeDeveloperPath: String?
    @Published private(set) var commandLineToolsPath = String(localized: "检测中…")
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var loadingDetailsIDs: Set<String> = []
    @Published private(set) var isGlobalShortcutAvailable = true
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var detailsByID: [String: XcodeDetails] = [:]
    @Published private(set) var runtimesByID: [String: [SimulatorRuntime]] = [:]
    @Published private(set) var devicesByID: [String: [SimulatorDevice]] = [:]

    /// Which option the preview above belongs to, so 清理 deletes exactly that set.

    @Published var configuration: AppConfiguration
    @Published var statusMessage = String(localized: "正在扫描本机安装的 Xcode…")
    @Published var isError = false
    @Published private(set) var configurationSaveError: String?
    @Published var filter = ""
    @Published private(set) var searchFocusRequest = 0

    /// Deliberately not `@Published`: only the runtime section observes it, so
    /// download progress does not republish the whole view model.
    let runtimeDownload = RuntimeDownloadState()

    /// Code-signing identities live in their own store. Its state is re-published
    /// below, so the views keep observing this one object.
    let signing = SigningStore()

    /// Disk cleanup and simulator-runtime reclamation, in its own store. Its state
    /// is re-published below, so the views keep observing this one object.
    let cleanup = DiskCleanupStore()

    /// The release index, per-installation build details and the update check.
    /// Assigned in `init` because it takes the injected catalog store.
    let releases: ReleaseStore

    /// Environment checks and the reports they produce.
    let environment = EnvironmentStore()

    /// Projects: profiles, how each resolves to an Xcode, and opening them.
    let projects = ProjectStore()

    private let store: AppConfigurationStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var runtimeDownloadTask: Task<Void, Never>?

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
        releases = ReleaseStore(releaseCatalogStore: releaseCatalogStore)
        configuration = store.load()
        isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
        // Each store's dependencies on this model, plus the re-publish that keeps
        // the views' single `@EnvironmentObject` working.
        signing.resolveInstallation = { [weak self] profile in self?.installation(for: profile) }
        signing.projectIssue = { [weak self] profile in self?.projectIssue(for: profile) }
        signing.status = self
        signing.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        cleanup.status = self
        cleanup.isAnyXcodeRunning = { [weak self] in self?.isAnyXcodeRunning ?? false }
        cleanup.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        releases.status = self
        releases.installations = { [weak self] in self?.installations ?? [] }
        releases.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        environment.status = self
        environment.activeDeveloperPath = { [weak self] in self?.activeDeveloperPath }
        environment.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        projects.projects = { [weak self] in self?.configuration.projects ?? [] }
        projects.setProjects = { [weak self] in self?.configuration.projects = $0 }
        projects.persist = { [weak self] in self?.persist() }
        projects.installations = { [weak self] in self?.installations ?? [] }
        projects.activeInstallation = { [weak self] in self?.activeInstallation }
        projects.aliases = { [weak self] in self?.configuration.xcodeAliases ?? [:] }
        projects.activate = { [weak self] installation, url in self?.activate(installation, thenOpen: url) }
        projects.showMainWindow = { [weak self] in self?.showMainWindow() }
        projects.status = self
        projects.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
    }

    // MARK: - 签名

    /// The signing store owns this state. These forward so the views and the tests
    /// keep talking to a single object, exactly as they did before the split.
    var signingCertificates: [SigningCertificate] { signing.certificates }
    var provisioningProfiles: [ProvisioningProfile] { signing.profiles }
    var signingReport: ProjectSigningReport? { signing.report }
    var isRefreshingSigning: Bool { signing.isRefreshing }
    var isLoadingSigningReport: Bool { signing.isLoadingReport }

    func refreshSigning() { signing.refresh() }
    func refreshSigningReport(for profile: ProjectProfile) { signing.refreshReport(for: profile) }
    func refreshSigningReport(for profile: ProjectProfile, scheme: String?, configuration: String?) {
        signing.refreshReport(for: profile, scheme: scheme, configuration: configuration)
    }
    func exportCertificate(_ certificate: SigningCertificate) { signing.exportCertificate(certificate) }
    func openKeychainAccess() { signing.openKeychainAccess() }
    func revealProfilesFolder() { signing.revealProfilesFolder() }

    // MARK: - 磁盘清理与模拟器运行时

    /// Same forwarding contract as the signing store above: the store owns the
    /// state and the commands, and these keep the call sites unchanged.
    var runtimeReclaimPreview: SimulatorRuntimeReclaimPreview? { cleanup.runtimeReclaimPreview }
    var isReclaimingRuntimes: Bool { cleanup.isReclaimingRuntimes }

    func cleanupEntries(for installation: XcodeInstallation) -> [XcodeCleanupEntry] {
        cleanup.cleanupEntries(for: installation)
    }
    func isCleanupLoading(for installation: XcodeInstallation) -> Bool {
        cleanup.isCleanupLoading(for: installation)
    }
    func isRemovingCleanupEntry(_ entry: XcodeCleanupEntry) -> Bool {
        cleanup.isRemovingCleanupEntry(entry)
    }
    func loadCleanupEntries(for installation: XcodeInstallation, force: Bool = false) {
        cleanup.loadCleanupEntries(for: installation, force: force)
    }
    func removeCleanupEntry(_ entry: XcodeCleanupEntry) { cleanup.removeCleanupEntry(entry) }
    func runtimeSizes(for installation: XcodeInstallation) -> [DiskUsageReporter.SimulatorRuntime] {
        cleanup.runtimeSizes(for: installation)
    }
    func isLoadingRuntimeSizes(for installation: XcodeInstallation) -> Bool {
        cleanup.isLoadingRuntimeSizes(for: installation)
    }
    func loadRuntimeSizes(for installation: XcodeInstallation, force: Bool = false) {
        cleanup.loadRuntimeSizes(for: installation, force: force)
    }
    func deleteRuntime(_ runtime: DiskUsageReporter.SimulatorRuntime, for installation: XcodeInstallation) {
        cleanup.deleteRuntime(runtime, for: installation)
    }
    func previewRuntimeReclaim(_ reclaim: SimulatorRuntimeReclaim, for installation: XcodeInstallation) {
        cleanup.previewRuntimeReclaim(reclaim, for: installation)
    }
    func reclaimRuntimes(_ reclaim: SimulatorRuntimeReclaim, for installation: XcodeInstallation) {
        cleanup.reclaimRuntimes(reclaim, for: installation)
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

    /// Reloads the installed simulator runtimes the detail pane lists. The cleanup
    /// store calls this after it changes what is installed, because that list
    /// belongs to the installations rather than to the store.
    func reloadInstalledRuntimes(for installation: XcodeInstallation) {
        Task { [weak self] in
            let runtimes = await Task.detached(priority: .utility) {
                XcodeTooling.simulatorRuntimes(for: installation)
            }.value
            self?.runtimesByID[installation.id] = runtimes
        }
    }

    // MARK: - 版本索引与更新

    /// Same forwarding contract as the stores above.
    var releaseCatalogState: ReleaseStore.ReleaseCatalogState { releases.releaseCatalogState }
    var allReleases: [XcodeReleaseInfo] { releases.allReleases }
    var installedBuilds: Set<String> { releases.installedBuilds }
    var isCheckingRelease: Bool { releases.isCheckingRelease }
    var isUpdateServiceAvailable: Bool { releases.isUpdateServiceAvailable }
    var updateServiceMessage: String { releases.updateServiceMessage }

    func installation(matching release: XcodeReleaseInfo) -> XcodeInstallation? {
        releases.installation(matching: release)
    }
    func installDetails(for installation: XcodeInstallation) -> XcodeInstallDetails? {
        releases.installDetails(for: installation)
    }
    func loadInstallDetails(for installation: XcodeInstallation) {
        releases.loadInstallDetails(for: installation)
    }
    func releaseInfo(for installation: XcodeInstallation) -> XcodeReleaseInfo? {
        releases.releaseInfo(for: installation)
    }
    func loadReleaseCatalog(force: Bool = false) { releases.loadReleaseCatalog(force: force) }
    func checkForUpdates() { releases.checkForUpdates() }
    func openReleasePage() { releases.openReleasePage() }

    // MARK: - 环境体检

    /// Same forwarding contract as the stores above. `diagnostics(for:)` stays in
    /// this type on purpose: it renders installation facts rather than check
    /// results, and reads `detailsByID` / `commandLineToolsPath`.
    var environmentReportsByID: [String: EnvironmentReport] { environment.reportsByID }

    func runEnvironmentDoctor(for installation: XcodeInstallation) {
        environment.runEnvironmentDoctor(for: installation)
    }
    func isEnvironmentDoctorRunning(for installation: XcodeInstallation) -> Bool {
        environment.isEnvironmentDoctorRunning(for: installation)
    }
    func copyEnvironmentReport(for installation: XcodeInstallation) {
        environment.copyEnvironmentReport(for: installation)
    }
    func copyRedactedEnvironmentReport(for installation: XcodeInstallation) {
        environment.copyRedactedEnvironmentReport(for: installation)
    }
    func exportEnvironmentReport(for installation: XcodeInstallation) {
        environment.exportEnvironmentReport(for: installation)
    }
    func exportRedactedEnvironmentReport(for installation: XcodeInstallation) {
        environment.exportRedactedEnvironmentReport(for: installation)
    }

    // MARK: - 项目

    /// Same forwarding contract as the stores above.
    var pendingProjectOpen: ProjectOpenRequest? { projects.pendingProjectOpen }
    var invalidProjects: [ProjectProfile] { projects.invalidProjects }

    func addProject(_ url: URL) { projects.addProject(url) }
    func removeProject(_ profile: ProjectProfile) { projects.removeProject(profile) }
    func removeInvalidProjects() { projects.removeInvalidProjects() }
    func updateProject(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        projects.updateProject(profile, name: name, xcodeID: xcodeID)
    }
    func installation(for profile: ProjectProfile) -> XcodeInstallation? {
        projects.installation(for: profile)
    }
    func applyAndOpen(_ profile: ProjectProfile) { projects.applyAndOpen(profile) }
    func switchAndOpenPendingProject() { projects.switchAndOpenPendingProject() }
    func openPendingProjectWithRecommendedXcode() { projects.openPendingProjectWithRecommendedXcode() }
    func cancelPendingProjectOpen() { projects.cancelPendingProjectOpen() }
    func automaticMatch(for profile: ProjectProfile) -> ProjectXcodeMatch? {
        projects.automaticMatch(for: profile)
    }
    func projectIssue(for profile: ProjectProfile) -> String? { projects.projectIssue(for: profile) }
    func invalidateProjectSnapshots() { projects.invalidateSnapshots() }
    func scheduleProjectUpdate(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        projects.scheduleProjectUpdate(profile, name: name, xcodeID: xcodeID)
    }
    func flushPendingProjectUpdate() { projects.flushPendingProjectUpdate() }

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
            projects.invalidateSnapshots()
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

    var isAnyXcodeRunning: Bool {
        !XcodeProcessInspector.runningInstallations(among: installations).isEmpty
    }

    /// What the installed bundle says about itself.
    ///
    /// Two plist reads, so it is done on demand rather than inside the toolchain
    /// scan, which shells out to several processes.

    /// The Xcode app icon, taken from a locally installed copy.
    ///
    /// Deliberately read from the user's own installation rather than shipped in the
    /// bundle: the icon is Apple's artwork, and this app has always shown it by asking
    /// the local bundle (the installed list and the detail header both do). Nil when no
    /// Xcode is installed at all, where the version list falls back to a symbol.
    var xcodeIcon: NSImage? {
        installations.first.map { icon(for: $0) }
    }

    /// Fetches the release index, served from a cached copy for a day.
    ///
    /// Called when a detail page is opened, which is what makes this automatic; a
    /// loaded or in-flight fetch is not repeated. A previous failure is retried,
    /// since opening the page again is a reasonable way to ask again.

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



    func persist() {
        projects.invalidateSnapshots()
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

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func showMainWindow(focusSearch: Bool = false) {
        AppDelegate.shared?.presentMainWindow(focusSearch: focusSearch)
    }

    func showSettings() {
        AppDelegate.shared?.showSettings()
    }

    func showAllVersions() {
        AppDelegate.shared?.showAllVersions()
    }
}
