import AppKit
import Combine
import SwiftUI
import XcodeSwitcherKit

@main
struct XcodeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Xcode Switcher") {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { AppDelegate.shared?.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("所有 Xcode 版本…") { AppDelegate.shared?.showAllVersions() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    let model: XcodeViewModel
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?
    private var allVersionsWindow: NSWindow?
    private var directoryMonitors: [DispatchSourceFileSystemObject] = []
    private var directoryRefreshTask: Task<Void, Never>?
    private let monitorQueue = DispatchQueue(label: "com.yostar.xcodeswitcher.directory-monitor")
    private var menuBarTitleObserver: AnyCancellable?

    /// Windows are told apart by identifier rather than by title so the code does
    /// not depend on user-visible, localized strings.
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("XcodeSwitcherMainWindow")
    private static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("XcodeSwitcherSettingsWindow")
    private static let uiTestingEnvironmentKey = "XCODE_SWITCHER_UI_TESTING"
    private static let uiTestingDefaultsSuite = "com.yostar.xcodeswitcher.uitests"

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.environment[uiTestingEnvironmentKey] == "1"
    }

    /// "Xcode Switcher 2.1.0 (8)", for the launch line of the log.
    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Xcode Switcher \(version) (\(build))"
    }

    /// "macOS 27.0", built from the components rather than
    /// `operatingSystemVersionString`, which is localized by the process's language and
    /// made the log line switch between "macOS Version 27.0 (…)" and
    /// 「macOS 版本27.0（…）」 depending on how the app was launched.
    private static var osDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    override init() {
        model = Self.makeModel()
        super.init()
        Self.shared = self
    }

    /// UI tests must exercise the shipped application process, while still
    /// avoiding the user's configuration, language choice, login item, global
    /// shortcut, and update service. The test process opts into this mode with
    /// an environment variable that production launches never set.
    private static func makeModel() -> XcodeViewModel {
        guard isRunningUITests else { return XcodeViewModel() }

        let defaults = UserDefaults(suiteName: uiTestingDefaultsSuite)!
        defaults.removePersistentDomain(forName: uiTestingDefaultsSuite)
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSwitcherUITests-\(ProcessInfo.processInfo.processIdentifier).json")
        return XcodeViewModel(
            store: AppConfigurationStore(fileURL: configurationURL),
            languageDefaults: defaults,
            configuresSystemServices: false
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First line of every log: which build is running, on what system, and which
        // developer directory it started from. A bug report is much easier to place
        // with that than without it.
        AppLog.logger(.launch).notice(
            "launched \(Self.versionDescription, privacy: .public) on \(Self.osDescription, privacy: .public), developer dir \(XcodeLocator.activeDeveloperPath() ?? "none", privacy: .public)"
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon() ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Xcode Switcher")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Xcode Switcher"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if !Self.isRunningUITests {
            model.refresh()
        }
        rebuildMenu()
        // Keep the version in the menu bar current even when it changes outside
        // this app, for example after `xcode-select --switch` in a terminal.
        menuBarTitleObserver = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItemTitle() }
        }
        updateStatusItemTitle()
        model.onSearchPathsChanged = { [weak self] in self?.startWatchingSearchPaths() }
        if !Self.isRunningUITests {
            startWatchingSearchPaths()
        }
        applyMenuBarOnly(model.configuration.menuBarOnly)
    }

    /// Watches the folders that can gain or lose an Xcode installation, so the
    /// app reacts to real changes instead of re-running a Spotlight scan on a
    /// repeating timer while it sits idle in the menu bar.
    private func startWatchingSearchPaths() {
        stopWatchingSearchPaths()
        let folders = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true).path
        ] + model.configuration.customSearchPaths

        for folder in Set(folders) where FileManager.default.fileExists(atPath: folder) {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend],
                queue: monitorQueue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleRefreshAfterDirectoryChange() }
            }
            source.setCancelHandler { _ = close(descriptor) }
            source.resume()
            directoryMonitors.append(source)
        }
    }

    private func stopWatchingSearchPaths() {
        directoryMonitors.forEach { $0.cancel() }
        directoryMonitors.removeAll()
        directoryRefreshTask?.cancel()
        directoryRefreshTask = nil
    }

    /// Coalesces the burst of filesystem events a single install or move emits.
    private func scheduleRefreshAfterDirectoryChange() {
        directoryRefreshTask?.cancel()
        directoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.model.refresh(silently: true)
        }
    }

    /// Shows the active Xcode's version next to the icon, so the menu bar answers
    /// "which Xcode am I on?" without opening the menu. `version` rather than
    /// `displayVersion` keeps it short enough for the menu bar.
    private func updateStatusItemTitle() {
        let version = model.installations
            .first { $0.developerURL.path == model.activeDeveloperPath }?
            .version
        let title = version.map { " \($0)" } ?? ""
        guard statusItem.button?.title != title else { return }
        statusItem.button?.title = title
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.toolTip = version.map { "Xcode Switcher — Xcode \($0)" } ?? "Xcode Switcher"
    }

    private static func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchingSearchPaths()
        GlobalShortcutService.shared.stop()
        // Apply an edit that is still inside the project-edit debounce window.
        model.flushPendingProjectUpdate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Replaces the repeating timer: refresh only when the menu is actually
        // opened and the cached list has gone stale.
        model.refreshIfStale()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let active = model.activeInstallation {
            let activeItem = NSMenuItem(title: String(localized: "当前：\(active.name) \(active.displayVersion)"), action: nil, keyEquivalent: "")
            activeItem.isEnabled = false
            menu.addItem(activeItem)
            menu.addItem(.separator())
        }

        if model.installations.isEmpty {
            let empty = NSMenuItem(title: String(localized: "未发现 Xcode"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for installation in model.installations {
                let displayName = model.alias(for: installation).isEmpty ? installation.name : model.alias(for: installation)
                let title = (model.isFavorite(installation) ? "★ " : "") + "\(displayName) \(installation.displayVersion)"
                let item = NSMenuItem(title: title, action: #selector(activateXcode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = installation.id
                item.state = installation.developerURL.path == model.activeDeveloperPath ? .on : .off
                item.isEnabled = !model.isActive(installation) && !model.isSwitching
                menu.addItem(item)
            }
        }

        if !model.configuration.projects.isEmpty {
            menu.addItem(.separator())
            let projectsItem = NSMenuItem(title: String(localized: "项目"), action: nil, keyEquivalent: "")
            let projectsMenu = NSMenu(title: String(localized: "项目"))
            for profile in model.configuration.projects.prefix(12) {
                let issue = model.projectIssue(for: profile)
                let item = NSMenuItem(
                    title: (issue == nil ? "" : "⚠︎ ") + profile.name,
                    action: #selector(openProject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id.uuidString
                item.toolTip = issue ?? projectXcodeDescription(for: profile)
                item.isEnabled = issue == nil && !model.isSwitching
                projectsMenu.addItem(item)
            }
            if model.configuration.projects.count > 12 {
                projectsMenu.addItem(.separator())
                let remaining = NSMenuItem(
                    title: String(localized: "还有 \(model.configuration.projects.count - 12) 个项目，请在设置中查看"),
                    action: nil,
                    keyEquivalent: ""
                )
                remaining.isEnabled = false
                projectsMenu.addItem(remaining)
            }
            projectsItem.submenu = projectsMenu
            menu.addItem(projectsItem)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "打开主窗口"), action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let refresh = NSMenuItem(title: String(localized: "重新扫描"), action: #selector(refreshXcodes), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let allVersions = NSMenuItem(title: String(localized: "所有 Xcode 版本…"), action: #selector(openAllVersions), keyEquivalent: "")
        allVersions.target = self
        menu.addItem(allVersions)
        let settings = NSMenuItem(title: String(localized: "设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let updates = NSMenuItem(title: String(localized: "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = !model.isCheckingRelease
        updates.toolTip = model.updateServiceMessage
        menu.addItem(updates)
        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: String(localized: "全局快捷键：\(model.globalShortcutDisplayName)"), action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        let quit = NSMenuItem(title: String(localized: "退出 Xcode Switcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func activateXcode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let installation = model.installations.first(where: { $0.id == id }) else { return }
        model.select(installation)
        model.activate(installation)
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let profile = model.configuration.projects.first(where: { $0.id == id }) else { return }
        model.applyAndOpen(profile)
    }

    private func projectXcodeDescription(for profile: ProjectProfile) -> String {
        guard let installation = model.installation(for: profile) else {
            return String(localized: "没有可用的 Xcode")
        }
        if profile.xcodeID == nil, let match = model.automaticMatch(for: profile) {
            return String(localized: "自动匹配 \(installation.name) \(match.requirement.normalizedVersion)")
        }
        return String(localized: "使用 \(installation.name) \(installation.displayVersion)")
    }

    @objc private func openMainWindow() { model.showMainWindow() }
    @objc private func refreshXcodes() { model.refresh() }
    @objc private func openAllVersions() { showAllVersions(nil) }
    @objc private func openSettings() { showSettings(nil) }
    @objc private func checkForUpdates() { model.checkForUpdates() }

    func applyMenuBarOnly(_ enabled: Bool) {
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if enabled {
            DispatchQueue.main.async {
                // Only the main window belongs to menu-bar-only mode; the Settings
                // window keeps its own lifecycle.
                NSApp.windows
                    .filter { $0.identifier != Self.settingsWindowIdentifier }
                    .forEach { $0.orderOut(nil) }
            }
        } else {
            presentMainWindow()
        }
    }

    func presentMainWindow(focusSearch: Bool = false) {
        model.refreshIfStale()
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.identifier != Self.settingsWindowIdentifier }) ?? NSApp.windows.first else { return }
        window.identifier = Self.mainWindowIdentifier
        window.makeKeyAndOrderFront(nil)
        if focusSearch {
            DispatchQueue.main.async { [weak self] in
                self?.model.requestSearchFocus()
            }
        }
    }

    /// A window rather than a sheet: browsing releases is a comparison task, and it
    /// should not block the detail pane it is meant to be read next to.
    @objc func showAllVersions(_ notification: Notification? = nil) {
        if let allVersionsWindow {
            allVersionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = AllVersionsView().environmentObject(model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "所有 Xcode 版本")
        window.contentViewController = NSHostingController(rootView: content)
        // Handing AppKit a hosting controller makes it adopt the view's minimum size,
        // which silently ignores the contentRect above — the window opened at the
        // 640x420 floor instead of the intended size. Setting it afterwards sticks.
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        allVersionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ notification: Notification? = nil) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SettingsView().environmentObject(model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Xcode Switcher 设置")
        window.identifier = Self.settingsWindowIdentifier
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
