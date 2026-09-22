import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// The installed Xcodes and everything done to one of them.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. It is the
/// largest store, and its dependencies are held to four: reporting
/// (`StatusReporting`), the configuration and its persistence
/// (`ConfigurationOwning`, one protocol rather than a closure per key), and two
/// cross-domain callbacks — the rest of the app reloads itself after a refresh or
/// a selection, and the app re-arms its directory monitors after the search
/// folders change. Nothing here reaches back into `XcodeViewModel`.
@MainActor
final class InstallationStore: ObservableObject {
    @Published private(set) var installations: [XcodeInstallation] = []
    @Published var selectedID: String?
    @Published private(set) var activeDeveloperPath: String?
    @Published private(set) var commandLineToolsPath = String(localized: "检测中…")
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var loadingDetailsIDs: Set<String> = []
    @Published private(set) var detailsByID: [String: XcodeDetails] = [:]
    @Published private(set) var runtimesByID: [String: [SimulatorRuntime]] = [:]
    @Published private(set) var devicesByID: [String: [SimulatorDevice]] = [:]
    /// Only needed while the creation form is open, so it is fetched then rather than on
    /// every refresh.
    @Published private(set) var deviceTypesByID: [String: [SimulatorDeviceType]] = [:]

    /// Deliberately not `@Published`: only the runtime section observes it, so the
    /// download progress does not republish the whole view model.
    let runtimeDownload = RuntimeDownloadState()

    /// Set by `XcodeViewModel` at construction.
    weak var status: (any StatusReporting)?
    weak var owner: (any ConfigurationOwning)?
    var didRefresh: () -> Void = {}
    var reloadSelected: (XcodeInstallation?) -> Void = { _ in }
    var searchPathsDidChange: () -> Void = {}

    private var refreshTask: Task<Void, Never>?
    private var usesUITestFixture = false
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var runtimeDownloadTask: Task<Void, Never>?
    /// `NSWorkspace.icon(forFile:)` goes through LaunchServices, so the result is
    /// cached instead of being re-fetched on every row render.
    private var iconCache: [String: NSImage] = [:]
    private var lastRefreshAt: Date?

    /// Cancelled here rather than from the model's `deinit`, which is nonisolated
    /// and so cannot call into this actor.
    deinit {
        refreshTask?.cancel()
        detailTasks.values.forEach { $0.cancel() }
        runtimeDownloadTask?.cancel()
    }


    func deleteUnavailableDevices(for installation: XcodeInstallation) {
        let unavailable = simulatorDevices(for: installation).filter { !$0.isAvailable }.count
        guard unavailable > 0 else { return }
        status?.isError = false
        status?.statusMessage = String(localized: "正在删除 \(unavailable) 个不可用 Simulator 设备…")
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let actionResult = XcodeTooling.deleteUnavailableDevices(for: installation)
                let devices = actionResult.succeeded ? XcodeTooling.simulatorDevices(for: installation) : nil
                return (actionResult, devices)
            }.value
            guard let self else { return }
            if result.0.succeeded {
                if let devices = result.1 { devicesByID[installation.id] = devices }
                status?.isError = false
                status?.statusMessage = String(localized: "已删除 \(unavailable) 个不可用 Simulator 设备。")
            } else {
                status?.isError = true
                status?.statusMessage = String(localized: "Simulator 操作失败：\(result.0.failureDescription)")
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

    var selectedInstallation: XcodeInstallation? {
        installations.first { $0.id == selectedID }
    }

    var activeInstallation: XcodeInstallation? {
        installations.first { $0.developerURL.path == activeDeveloperPath }
    }

    func isActive(_ installation: XcodeInstallation) -> Bool {
        installation.developerURL.path == activeDeveloperPath
    }

    func filteredInstallations(matching filter: String) -> [XcodeInstallation] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return installations }
        return installations.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.displayVersion.localizedCaseInsensitiveContains(query) ||
            $0.appURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh(silently: Bool = false) {
        // The UI suite supplies deterministic installations. Ignore every refresh
        // trigger (including status-menu callbacks) so a host Xcode cannot replace
        // that fixture while a destructive confirmation path is under test.
        guard !usesUITestFixture else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        if !silently { status?.statusMessage = String(localized: "正在扫描本机安装的 Xcode…") }
        let searchPaths = owner?.configuration.customSearchPaths ?? []
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
            didRefresh()
            iconCache.removeAll()
            lastRefreshAt = Date()
            if !installations.contains(where: { $0.id == selectedID }) {
                selectedID = installations.first(where: { $0.developerURL.path == activeDeveloperPath })?.id ?? installations.first?.id
            }
            isRefreshing = false
            status?.isError = installations.isEmpty
            if !silently || installations.isEmpty {
                status?.statusMessage = installations.isEmpty ? String(localized: "未发现 Xcode.app。") : String(localized: "已发现 \(installations.count) 个 Xcode。")
            }
            reloadSelected(selectedInstallation)
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
        reloadSelected(installation)
    }

    /// Supplies deterministic data for the shipped-app UI tests without starting
    /// discovery or the per-installation background loaders.
    func replaceInstallationsForUITesting(
        _ installations: [XcodeInstallation],
        activeDeveloperPath: String?
    ) {
        usesUITestFixture = true
        self.installations = installations
        selectedID = installations.first?.id
        self.activeDeveloperPath = activeDeveloperPath
        commandLineToolsPath = activeDeveloperPath ?? String(localized: "未检测到")
    }

    var isAnyXcodeRunning: Bool {
        !XcodeProcessInspector.runningInstallations(among: installations).isEmpty
    }


    /// The Xcode app icon, taken from a locally installed copy.
    ///
    /// Deliberately read from the user's own installation rather than shipped in the
    /// bundle: the icon is Apple's artwork, and this app has always shown it by asking
    /// the local bundle (the installed list and the detail header both do). Nil when no
    /// Xcode is installed at all, where the version list falls back to a symbol.
    var xcodeIcon: NSImage? {
        installations.first.map { icon(for: $0) }
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
            status?.statusMessage = String(localized: "所选 Xcode 已处于激活状态。")
            if let project { XcodeActions.open(project, with: installation) }
            return
        }
        guard !isSwitching else { return }
        if !force, let running = Self.runningXcodeDescription(among: installations) {
            guard Self.confirmSwitchWhileXcodeRuns(running) else {
                status?.statusMessage = String(localized: "已取消切换。")
                return
            }
        }
        if let activeInstallation {
            recordActivation(activeInstallation)
        }
        isSwitching = true
        status?.isError = false
        status?.statusMessage = String(localized: "正在请求管理员授权…")
        let switchLog = AppLog.logger(.switching)
        switchLog.info("switch requested: \(installation.developerURL.path, privacy: .public) (was \(self.activeDeveloperPath ?? "none", privacy: .public))")
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
                status?.isError = true
                status?.statusMessage = String(localized: "切换失败：\(errorMessage)")
                switchLog.error("switch failed: \(errorMessage, privacy: .public)")
                return
            }
            activeDeveloperPath = XcodeLocator.activeDeveloperPath()
            let verified = activeDeveloperPath == installation.developerURL.path
            status?.isError = !verified
            status?.statusMessage = verified ? String(localized: "已激活并验证 Xcode \(installation.displayVersion)。") : String(localized: "切换命令完成，但未能验证当前开发者目录。")
            if verified {
                switchLog.notice("switch verified: \(installation.developerURL.path, privacy: .public)")
                recordActivation(installation)
            } else {
                switchLog.error("switch not verified: xcode-select reports \(self.activeDeveloperPath ?? "none", privacy: .public), expected \(installation.developerURL.path, privacy: .public)")
            }
            if let project, verified { XcodeActions.open(project, with: installation) }
        }
    }

    func openSelectedXcode() {
        guard let selectedInstallation, XcodeActions.openXcode(selectedInstallation) else {
            status?.statusMessage = String(localized: "无法打开所选 Xcode。")
            status?.isError = true
            return
        }
        status?.statusMessage = String(localized: "已打开 Xcode \(selectedInstallation.displayVersion)。")
        status?.isError = false
    }

    func openTerminal(for installation: XcodeInstallation, directory: URL? = nil) {
        let target = directory ?? FileManager.default.homeDirectoryForCurrentUser
        let success = XcodeActions.openTerminal(at: target, developerPath: installation.developerURL.path)
        status?.isError = !success
        status?.statusMessage = success ? String(localized: "已打开终端，DEVELOPER_DIR 指向 Xcode \(installation.displayVersion)。") : String(localized: "无法打开终端。")
    }

    /// The shell assignment that makes one session use this Xcode without
    /// changing the system-wide developer directory, and therefore without
    /// administrator authorization.
    nonisolated static func developerDirectoryExport(for installation: XcodeInstallation) -> String {
        ProjectEnvironmentOutput.exportDeveloperDirectory(installation.developerURL.path).shellSource
    }

    func copyDeveloperDirectoryExport(for installation: XcodeInstallation) {
        NSPasteboard.general.replaceContents(with: Self.developerDirectoryExport(for: installation))
        status?.statusMessage = String(localized: "已复制 export 命令。粘贴到终端即可让该会话使用 Xcode \(installation.displayVersion)，不会修改系统设置。")
        status?.isError = false
    }

    func toggleFavorite(_ installation: XcodeInstallation) {
        if owner?.configuration.favoriteIDs.contains(installation.id) == true {
            owner?.configuration.favoriteIDs.remove(installation.id)
        } else {
            owner?.configuration.favoriteIDs.insert(installation.id)
        }
        owner?.persist()
    }

    func isFavorite(_ installation: XcodeInstallation) -> Bool {
        owner?.configuration.favoriteIDs.contains(installation.id) == true
    }

    func alias(for installation: XcodeInstallation) -> String {
        owner?.configuration.xcodeAliases[installation.id] ?? ""
    }

    func updateAlias(for installation: XcodeInstallation, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            owner?.configuration.xcodeAliases.removeValue(forKey: installation.id)
        } else {
            owner?.configuration.xcodeAliases[installation.id] = trimmed
        }
        owner?.persist()
    }




    func addSearchPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !(owner?.configuration.customSearchPaths.contains(url.path) ?? false) {
                owner?.configuration.customSearchPaths.append(url.path)
            }
            owner?.persist()
            refresh()
            searchPathsDidChange()
        }
    }

    func removeSearchPath(_ path: String) {
        owner?.configuration.customSearchPaths.removeAll { $0 == path }
        owner?.persist()
        refresh()
        searchPathsDidChange()
    }

    /// Whether this installation already has an available runtime for `platform`.
    ///
    /// For iOS the installed runtime is additionally checked against the iPhoneOS SDK
    /// version, as before. For the other platforms the SDK version of the *iOS* platform
    /// says nothing about them, so "any available runtime of this platform" is the
    /// honest answer.
    func hasAvailableRuntime(for installation: XcodeInstallation, platform: SimulatorPlatform = .iOS) -> Bool {
        guard let runtimes = runtimesByID[installation.id] else { return false }
        let matching = runtimes.filter { $0.isAvailable && platform.owns(runtimeIdentifier: $0.id) }
        guard platform == .iOS,
              let sdkVersion = detailsByID[installation.id]?.sdkVersion,
              !sdkVersion.isEmpty,
              sdkVersion != XcodeDetails.unknownValue else {
            return !matching.isEmpty
        }
        return matching.contains { $0.version == sdkVersion }
    }

    func downloadRuntime(platform: SimulatorPlatform = .iOS) {
        guard let installation = selectedInstallation, !runtimeDownload.isDownloading else { return }
        if hasAvailableRuntime(for: installation, platform: platform) {
            status?.statusMessage = String(localized: "当前 Xcode 已有可用的 \(platform.displayName) Simulator Runtime。")
            status?.isError = false
            return
        }
        runtimeDownload.begin(String(localized: "正在准备下载…"))
        status?.statusMessage = String(localized: "正在下载 \(platform.displayName) Simulator Runtime…")
        AppLog.logger(.runtime).info(
            "\(platform.rawValue, privacy: .public) runtime download requested for \(installation.id, privacy: .public)"
        )
        runtimeDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = XcodeTooling.downloadRuntime(for: platform, installation: installation) { output in
                let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                Task { @MainActor in self.runtimeDownload.update(message) }
            }
            let runtimes = result.succeeded ? XcodeTooling.simulatorRuntimes(for: installation) : nil
            await self.completeRuntimeDownload(result: result, runtimes: runtimes, installationID: installation.id, platform: platform)
        }
    }

    func cancelRuntimeDownload() {
        runtimeDownload.update(String(localized: "正在取消…"))
        runtimeDownloadTask?.cancel()
    }

    func simulatorDevices(for installation: XcodeInstallation) -> [SimulatorDevice] {
        devicesByID[installation.id] ?? []
    }

    /// Runs one `simctl` mutation and reloads the device list when it worked.
    ///
    /// The messages are passed in whole rather than assembled from a verb: injecting
    /// 「克隆」 into a shared template (「正在%@ Simulator %@…」) cannot be translated,
    /// because English needs a progressive form ("Cloning…") that the imperative button
    /// label ("Clone") cannot supply.
    private func mutateSimulatorDevices(
        start: String,
        success: String,
        installation: XcodeInstallation,
        operation: @escaping @Sendable () -> ProcessResult
    ) {
        status?.statusMessage = start
        status?.isError = false
        Task { @MainActor in
            let outcome = await Task.detached(priority: .utility) {
                let result = operation()
                let devices = result.succeeded ? XcodeTooling.simulatorDevices(for: installation) : nil
                return (result, devices)
            }.value
            if outcome.0.succeeded {
                if let devices = outcome.1 { devicesByID[installation.id] = devices }
                status?.statusMessage = success
            } else {
                status?.isError = true
                status?.statusMessage = String(localized: "Simulator 操作失败：\(outcome.0.failureDescription)")
            }
        }
    }

    func performSimulatorAction(_ action: String, device: SimulatorDevice, installation: XcodeInstallation) {
        guard ["boot", "shutdown", "erase", "delete"].contains(action) else { return }
        // A `switch` expression may only be the source of an assignment, so it is bound
        // to a local before being passed on.
        let start = switch action {
        case "boot":
            String(localized: "正在启动 Simulator \(device.name)…")
        case "shutdown":
            String(localized: "正在关闭 Simulator \(device.name)…")
        case "delete":
            String(localized: "正在删除 Simulator \(device.name)…")
        default:
            String(localized: "正在抹掉 Simulator \(device.name)…")
        }
        mutateSimulatorDevices(
            start: start,
            success: String(localized: "Simulator \(device.name) 操作完成。"),
            installation: installation
        ) {
            XcodeTooling.simulatorAction(action, device: device, installation: installation)
        }
    }

    /// A copy of an existing device. It gets its own UDID, so the original is untouched.
    func cloneSimulatorDevice(_ device: SimulatorDevice, newName: String, installation: XcodeInstallation) {
        mutateSimulatorDevices(
            start: String(localized: "正在克隆 Simulator \(device.name)…"),
            success: String(localized: "已克隆为 \(newName)。"),
            installation: installation
        ) {
            XcodeTooling.cloneSimulatorDevice(device, newName: newName, installation: installation)
        }
    }

    func renameSimulatorDevice(_ device: SimulatorDevice, newName: String, installation: XcodeInstallation) {
        mutateSimulatorDevices(
            start: String(localized: "正在重命名 Simulator \(device.name)…"),
            success: String(localized: "已重命名为 \(newName)。"),
            installation: installation
        ) {
            XcodeTooling.renameSimulatorDevice(device, newName: newName, installation: installation)
        }
    }

    func createSimulatorDevice(
        name: String,
        deviceType: SimulatorDeviceType,
        runtime: SimulatorRuntime,
        installation: XcodeInstallation
    ) {
        mutateSimulatorDevices(
            start: String(localized: "正在创建 Simulator \(name)…"),
            success: String(localized: "已创建 Simulator \(name)。"),
            installation: installation
        ) {
            XcodeTooling.createSimulatorDevice(
                name: name,
                deviceTypeID: deviceType.id,
                runtimeID: runtime.id,
                installation: installation
            )
        }
    }

    /// Device types are only needed while the creation form is open.
    func loadSimulatorDeviceTypes(for installation: XcodeInstallation) {
        guard deviceTypesByID[installation.id] == nil else { return }
        Task { @MainActor in
            let types = await Task.detached(priority: .utility) {
                XcodeTooling.simulatorDeviceTypes(for: installation)
            }.value
            deviceTypesByID[installation.id] = types
        }
    }

    func simulatorDeviceTypes(for installation: XcodeInstallation) -> [SimulatorDeviceType] {
        deviceTypesByID[installation.id] ?? []
    }

    func rollbackToPreviousXcode() {
        let candidates = (owner?.configuration.activationHistory ?? []).compactMap { id in
            installations.first { $0.id == id }
        }
        guard let previous = candidates.first(where: { !isActive($0) }) else {
            status?.statusMessage = String(localized: "没有可回滚的上一个 Xcode。")
            status?.isError = true
            return
        }
        activate(previous)
    }

    private func recordActivation(_ installation: XcodeInstallation) {
        owner?.configuration.activationHistory.removeAll { $0 == installation.id }
        owner?.configuration.activationHistory.insert(installation.id, at: 0)
        owner?.configuration.activationHistory = Array((owner?.configuration.activationHistory ?? []).prefix(10))
        owner?.persist()
    }

    private func completeRuntimeDownload(
        result: ProcessResult,
        runtimes: [SimulatorRuntime]?,
        installationID: String,
        platform: SimulatorPlatform
    ) {
        runtimeDownloadTask = nil
        status?.isError = !result.succeeded && !result.cancelled
        let downloadLog = AppLog.logger(.runtime)
        if result.succeeded {
            downloadLog.notice("\(platform.rawValue, privacy: .public) runtime download finished for \(installationID, privacy: .public)")
            status?.statusMessage = String(localized: "\(platform.displayName) Simulator Runtime 下载命令已完成。")
            runtimeDownload.finish(String(localized: "下载完成"))
        } else if result.cancelled {
            downloadLog.notice("\(platform.rawValue, privacy: .public) runtime download cancelled for \(installationID, privacy: .public)")
            status?.statusMessage = String(localized: "已取消 \(platform.displayName) Simulator Runtime 下载。")
            runtimeDownload.finish(String(localized: "已取消"))
        } else {
            downloadLog.error("\(platform.rawValue, privacy: .public) runtime download failed for \(installationID, privacy: .public): \(result.failureDescription, privacy: .public)")
            status?.statusMessage = String(localized: "下载失败：\(result.failureDescription)")
            runtimeDownload.finish(result.failureDescription)
        }
        if let runtimes { runtimesByID[installationID] = runtimes }
    }

    func openXcodeSettings(for installation: XcodeInstallation) {
        status?.statusMessage = String(localized: "已打开 \(installation.name)，正在显示 Xcode Settings…")
        status?.isError = false
        // The menu automation runs a second later and can fail (missing
        // Accessibility permission, unexpected menu layout), so the result is
        // reported instead of leaving the user guessing.
        XcodeActions.openXcodeSettings(for: installation) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.status?.statusMessage = String(localized: "已在 \(installation.name) 中打开 Settings。")
                    self.status?.isError = false
                case let .failure(error):
                    self.status?.statusMessage = error.errorDescription ?? String(localized: "无法打开 Xcode Settings。")
                    self.status?.isError = true
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
}
