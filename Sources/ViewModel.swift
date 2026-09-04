import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class XcodeViewModel: ObservableObject {
    @Published private(set) var installations: [XcodeInstallation] = []
    @Published var selectedID: String?
    @Published private(set) var activeDeveloperPath: String?
    @Published private(set) var commandLineToolsPath = "检测中…"
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var loadingDetailsIDs: Set<String> = []
    @Published private(set) var isDownloadingRuntime = false
    @Published private(set) var runtimeDownloadProgress = ""
    @Published private(set) var environmentReportsByID: [String: EnvironmentReport] = [:]
    @Published private(set) var environmentDoctorRunningIDs: Set<String> = []
    @Published private(set) var isGlobalShortcutAvailable = true
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var detailsByID: [String: XcodeDetails] = [:]
    @Published private(set) var runtimesByID: [String: [SimulatorRuntime]] = [:]
    @Published private(set) var signingCertificates: [SigningCertificate] = []
    @Published private(set) var provisioningProfiles: [ProvisioningProfile] = []
    @Published private(set) var signingReport: ProjectSigningReport?
    @Published private(set) var isRefreshingSigning = false
    @Published private(set) var isLoadingSigningReport = false
    @Published var configuration: AppConfiguration
    @Published var statusMessage = "正在扫描本机安装的 Xcode…"
    @Published var isError = false
    @Published var filter = ""
    @Published private(set) var searchFocusRequest = 0

    private let store = AppConfigurationStore.shared
    private var refreshTask: Task<Void, Never>?
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var runtimeDownloadTask: Task<Void, Never>?
    private var signingReportTask: Task<Void, Never>?
    private var environmentDoctorTasks: [String: Task<Void, Never>] = [:]

    init() {
        configuration = store.load()
        isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
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
        if !silently { statusMessage = "正在扫描本机安装的 Xcode…" }
        let searchPaths = configuration.customSearchPaths
        refreshTask?.cancel()
        refreshTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                (
                    XcodeLocator.discover(searchPaths: searchPaths),
                    XcodeLocator.activeDeveloperPath(),
                    XcodeLocator.commandLineToolsPath()
                )
            }.value
            guard !Task.isCancelled else { return }
            installations = snapshot.0
            activeDeveloperPath = snapshot.1
            commandLineToolsPath = snapshot.2
            if !installations.contains(where: { $0.id == selectedID }) {
                selectedID = installations.first(where: { $0.developerURL.path == activeDeveloperPath })?.id ?? installations.first?.id
            }
            isRefreshing = false
            isError = installations.isEmpty
            if !silently || installations.isEmpty {
                statusMessage = installations.isEmpty ? "未发现 Xcode.app。" : "已发现 \(installations.count) 个 Xcode。"
            }
            if let selectedInstallation { loadDetails(for: selectedInstallation) }
        }
    }

    func select(_ installation: XcodeInstallation) {
        selectedID = installation.id
        loadDetails(for: installation)
    }

    func loadDetails(for installation: XcodeInstallation) {
        guard detailsByID[installation.id] == nil, detailTasks[installation.id] == nil else { return }
        loadingDetailsIDs.insert(installation.id)
        detailTasks[installation.id] = Task.detached(priority: .utility) { [weak self] in
            let result = (XcodeTooling.details(for: installation), XcodeTooling.simulatorRuntimes(for: installation))
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

    private func completeDetailsLoad(for id: String, result: (XcodeDetails, [SimulatorRuntime])?) {
        if let result {
            detailsByID[id] = result.0
            runtimesByID[id] = result.1
        }
        loadingDetailsIDs.remove(id)
        detailTasks[id] = nil
    }

    func activateSelection() {
        guard let installation = selectedInstallation else { return }
        activate(installation)
    }

    func activate(_ installation: XcodeInstallation, thenOpen project: URL? = nil) {
        if installation.developerURL.path == activeDeveloperPath {
            statusMessage = "所选 Xcode 已处于激活状态。"
            if let project { XcodeActions.open(project, with: installation) }
            return
        }
        guard !isSwitching else { return }
        isSwitching = true
        isError = false
        statusMessage = "正在请求管理员授权…"
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
                statusMessage = "切换失败：\(errorMessage)"
                return
            }
            activeDeveloperPath = XcodeLocator.activeDeveloperPath()
            let verified = activeDeveloperPath == installation.developerURL.path
            isError = !verified
            statusMessage = verified ? "已激活并验证 Xcode \(installation.displayVersion)。" : "切换命令完成，但未能验证当前开发者目录。"
            if let project, verified { XcodeActions.open(project, with: installation) }
        }
    }

    func openSelectedXcode() {
        guard let selectedInstallation, XcodeActions.openXcode(selectedInstallation) else {
            statusMessage = "无法打开所选 Xcode。"
            isError = true
            return
        }
        statusMessage = "已打开 Xcode \(selectedInstallation.displayVersion)。"
        isError = false
    }

    func openTerminal(for installation: XcodeInstallation, directory: URL? = nil) {
        let target = directory ?? FileManager.default.homeDirectoryForCurrentUser
        let success = XcodeActions.openTerminal(at: target, developerPath: installation.developerURL.path)
        isError = !success
        statusMessage = success ? "已打开终端，DEVELOPER_DIR 指向 Xcode \(installation.displayVersion)。" : "无法打开终端。"
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
            statusMessage = "请选择 .xcodeproj 或 .xcworkspace。"
            isError = true
            return
        }
        guard !configuration.projects.contains(where: { $0.path == url.path }) else {
            statusMessage = "该项目已经添加。"
            isError = false
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "项目路径不存在：\(url.path)"
            isError = true
            return
        }
        let profile = ProjectProfile(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        configuration.projects.append(profile)
        persist()
        if let match = automaticMatch(for: profile) {
            isError = !match.isInstalled
            statusMessage = match.isInstalled
                ? "已添加项目 \(profile.name)，自动匹配 Xcode \(match.requirement.normalizedVersion)。"
                : "已添加项目 \(profile.name)，但未安装其要求的 Xcode \(match.requirement.normalizedVersion)。"
        } else {
            statusMessage = "已添加项目 \(profile.name)。"
            isError = false
        }
    }

    func removeProject(_ profile: ProjectProfile) {
        configuration.projects.removeAll { $0.id == profile.id }
        persist()
    }

    func updateProject(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        guard let index = configuration.projects.firstIndex(where: { $0.id == profile.id }) else { return }
        configuration.projects[index].name = name
        configuration.projects[index].xcodeID = xcodeID
        persist()
    }

    func installation(for profile: ProjectProfile) -> XcodeInstallation? {
        let resolution = projectResolution(for: profile)
        return resolution.installationID.flatMap { id in installations.first(where: { $0.id == id }) }
    }

    func applyAndOpen(_ profile: ProjectProfile) {
        if let issue = projectIssue(for: profile) {
            statusMessage = issue
            isError = true
            return
        }
        guard let installation = installation(for: profile) else {
            statusMessage = "没有可用于打开项目的 Xcode。"
            isError = true
            return
        }
        activate(installation, thenOpen: profile.url)
    }

    func automaticMatch(for profile: ProjectProfile) -> ProjectXcodeMatch? {
        ProjectXcodeMatcher.match(
            projectURL: profile.url,
            installations: installations,
            aliases: configuration.xcodeAliases
        )
    }

    func projectIssue(for profile: ProjectProfile) -> String? {
        projectResolution(for: profile).issueDescription
    }

    private func projectResolution(for profile: ProjectProfile) -> ProjectXcodeResolution {
        ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: installations,
            aliases: configuration.xcodeAliases,
            activeInstallationID: activeInstallation?.id
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
        }
    }

    func removeSearchPath(_ path: String) {
        configuration.customSearchPaths.removeAll { $0 == path }
        persist()
        refresh()
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
        UpdateService.shared.configurationError ?? "Sparkle 自动更新已启用。"
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
            configuration.launchAtLoginEnabled = isLaunchAtLoginEnabled
            persist()
            statusMessage = isLaunchAtLoginEnabled ? "已启用登录时启动。" : "已关闭登录时启动。"
            isError = false
        } catch {
            isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
            statusMessage = "无法修改登录项：\(error.localizedDescription)"
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
        guard UpdateService.shared.isAvailable else {
            statusMessage = UpdateService.shared.configurationError ?? "当前构建未启用自动更新。"
            isError = true
            return
        }
        UpdateService.shared.checkForUpdates()
        statusMessage = "正在检查更新…"
        isError = false
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xcode-switcher-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(configuration, to: url)
            statusMessage = "配置已导出。"
            isError = false
        } catch { statusMessage = "导出失败：\(error.localizedDescription)"; isError = true }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            configuration = try store.import(from: url)
            persist()
            refresh()
            statusMessage = "配置已导入。"
            isError = false
        } catch { statusMessage = "导入失败：\(error.localizedDescription)"; isError = true }
    }

    func hasAvailableRuntime(for installation: XcodeInstallation) -> Bool {
        guard let runtimes = runtimesByID[installation.id] else { return false }
        if let sdkVersion = detailsByID[installation.id]?.sdkVersion,
           !sdkVersion.isEmpty,
           sdkVersion != "未知" {
            return runtimes.contains { $0.isAvailable && $0.version == sdkVersion }
        }
        return runtimes.contains(where: { $0.isAvailable })
    }

    func downloadRuntime() {
        guard let installation = selectedInstallation, !isDownloadingRuntime else { return }
        if hasAvailableRuntime(for: installation) {
            statusMessage = "当前 Xcode 已有可用的 iOS Simulator Runtime。"
            isError = false
            return
        }
        isDownloadingRuntime = true
        runtimeDownloadProgress = "正在准备下载…"
        statusMessage = "正在下载 iOS Simulator Runtime…"
        runtimeDownloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = XcodeTooling.downloadIOSRuntime(for: installation) { output in
                let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                Task { @MainActor in self.runtimeDownloadProgress = message }
            }
            let runtimes = result.succeeded ? XcodeTooling.simulatorRuntimes(for: installation) : nil
            await self.completeRuntimeDownload(result: result, runtimes: runtimes, installationID: installation.id)
        }
    }

    func cancelRuntimeDownload() {
        runtimeDownloadProgress = "正在取消…"
        runtimeDownloadTask?.cancel()
    }

    private func completeRuntimeDownload(result: ProcessResult, runtimes: [SimulatorRuntime]?, installationID: String) {
        isDownloadingRuntime = false
        runtimeDownloadTask = nil
        isError = !result.succeeded && !result.cancelled
        if result.succeeded {
            statusMessage = "iOS Simulator Runtime 下载命令已完成。"
            runtimeDownloadProgress = "下载完成"
        } else if result.cancelled {
            statusMessage = "已取消 iOS Simulator Runtime 下载。"
            runtimeDownloadProgress = "已取消"
        } else {
            statusMessage = "下载失败：\(result.failureDescription)"
            runtimeDownloadProgress = result.failureDescription
        }
        if let runtimes { runtimesByID[installationID] = runtimes }
    }

    func openXcodeSettings(for installation: XcodeInstallation) {
        let opened = XcodeActions.openXcodeSettings(for: installation)
        isError = !opened
        statusMessage = opened
            ? "已打开 \(installation.name)，正在显示 Xcode Settings。"
            : "无法打开 \(installation.name)。"
    }

    func diagnostics(for installation: XcodeInstallation) -> [XcodeDiagnostic] {
        let details = detailsByID[installation.id]
        return [
            XcodeDiagnostic(title: "应用路径", value: installation.appURL.path, isWarning: false),
            XcodeDiagnostic(title: "Developer 路径", value: installation.developerURL.path, isWarning: false),
            XcodeDiagnostic(title: "当前激活", value: installation.developerURL.path == activeDeveloperPath ? "是" : "否", isWarning: installation.developerURL.path != activeDeveloperPath),
            XcodeDiagnostic(title: "iPhoneOS SDK", value: details?.sdkVersion ?? "检测中…", isWarning: false),
            XcodeDiagnostic(title: "Swift", value: details?.swiftVersion ?? "检测中…", isWarning: false),
            XcodeDiagnostic(title: "xcode-select 当前路径", value: commandLineToolsPath, isWarning: false)
        ]
    }

    func runEnvironmentDoctor(for installation: XcodeInstallation) {
        guard environmentDoctorTasks[installation.id] == nil else { return }
        environmentDoctorRunningIDs.insert(installation.id)
        statusMessage = "正在体检 Xcode \(installation.displayVersion)…"
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
        statusMessage = "环境诊断报告已复制。"
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
            statusMessage = "环境诊断报告已导出。"
            isError = false
        } catch {
            statusMessage = "报告导出失败：\(error.localizedDescription)"
            isError = true
        }
    }

    private func completeEnvironmentDoctor(for id: String, report: EnvironmentReport?) {
        if let report {
            environmentReportsByID[id] = report
            isError = report.highestSeverity == .error
            statusMessage = report.issueCount == 0
                ? "环境体检完成，未发现问题。"
                : "环境体检完成，发现 \(report.issueCount) 项需要关注。"
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
            statusMessage = "公钥证书已导出并在 Finder 中显示。"
            isError = false
        } catch {
            statusMessage = "证书导出失败：\(error.localizedDescription)"
            isError = true
        }
    }

    func openKeychainAccess() {
        if SigningService.openKeychainAccess() {
            statusMessage = "已打开钥匙串访问。"
            isError = false
        } else {
            statusMessage = "无法打开钥匙串访问。"
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

    func persist() { store.save(configuration) }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func showMainWindow(focusSearch: Bool = false) {
        AppDelegate.shared?.presentMainWindow(focusSearch: focusSearch)
    }
}
