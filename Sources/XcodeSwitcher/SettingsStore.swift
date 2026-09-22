import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .simplifiedChinese: return String(localized: "简体中文")
        case .english: return "English"
        }
    }
}

/// The bundle chooses its localization before SwiftUI creates the first view, so an
/// in-app language change is stored in the standard `AppleLanguages` preference and
/// takes effect in a fresh process. A separate key distinguishes an app override from
/// the system-wide language list inherited through UserDefaults.
enum AppLanguagePreference {
    static let selectionKey = "XcodeSwitcherAppLanguage"
    static let appleLanguagesKey = "AppleLanguages"

    static func selected(in defaults: UserDefaults) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: selectionKey) else { return .system }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func apply(_ language: AppLanguage, to defaults: UserDefaults) {
        switch language {
        case .system:
            defaults.removeObject(forKey: selectionKey)
            defaults.removeObject(forKey: appleLanguagesKey)
        case .simplifiedChinese, .english:
            defaults.set(language.rawValue, forKey: selectionKey)
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
    }
}

/// The configuration and the settings built on it.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. `configuration`
/// lives here, and the model keeps a same-named forward plus its
/// `ConfigurationOwning` conformance so the views, the tests and the other stores
/// still read and write it the way they always did.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published private(set) var configurationSaveError: String?
    @Published private(set) var isGlobalShortcutAvailable = true
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var appLanguage: AppLanguage
    @Published private(set) var languageRestartRequired = false

    /// Set by `XcodeViewModel` at construction.
    weak var status: (any StatusReporting)?
    /// Saving any part of the configuration invalidates the cached project
    /// resolutions, which were computed from it.
    var configurationDidChange: () -> Void = {}
    /// Importing or restoring a configuration can change the search folders, so the
    /// app re-arms its directory monitors and re-runs discovery.
    var searchFoldersDidChange: () -> Void = {}
    /// What the global shortcut does, which is an application command.
    var shortcutPressed: () -> Void = {}
    /// The menu-bar monitor owns the displayed warning, while this store owns its
    /// configuration. Keep the one-way notification explicit rather than letting
    /// the store reach into AppKit.
    var diskSpaceWarningDidChange: () -> Void = {}
    /// Xcode-release alerts are delivered by AppKit, after this store persists
    /// the user's opt-in preference.
    var xcodeUpdateNotificationsDidChange: () -> Void = {}

    private let store: AppConfigurationStore
    private let languageDefaults: UserDefaults
    private let launchedLanguage: AppLanguage

    init(store: AppConfigurationStore = .shared, languageDefaults: UserDefaults = .standard) {
        self.store = store
        self.languageDefaults = languageDefaults
        let language = AppLanguagePreference.selected(in: languageDefaults)
        launchedLanguage = language
        appLanguage = language
        configuration = store.load()
        isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
    }

    /// Registers the global shortcut and hands the update preference to Sparkle.
    ///
    /// Separate from `init` because tests construct the model without touching
    /// either: `XcodeViewModel` only calls this when it was asked to configure
    /// system services.
    func configureSystemServices() {
        GlobalShortcutService.shared.onPressed = { [weak self] in
            Task { @MainActor in self?.shortcutPressed() }
        }
        if configuration.globalShortcutEnabled {
            isGlobalShortcutAvailable = GlobalShortcutService.shared.start(using: configuration.globalShortcut)
        }
        UpdateService.shared.setAutomaticallyChecksForUpdates(configuration.automaticallyChecksForUpdates)
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
        NSPasteboard.general.replaceContents(with: Self.shellIntegrationCommand)
        status?.statusMessage = String(localized: "已复制 Shell 集成命令，请添加到 ~/.zshrc。")
        status?.isError = false
    }

    func copyCLILinkCommand() {
        NSPasteboard.general.replaceContents(with: Self.cliLinkCommand)
        status?.statusMessage = String(localized: "已复制 CLI 链接命令。")
        status?.isError = false
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
            status?.statusMessage = isLaunchAtLoginEnabled ? String(localized: "已启用登录时启动。") : String(localized: "已关闭登录时启动。")
            status?.isError = false
        } catch {
            isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
            status?.statusMessage = String(localized: "无法修改登录项：\(error.localizedDescription)")
            status?.isError = true
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

    func toggleDiskSpaceWarning(_ enabled: Bool) {
        configuration.diskSpaceWarningEnabled = enabled
        persist()
        diskSpaceWarningDidChange()
    }

    func updateDiskSpaceWarningThreshold(_ thresholdGB: Int) {
        configuration.diskSpaceWarningThresholdGB = DiskSpaceMonitor.normalizedThresholdGB(thresholdGB)
        persist()
        diskSpaceWarningDidChange()
    }

    func toggleXcodeUpdateNotifications(_ enabled: Bool) {
        configuration.xcodeUpdateNotificationsEnabled = enabled
        persist()
        xcodeUpdateNotificationsDidChange()
    }

    func selectAppLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        AppLanguagePreference.apply(language, to: languageDefaults)
        appLanguage = language
        languageRestartRequired = language != launchedLanguage
        status?.statusMessage = languageRestartRequired
            ? String(localized: "语言设置已保存，重新启动 App 后生效。")
            : String(localized: "已恢复当前语言设置。")
        status?.isError = false
    }

    func restartToApplyLanguage() {
        guard languageRestartRequired else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.status?.statusMessage = String(localized: "重新启动失败：\(error.localizedDescription)")
                    self?.status?.isError = true
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xcode-switcher-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(configuration, to: url)
            status?.statusMessage = String(localized: "配置已导出。")
            status?.isError = false
        } catch { status?.statusMessage = String(localized: "导出失败：\(error.localizedDescription)"); status?.isError = true }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            configuration = try store.import(from: url)
            persist()
            searchFoldersDidChange()
            diskSpaceWarningDidChange()
            xcodeUpdateNotificationsDidChange()
            status?.statusMessage = String(localized: "配置已导入。")
            status?.isError = false
        } catch { status?.statusMessage = String(localized: "导入失败：\(error.localizedDescription)"); status?.isError = true }
    }

    var hasConfigurationBackup: Bool { store.hasBackup }

    func restoreConfigurationBackup() {
        do {
            configuration = try store.restoreBackup()
            searchFoldersDidChange()
            diskSpaceWarningDidChange()
            xcodeUpdateNotificationsDidChange()
            status?.statusMessage = String(localized: "已恢复上次配置备份。")
            status?.isError = false
        } catch {
            status?.statusMessage = String(localized: "恢复配置失败：\(error.localizedDescription)")
            status?.isError = true
        }
    }

    func persist() {
        configurationDidChange()
        do {
            try store.save(configuration)
            configurationSaveError = nil
        } catch {
            // Losing an alias or project binding silently is worse than a visible
            // error, so keep it on screen until a later save succeeds.
            configurationSaveError = error.localizedDescription
            status?.statusMessage = String(localized: "配置保存失败：\(error.localizedDescription)")
            status?.isError = true
        }
    }
}
