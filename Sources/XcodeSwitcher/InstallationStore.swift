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
                return
            }
            activeDeveloperPath = XcodeLocator.activeDeveloperPath()
            let verified = activeDeveloperPath == installation.developerURL.path
            status?.isError = !verified
            status?.statusMessage = verified ? String(localized: "已激活并验证 Xcode \(installation.displayVersion)。") : String(localized: "切换命令完成，但未能验证当前开发者目录。")
            if verified {
                recordActivation(installation)
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
            status?.statusMessage = String(localized: "当前 Xcode 已有可用的 iOS Simulator Runtime。")
            status?.isError = false
            return
        }
        runtimeDownload.begin("正在准备下载…")
        status?.statusMessage = String(localized: "正在下载 iOS Simulator Runtime…")
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
        status?.statusMessage = switch action {
        case "boot":
            String(localized: "正在启动 Simulator \(device.name)…")
        case "shutdown":
            String(localized: "正在关闭 Simulator \(device.name)…")
        case "delete":
            String(localized: "正在删除 Simulator \(device.name)…")
        default:
            String(localized: "正在抹掉 Simulator \(device.name)…")
        }
        status?.isError = false
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                let actionResult = XcodeTooling.simulatorAction(action, device: device, installation: installation)
                let devices = actionResult.succeeded ? XcodeTooling.simulatorDevices(for: installation) : nil
                return (actionResult, devices)
            }.value
            if result.0.succeeded {
                if let devices = result.1 { devicesByID[installation.id] = devices }
                status?.statusMessage = String(localized: "Simulator \(device.name) 操作完成。")
            } else {
                status?.isError = true
                status?.statusMessage = String(localized: "Simulator 操作失败：\(result.0.failureDescription)")
            }
        }
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

    private func completeRuntimeDownload(result: ProcessResult, runtimes: [SimulatorRuntime]?, installationID: String) {
        runtimeDownloadTask = nil
        status?.isError = !result.succeeded && !result.cancelled
        if result.succeeded {
            status?.statusMessage = String(localized: "iOS Simulator Runtime 下载命令已完成。")
            runtimeDownload.finish("下载完成")
        } else if result.cancelled {
            status?.statusMessage = String(localized: "已取消 iOS Simulator Runtime 下载。")
            runtimeDownload.finish("已取消")
        } else {
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
