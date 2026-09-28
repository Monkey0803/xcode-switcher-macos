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
    private var diskSpaceTimer: Timer?
    private var lowDiskSpaceAvailableBytes: Int64?

    /// Windows are told apart by identifier rather than by title so the code does
    /// not depend on user-visible, localized strings.
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("XcodeSwitcherMainWindow")
    private static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("XcodeSwitcherSettingsWindow")
    private static let allVersionsWindowIdentifier = NSUserInterfaceItemIdentifier("XcodeSwitcherAllVersionsWindow")
    private static let uiTestingEnvironmentKey = "XCODE_SWITCHER_UI_TESTING"
    private static let uiTestingDefaultsSuite = "com.yostar.xcodeswitcher.uitests"
    private static let uiTestingRecommendedProjectID = UUID(uuidString: "7C7B93FD-DC7A-47BB-9C91-F0E591DDD2AA")!

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
        let model = XcodeViewModel(
            store: AppConfigurationStore(fileURL: configurationURL),
            releaseCatalogStore: uiTestReleaseCatalogStore(),
            languageDefaults: defaults,
            configuresSystemServices: false
        )
        configureUITestFixture(on: model)
        return model
    }

    /// The release index the UI suite runs against, served from memory.
    ///
    /// Without this the "every version" window would reach `xcodereleases.com` on
    /// first run and then reuse a day-old on-disk cache: the row count would depend
    /// on the network and on when the machine last fetched, so no assertion about
    /// filtering could be stable. `maxAge: 0` keeps the cache from ever being
    /// trusted, and the cache file is per process so two runs cannot share it.
    private static func uiTestReleaseCatalogStore() -> XcodeReleaseCatalogStore {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSwitcherUITests-releases-\(ProcessInfo.processInfo.processIdentifier).json")
        // Read on the main actor: the closure below is `@Sendable` and cannot touch
        // this type's actor-isolated state.
        let index = Data(uiTestReleaseIndex.utf8)
        return XcodeReleaseCatalogStore(
            fetch: { index },
            cacheURL: cacheURL,
            maxAge: 0
        )
    }

    /// Four releases, one per case the window's filters need to tell apart:
    /// `15F31d` and `16A242d` are the two fixture installations, `17A100` is a beta,
    /// and `27Z999` requires a macOS that will not exist, so "hidden because this Mac
    /// cannot run it" always has exactly one row to hide.
    private static let uiTestReleaseIndex = """
    [
      {
        "name": "Xcode",
        "version": { "number": "15.4", "build": "15F31d", "release": { "release": true } },
        "date": { "year": 2024, "month": 5, "day": 13 },
        "requires": "14.0",
        "links": {
          "download": {
            "url": "https://example.com/Xcode_15.4.xip",
            "architectures": [ "arm64" ]
          }
        }
      },
      {
        "name": "Xcode",
        "version": { "number": "16.0", "build": "16A242d", "release": { "release": true } },
        "date": { "year": 2024, "month": 9, "day": 16 },
        "requires": "15.0",
        "links": {
          "download": {
            "url": "https://example.com/Xcode_16.0.xip",
            "architectures": [ "arm64" ]
          }
        }
      },
      {
        "name": "Xcode",
        "version": { "number": "17.0", "build": "17A100", "release": { "beta": 1 } },
        "date": { "year": 2025, "month": 6, "day": 9 },
        "requires": "15.0",
        "links": {
          "download": {
            "url": "https://example.com/Xcode_17.0_beta.xip",
            "architectures": [ "arm64" ]
          }
        }
      },
      {
        "name": "Xcode",
        "version": { "number": "27.5", "build": "27Z999", "release": { "release": true } },
        "date": { "year": 2027, "month": 1, "day": 1 },
        "requires": "99.0",
        "links": {
          "download": {
            "url": "https://example.com/Xcode_27.5.xip",
            "architectures": [ "arm64" ]
          }
        }
      }
    ]
    """

    /// The UI suite launches the production app target, but this fixture removes
    /// dependencies on the user's installed Xcodes, project list, and disk usage.
    private static func configureUITestFixture(on model: XcodeViewModel) {
        // Resolved to match what discovery stores (it resolves too). Note that
        // `URL.resolvingSymlinksInPath()` leaves `/var` and `/tmp` alone — measured
        // 2026-09-28 — so for the default temporary directory this call is a no-op and
        // the removal policy's symlink test does not fire on fixture paths.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSwitcherUITestFixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .resolvingSymlinksInPath()
        let active = XcodeInstallation(
            appURL: root.appendingPathComponent("Xcode 15.4.app", isDirectory: true),
            version: "15.4",
            build: "15F31d"
        )
        let recommended = XcodeInstallation(
            appURL: root.appendingPathComponent("Xcode 16.0.app", isDirectory: true),
            version: "16.0",
            build: "16A242d"
        )
        // A third installation that nothing pins and that is not the system default,
        // so the removal panel has one case where the action is actually offered.
        // Its build is deliberately absent from the release index above, which keeps
        // the 「已安装」 filter assertions about 15F31d/16A242d untouched.
        let spare = XcodeInstallation(
            appURL: root.appendingPathComponent("Xcode 17.5.app", isDirectory: true),
            version: "17.5",
            build: "17B42"
        )
        let projectURL = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("Workspace.xcworkspace", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: active.developerURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: recommended.developerURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: spare.developerURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        for (name, version) in [("App", "15.4"), ("Tools", "16.0")] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let childProjectURL = directory.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
            try? FileManager.default.createDirectory(at: childProjectURL, withIntermediateDirectories: true)
            try? "{\"xcode\": \"\(version)\"}".write(
                to: directory.appendingPathComponent(".xcode-switcher.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        try? """
        <Workspace version=\"1.0\">
          <FileRef location=\"group:App/App.xcodeproj\"/>
          <FileRef location=\"group:Tools/Tools.xcodeproj\"/>
        </Workspace>
        """.write(
            to: workspaceURL.appendingPathComponent("contents.xcworkspacedata"),
            atomically: true,
            encoding: .utf8
        )

        model.installs.replaceInstallationsForUITesting(
            [active, recommended, spare],
            activeDeveloperPath: active.developerURL.path
        )
        // The two system boundaries a test cannot cross are stubbed rather than
        // simulated: the administrator prompt for `xcode-select --switch` and
        // `simctl` itself. Both fail visibly, which is what the tests assert.
        model.installs.activateXcode = { _ in
            throw NSError(
                domain: "XcodeSwitcher.UITest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "UI test authorization cancelled."]
            )
        }
        model.installs.simulatorAction = { _, _, _ in
            ProcessResult(status: 1, stdout: "", stderr: "UI test simctl failure")
        }
        model.installs.setSimulatorDevicesForUITesting([
            SimulatorDevice(
                id: "ui-test-device",
                name: "UI Test Simulator",
                state: "Shutdown",
                runtimeID: "ui-test-runtime",
                isAvailable: true
            )
        ], for: recommended)
        // The UI test opens then cancels this confirmation. It must remain
        // enabled even when the developer machine has a real Xcode process.
        model.cleanup.isAnyXcodeRunning = { false }
        model.cleanup.setCleanupEntriesForUITesting([
            XcodeCleanupEntry(
                path: root.appendingPathComponent("DerivedData").path,
                label: String(localized: "测试 DerivedData"),
                bytes: 512 * 1_024 * 1_024,
                safety: .safe,
                note: String(localized: "仅用于确认清理流程测试，不会删除该目录。")
            )
        ], for: active)
        model.environment.inspect = { installation, _ in
            // Printed on purpose: the app's stdout lands in the CI log, and when this
            // path fails only on a runner this is what tells 「the click never ran the
            // action」 apart from 「the report never came back」.
            print("[ui-test] environment inspect ran for \(installation.name)")
            return EnvironmentReport(
                installationID: installation.id,
                installationName: installation.name,
                version: installation.version,
                checks: [
                    EnvironmentCheck(
                        id: "ui-test-check",
                        title: String(localized: "测试诊断完成"),
                        detail: String(localized: "这是 UI 测试提供的诊断结果。"),
                        severity: .healthy
                    )
                ]
            )
        }
        model.configuration.projects = [
            ProjectProfile(
                id: uiTestingRecommendedProjectID,
                name: String(localized: "测试项目"),
                path: projectURL.path,
                xcodeID: recommended.id
            ),
            ProjectProfile(name: String(localized: "测试工作区"), path: workspaceURL.path)
        ]
        model.configuration.projectSearchPaths = [root.path]
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
        model.onDiskSpaceWarningConfigurationChanged = { [weak self] in self?.refreshDiskSpaceWarning() }
        model.onXcodeUpdateNotificationsReady = { [weak self] candidates in
            Task { @MainActor [weak self] in
                let delivered = await XcodeUpdateNotificationService.deliver(candidates)
                self?.model.markXcodeUpdateNotificationsDelivered(delivered)
            }
        }
        model.onXcodeUpdateNotificationsPreferenceChanged = { enabled in
            guard enabled else { return }
            Task { @MainActor in
                let authorized = await XcodeUpdateNotificationService.requestAuthorizationIfNeeded()
                AppLog.logger(.settings).info(
                    "Xcode update notification authorization \(authorized ? "granted" : "not granted", privacy: .public)"
                )
            }
        }
        if !Self.isRunningUITests {
            model.refresh()
            startDiskSpaceMonitoring()
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
        let normalTitle = version.map { " \($0)" } ?? ""
        let normalToolTip = version.map { "Xcode Switcher — Xcode \($0)" } ?? "Xcode Switcher"
        let title = lowDiskSpaceAvailableBytes.map { " ⚠︎ \(DiskUsageFormatter.humanReadable(bytes: $0))" } ?? normalTitle
        let toolTip = lowDiskSpaceAvailableBytes.map {
            String(localized: "磁盘空间不足：剩余 \(DiskUsageFormatter.humanReadable(bytes: $0))。打开菜单查看清理建议。")
        } ?? normalToolTip
        guard statusItem.button?.title != title || statusItem.button?.toolTip != toolTip else { return }
        statusItem.button?.title = title
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.toolTip = toolTip
    }

    private static func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func startDiskSpaceMonitoring() {
        refreshDiskSpaceWarning()
        diskSpaceTimer?.invalidate()
        diskSpaceTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDiskSpaceWarning()
            }
        }
    }

    private func refreshDiskSpaceWarning() {
        guard model.configuration.diskSpaceWarningEnabled,
              let availableBytes = DiskSpaceMonitor.availableBytes(at: FileManager.default.homeDirectoryForCurrentUser),
              DiskSpaceMonitor.isBelowWarningThreshold(
                availableBytes: availableBytes,
                thresholdGB: model.configuration.diskSpaceWarningThresholdGB
              )
        else {
            lowDiskSpaceAvailableBytes = nil
            updateStatusItemTitle()
            return
        }
        lowDiskSpaceAvailableBytes = availableBytes
        updateStatusItemTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchingSearchPaths()
        diskSpaceTimer?.invalidate()
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
        if let availableBytes = lowDiskSpaceAvailableBytes {
            let warning = NSMenuItem(
                title: String(localized: "磁盘空间不足：剩余 \(DiskUsageFormatter.humanReadable(bytes: availableBytes))。查看清理建议…"),
                action: #selector(openDiskCleanup),
                keyEquivalent: ""
            )
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }
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
    @objc private func openDiskCleanup() {
        guard let installation = model.activeInstallation ?? model.selectedInstallation ?? model.installations.first else {
            presentMainWindow()
            return
        }
        model.requestDiskCleanup(for: installation)
        presentMainWindow()
    }
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

    /// Centres a window on the screen it will open on, inside its visible frame.
    ///
    /// `NSWindow.center()` is not enough on its own: it centres whatever size the window
    /// has *at that moment*. A window whose content view controller has not been laid out
    /// yet is still at its minimum, and CI (a 1024×768 display) showed where that ends —
    /// the 760-point settings window sat at x=511, i.e. 247 points off the right edge,
    /// with every control in that strip unreachable. The caller therefore pins the size
    /// first; this only positions, so it can never shrink a window that is still growing.
    private func centerOnVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let centred = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrameOrigin(NSPoint(
            x: min(max(centred.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(centred.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        ))
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
        window.identifier = Self.allVersionsWindowIdentifier
        window.contentViewController = NSHostingController(rootView: content)
        // Handing AppKit a hosting controller makes it adopt the view's minimum size,
        // which silently ignores the contentRect above — the window opened at the
        // 640x420 floor instead of the intended size. Setting it afterwards sticks.
        window.setContentSize(NSSize(width: 1000, height: 640))
        centerOnVisibleScreen(window)
        window.isReleasedWhenClosed = false
        allVersionsWindow = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            self.centerOnVisibleScreen(window)
        }
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
        // Pin the size before positioning: the hosting controller reports a minimum that
        // is not the final size, and positioning an unsized window is what put it off the
        // edge of the screen.
        window.setContentSize(NSSize(width: 760, height: 600))
        centerOnVisibleScreen(window)
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        // Again after layout, when the size is final. Positioning is idempotent.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            self.centerOnVisibleScreen(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
