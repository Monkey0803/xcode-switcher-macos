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

@MainActor
final class XcodeViewModel: ObservableObject, StatusReporting, ConfigurationOwning {

    /// Which option the preview above belongs to, so 清理 deletes exactly that set.

    @Published var statusMessage = String(localized: "正在扫描本机安装的 Xcode…")
    @Published var isError = false

    @Published var filter = ""
    @Published private(set) var searchFocusRequest = 0

    /// Deliberately not `@Published`: only the runtime section observes it, so
    /// download progress does not republish the whole view model.

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

    /// The configuration and the settings built on it. Assigned in `init` because
    /// it takes the injected configuration store.
    let settings: SettingsStore

    /// The installed Xcodes and everything done to one of them.
    let installs = InstallationStore()

    private var cancellables = Set<AnyCancellable>()

    /// `NSWorkspace.icon(forFile:)` goes through LaunchServices, so the result is
    /// cached instead of being re-fetched on every row render.

    /// Invoked when the folders that should be watched for Xcode installations
    /// change, so the app can re-arm its directory monitors.
    var onSearchPathsChanged: (() -> Void)?

    init(
        store: AppConfigurationStore = .shared,
        releaseCatalogStore: XcodeReleaseCatalogStore = .live,
        configuresSystemServices: Bool = true
    ) {
        settings = SettingsStore(store: store)
        releases = ReleaseStore(releaseCatalogStore: releaseCatalogStore)
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
        installs.status = self
        installs.owner = self
        installs.didRefresh = { [weak self] in self?.projects.invalidateSnapshots() }
        installs.searchPathsDidChange = { [weak self] in self?.onSearchPathsChanged?() }
        // After a refresh or a selection, every other store reloads for that
        // installation. This is the one place that knows about all of them.
        installs.reloadSelected = { [weak self] installation in
            guard let self, let installation else { return }
            self.installs.loadDetails(for: installation)
            self.cleanup.loadCleanupEntries(for: installation)
            self.cleanup.loadRuntimeSizes(for: installation)
            self.releases.loadInstallDetails(for: installation)
            self.releases.loadReleaseCatalog()
        }
        installs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.status = self
        settings.configurationDidChange = { [weak self] in self?.projects.invalidateSnapshots() }
        settings.searchFoldersDidChange = { [weak self] in
            self?.installs.refresh()
            self?.onSearchPathsChanged?()
        }
        settings.shortcutPressed = { [weak self] in self?.showMainWindow(focusSearch: true) }
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Tests construct the model to exercise caching and persistence without
        // registering global event monitors or touching the updater.
        guard configuresSystemServices else { return }
        settings.configureSystemServices()
    }

    deinit {
    }

    // MARK: - 设置与配置

    /// The settings store owns the configuration; this forward (with the
    /// `ConfigurationOwning` conformance above it) is what keeps the views, the
    /// tests and the other stores reading and writing it the same way.
    var configuration: AppConfiguration {
        get { settings.configuration }
        set { settings.configuration = newValue }
    }
    var configurationSaveError: String? { settings.configurationSaveError }
    var isGlobalShortcutAvailable: Bool { settings.isGlobalShortcutAvailable }
    var isLaunchAtLoginEnabled: Bool { settings.isLaunchAtLoginEnabled }
    var hasConfigurationBackup: Bool { settings.hasConfigurationBackup }
    var globalShortcutDisplayName: String { settings.globalShortcutDisplayName }

    func persist() { settings.persist() }
    func toggleGlobalShortcut(_ enabled: Bool) { settings.toggleGlobalShortcut(enabled) }
    func updateGlobalShortcut(_ shortcut: GlobalShortcut) { settings.updateGlobalShortcut(shortcut) }
    func refreshGlobalShortcutPermission() { settings.refreshGlobalShortcutPermission() }
    func toggleLaunchAtLogin(_ enabled: Bool) { settings.toggleLaunchAtLogin(enabled) }
    func toggleMenuBarOnly(_ enabled: Bool) { settings.toggleMenuBarOnly(enabled) }
    func toggleAutomaticUpdateChecks(_ enabled: Bool) { settings.toggleAutomaticUpdateChecks(enabled) }
    func exportConfiguration() { settings.exportConfiguration() }
    func importConfiguration() { settings.importConfiguration() }
    func restoreConfigurationBackup() { settings.restoreConfigurationBackup() }
    func copyShellIntegrationCommand() { settings.copyShellIntegrationCommand() }
    func copyCLILinkCommand() { settings.copyCLILinkCommand() }

    /// Forwarded because the tests exercise these as pure functions.
    nonisolated static var shellIntegrationCommand: String { SettingsStore.shellIntegrationCommand }
    nonisolated static var cliExecutablePath: String { SettingsStore.cliExecutablePath }
    nonisolated static var cliLinkCommand: String { SettingsStore.cliLinkCommand }

    // MARK: - 安装列表

    /// Same forwarding contract as the stores below. `filter` stays here because the
    /// search field binds to it; the store takes the query as an argument.
    var installations: [XcodeInstallation] { installs.installations }
    var selectedID: String? { installs.selectedID }
    var activeDeveloperPath: String? { installs.activeDeveloperPath }
    var commandLineToolsPath: String { installs.commandLineToolsPath }
    var isRefreshing: Bool { installs.isRefreshing }
    var isSwitching: Bool { installs.isSwitching }
    var loadingDetailsIDs: Set<String> { installs.loadingDetailsIDs }
    var detailsByID: [String: XcodeDetails] { installs.detailsByID }
    var runtimesByID: [String: [SimulatorRuntime]] { installs.runtimesByID }
    var devicesByID: [String: [SimulatorDevice]] { installs.devicesByID }
    var runtimeDownload: RuntimeDownloadState { installs.runtimeDownload }
    var xcodeIcon: NSImage? { installs.xcodeIcon }
    var isAnyXcodeRunning: Bool { installs.isAnyXcodeRunning }
    var selectedInstallation: XcodeInstallation? { installs.selectedInstallation }
    var activeInstallation: XcodeInstallation? { installs.activeInstallation }
    var filteredInstallations: [XcodeInstallation] { installs.filteredInstallations(matching: filter) }

    /// `$installations` as a publisher, for the view that auto-selects the first
    /// installation when the list first arrives.
    var installationsPublisher: AnyPublisher<[XcodeInstallation], Never> {
        installs.$installations.eraseToAnyPublisher()
    }

    /// The shell assignment that makes one session use this Xcode. Forwarded
    /// because the tests exercise it as a pure function.
    nonisolated static func developerDirectoryExport(for installation: XcodeInstallation) -> String {
        InstallationStore.developerDirectoryExport(for: installation)
    }

    func isActive(_ installation: XcodeInstallation) -> Bool { installs.isActive(installation) }
    func refresh(silently: Bool = false) { installs.refresh(silently: silently) }
    func refreshIfStale(olderThan interval: TimeInterval = 60) {
        installs.refreshIfStale(olderThan: interval)
    }
    func icon(for installation: XcodeInstallation) -> NSImage { installs.icon(for: installation) }
    func select(_ installation: XcodeInstallation) { installs.select(installation) }
    func loadDetails(for installation: XcodeInstallation) { installs.loadDetails(for: installation) }
    func isLoadingDetails(for installation: XcodeInstallation) -> Bool {
        installs.isLoadingDetails(for: installation)
    }
    func activateSelection() { installs.activateSelection() }
    func activate(_ installation: XcodeInstallation, thenOpen project: URL? = nil, force: Bool = false) {
        installs.activate(installation, thenOpen: project, force: force)
    }
    func openSelectedXcode() { installs.openSelectedXcode() }
    func openTerminal(for installation: XcodeInstallation, directory: URL? = nil) {
        installs.openTerminal(for: installation, directory: directory)
    }
    func copyDeveloperDirectoryExport(for installation: XcodeInstallation) {
        installs.copyDeveloperDirectoryExport(for: installation)
    }
    func toggleFavorite(_ installation: XcodeInstallation) { installs.toggleFavorite(installation) }
    func isFavorite(_ installation: XcodeInstallation) -> Bool { installs.isFavorite(installation) }
    func alias(for installation: XcodeInstallation) -> String { installs.alias(for: installation) }
    func updateAlias(for installation: XcodeInstallation, value: String) {
        installs.updateAlias(for: installation, value: value)
    }
    func addSearchPath() { installs.addSearchPath() }
    func removeSearchPath(_ path: String) { installs.removeSearchPath(path) }
    func hasAvailableRuntime(for installation: XcodeInstallation) -> Bool {
        installs.hasAvailableRuntime(for: installation)
    }
    func downloadRuntime() { installs.downloadRuntime() }
    func cancelRuntimeDownload() { installs.cancelRuntimeDownload() }
    func simulatorDevices(for installation: XcodeInstallation) -> [SimulatorDevice] {
        installs.simulatorDevices(for: installation)
    }
    func performSimulatorAction(_ action: String, device: SimulatorDevice, installation: XcodeInstallation) {
        installs.performSimulatorAction(action, device: device, installation: installation)
    }
    func rollbackToPreviousXcode() { installs.rollbackToPreviousXcode() }
    func openXcodeSettings(for installation: XcodeInstallation) {
        installs.openXcodeSettings(for: installation)
    }
    func diagnostics(for installation: XcodeInstallation) -> [XcodeDiagnostic] {
        installs.diagnostics(for: installation)
    }
    func deleteUnavailableDevices(for installation: XcodeInstallation) {
        installs.deleteUnavailableDevices(for: installation)
    }
    func reloadInstalledRuntimes(for installation: XcodeInstallation) {
        installs.reloadInstalledRuntimes(for: installation)
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
