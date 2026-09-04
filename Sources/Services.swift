import AppKit
import ApplicationServices
import Foundation
import Security

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let cancelled: Bool
    var succeeded: Bool { status == 0 && !timedOut && !cancelled }

    init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, cancelled: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    var failureDescription: String {
        if cancelled { return "操作已取消。" }
        if timedOut { return "操作超时。" }
        if !stderr.isEmpty { return stderr }
        return "命令执行失败（退出码 \(status)）。"
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var data: Data {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func append(_ data: Data) {
        lock.withLock { stored.append(data) }
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = 60,
        progress: (@Sendable (String) -> Void)? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { mergedEnvironment[$0.key] = $0.value }
        process.environment = mergedEnvironment
        process.currentDirectoryURL = currentDirectory

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
            let group = DispatchGroup()
            let stdoutBox = DataBox()
            let stderrBox = DataBox()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    stdoutBox.append(data)
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty { progress?(text) }
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let data = errorOutput.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    stderrBox.append(data)
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty { progress?(text) }
                }
                group.leave()
            }
            let startedAt = Date()
            var timedOut = false
            var cancelled = false
            while process.isRunning {
                if Task.isCancelled {
                    cancelled = true
                    process.terminate()
                    break
                }
                if let timeout, Date().timeIntervalSince(startedAt) >= timeout {
                    timedOut = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            group.wait()
            let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
            let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
            return ProcessResult(
                status: process.terminationStatus,
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                timedOut: timedOut,
                cancelled: cancelled
            )
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    static func output(executable: String, arguments: [String], environment: [String: String] = [:]) -> String? {
        let result = run(executable: executable, arguments: arguments, environment: environment)
        return result.succeeded && !result.stdout.isEmpty ? result.stdout : nil
    }
}

enum XcodeLocator {
    private static let bundleIdentifier = "com.apple.dt.Xcode"

    static func discover(searchPaths: [String]) -> [XcodeInstallation] {
        var candidates = Set<URL>()

        if let spotlightResults = ProcessRunner.output(
            executable: "/usr/bin/mdfind",
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"]
        ) {
            spotlightResults.split(whereSeparator: \.isNewline).forEach {
                candidates.insert(URL(fileURLWithPath: String($0)).resolvingSymlinksInPath())
            }
        }

        let fileManager = FileManager.default
        let standardFolders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for folder in standardFolders {
            addApplications(in: folder, to: &candidates)
        }

        for path in searchPaths where !path.isEmpty {
            addApplicationsRecursively(in: URL(fileURLWithPath: path), to: &candidates)
        }

        return candidates.compactMap(installation(at:)).sorted { lhs, rhs in
            let versionComparison = lhs.version.compare(rhs.version, options: .numeric)
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            return lhs.appURL.path.localizedStandardCompare(rhs.appURL.path) == .orderedAscending
        }
    }

    static func activeDeveloperPath() -> String? {
        let result = ProcessRunner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"])
        guard result.succeeded else { return nil }
        return URL(fileURLWithPath: result.stdout).resolvingSymlinksInPath().path
    }

    static func commandLineToolsPath() -> String {
        activeDeveloperPath() ?? "未配置"
    }

    private static func addApplications(in folder: URL, to candidates: inout Set<URL>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        candidates.formUnion(contents.filter { $0.pathExtension == "app" }.map { $0.resolvingSymlinksInPath() })
    }

    private static func addApplicationsRecursively(in folder: URL, to candidates: inout Set<URL>) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if folder.pathExtension == "app" {
            candidates.insert(folder.resolvingSymlinksInPath())
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            candidates.insert(url.resolvingSymlinksInPath())
        }
    }

    private static func installation(at appURL: URL) -> XcodeInstallation? {
        let resolvedURL = appURL.resolvingSymlinksInPath()
        let infoURL = resolvedURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              FileManager.default.fileExists(atPath: resolvedURL.appendingPathComponent("Contents/Developer").path) else {
            return nil
        }
        return XcodeInstallation(appURL: resolvedURL, version: version, build: info["CFBundleVersion"] as? String ?? "")
    }
}

enum XcodeTooling {
    static func details(for installation: XcodeInstallation) -> XcodeDetails {
        let environment = ["DEVELOPER_DIR": installation.developerURL.path]
        let sdkResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-version"],
            environment: environment,
            timeout: 20
        )
        let sdk = sdkResult.succeeded && !sdkResult.stdout.isEmpty ? sdkResult.stdout : "未知"
        let swiftResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "--version"],
            environment: environment,
            timeout: 20
        )
        let swift = swiftResult.stdout
            .split(separator: "\n")
            .first(where: { $0.lowercased().contains("swift version") })
            .map(String.init) ?? "未检测到"
        return XcodeDetails(swiftVersion: swift, sdkVersion: sdk, isCommandLineTools: false)
    }

    static func simulatorRuntimes(for installation: XcodeInstallation) -> [SimulatorRuntime] {
        let environment = ["DEVELOPER_DIR": installation.developerURL.path]
        let result = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "runtimes", "--json"],
            environment: environment,
            timeout: 30
        )
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else { return [] }
        var seenIdentifiers = Set<String>()
        return runtimes.compactMap { runtime in
            guard let identifier = runtime["identifier"] as? String,
                  seenIdentifiers.insert(identifier).inserted,
                  let name = runtime["name"] as? String else { return nil }
            let version = runtime["version"] as? String ?? "未知"
            let available = runtime["isAvailable"] as? Bool ?? (runtime["availability"] as? String)?.contains("available") ?? false
            return SimulatorRuntime(id: identifier, name: name, version: version, isAvailable: available)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func downloadIOSRuntime(
        for installation: XcodeInstallation,
        progress: (@Sendable (String) -> Void)? = nil
    ) -> ProcessResult {
        ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-downloadPlatform", "iOS"],
            environment: ["DEVELOPER_DIR": installation.developerURL.path],
            timeout: 7_200,
            progress: progress
        )
    }
}

private final class XcodeAuthorizationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: AuthorizationRef?

    deinit {
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
        }
    }

    func execute(toolPath: String, arguments: [String]) throws {
        try lock.withLock {
            var authorization = try authorizationReference()
            var rightsStatus = copyExecuteRights(for: toolPath, authorization: authorization)
            if rightsStatus == errAuthorizationInvalidRef {
                resetAuthorization()
                authorization = try authorizationReference()
                rightsStatus = copyExecuteRights(for: toolPath, authorization: authorization)
            }
            guard rightsStatus == errAuthorizationSuccess else {
                throw authorizationError(rightsStatus, action: "获取管理员授权")
            }

            let executeStatus = executeWithPrivileges(
                authorization: authorization,
                toolPath: toolPath,
                arguments: arguments
            )
            guard executeStatus == errAuthorizationSuccess else {
                if executeStatus == errAuthorizationInvalidRef {
                    resetAuthorization()
                }
                throw authorizationError(executeStatus, action: "执行 Xcode 切换")
            }
        }
    }

    private func authorizationReference() throws -> AuthorizationRef {
        if let authorization { return authorization }
        var authorization: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw authorizationError(status, action: "创建授权会话")
        }
        self.authorization = authorization
        return authorization
    }

    private func copyExecuteRights(for toolPath: String, authorization: AuthorizationRef) -> OSStatus {
        kAuthorizationRightExecute.withCString { rightName in
            toolPath.withCString { toolPathPointer in
                var item = AuthorizationItem(
                    name: rightName,
                    valueLength: toolPath.utf8.count,
                    value: UnsafeMutableRawPointer(mutating: toolPathPointer),
                    flags: 0
                )
                return withUnsafeMutablePointer(to: &item) { itemPointer in
                    var rights = AuthorizationRights(count: 1, items: itemPointer)
                    return AuthorizationCopyRights(
                        authorization,
                        &rights,
                        nil,
                        [.interactionAllowed, .extendRights],
                        nil
                    )
                }
            }
        }
    }

    private func resetAuthorization() {
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
        }
        authorization = nil
    }

    private func authorizationError(_ status: OSStatus, action: String) -> NSError {
        NSError(
            domain: "XcodeSwitcher.Authorization",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(action)失败（错误码 \(status)）。"]
        )
    }

    private func executeWithPrivileges(
        authorization: AuthorizationRef,
        toolPath: String,
        arguments: [String]
    ) -> OSStatus {
        let argumentPointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        argumentPointers.initialize(repeating: nil, count: arguments.count + 1)
        defer {
            for index in arguments.indices {
                if let pointer = argumentPointers[index] {
                    free(pointer)
                }
            }
            argumentPointers.deinitialize(count: arguments.count + 1)
            argumentPointers.deallocate()
        }

        for (index, argument) in arguments.enumerated() {
            argumentPointers[index] = strdup(argument)
        }

        var communicationsPipe: UnsafeMutablePointer<FILE>?
        let status = toolPath.withCString { toolPathPointer in
            argumentPointers.withMemoryRebound(
                to: UnsafeMutablePointer<CChar>.self,
                capacity: arguments.count + 1
            ) { pointer in
                xcodeAuthorizationExecuteWithPrivileges(
                    authorization,
                    toolPathPointer,
                    [],
                    UnsafePointer(pointer),
                    &communicationsPipe
                )
            }
        }
        guard status == errAuthorizationSuccess else { return status }

        // Reading to EOF waits for xcode-select to finish before returning.
        if let communicationsPipe {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while buffer.withUnsafeMutableBytes({ bytes in
                fread(bytes.baseAddress, 1, bytes.count, communicationsPipe)
            }) > 0 {}
            fclose(communicationsPipe)
        }
        return status
    }
}

// Swift marks this legacy symbol unavailable. Keep the compatibility
// declaration local so the authorization session can reuse its token on
// supported macOS versions without persisting credentials.
@_silgen_name("AuthorizationExecuteWithPrivileges")
private func xcodeAuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ options: AuthorizationFlags,
    _ arguments: UnsafePointer<UnsafeMutablePointer<CChar>>,
    _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

enum XcodeActivator {
    private static let authorizationSession = XcodeAuthorizationSession()

    static func activate(_ installation: XcodeInstallation) throws {
        try authorizationSession.execute(
            toolPath: "/usr/bin/xcode-select",
            arguments: ["--switch", installation.developerURL.path]
        )
    }

    static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

enum XcodeActions {
    static func open(_ project: URL, with installation: XcodeInstallation) {
        NSWorkspace.shared.open(
            [project],
            withApplicationAt: installation.appURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    static func openXcode(_ installation: XcodeInstallation) -> Bool {
        NSWorkspace.shared.open(installation.appURL)
    }

    static func openTerminal(at directory: URL, developerPath: String) -> Bool {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard FileManager.default.fileExists(atPath: terminalURL.path) else { return false }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSwitcher-\(UUID().uuidString)")
            .appendingPathExtension("command")
        let command = """
        #!/bin/zsh
        export DEVELOPER_DIR=\(shellQuote(developerPath))
        cd \(shellQuote(directory.path)) || exit 1
        clear
        exec /bin/zsh -l
        """
        do {
            try command.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let result = ProcessRunner.run(
                executable: "/usr/bin/open",
                arguments: ["-a", terminalURL.path, scriptURL.path]
            )
            if result.succeeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    try? FileManager.default.removeItem(at: scriptURL)
                }
            } else {
                try? FileManager.default.removeItem(at: scriptURL)
            }
            return result.succeeded
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return false
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openXcodeSettings(for installation: XcodeInstallation) -> Bool {
        guard NSWorkspace.shared.open(installation.appURL) else { return false }

        // Xcode does not expose a public URL scheme for its Settings window.
        // Open its application menu and choose Settings. This is independent
        // of the user's display language and requires Accessibility permission.
        let processName = installation.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let source = """
            tell application "System Events"
                tell process \(XcodeActivator.appleScriptQuote(processName))
                    click menu bar item 2 of menu bar 1
                    tell menu 1 of menu bar item 2 of menu bar 1
                        repeat with menuItem in menu items
                            set itemTitle to title of menuItem
                            if itemTitle contains "Settings" or itemTitle contains "设置" then
                                click menuItem
                                exit repeat
                            end if
                        end repeat
                    end tell
                end tell
            end tell
            """
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
        return true
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

@MainActor
final class GlobalShortcutService {
    static let shared = GlobalShortcutService()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var shortcut = GlobalShortcut.default
    var onPressed: (() -> Void)?

    @discardableResult
    func start(using shortcut: GlobalShortcut = .default) -> Bool {
        guard globalMonitor == nil else { return isAccessibilityTrusted }
        self.shortcut = shortcut
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.matches(event) else { return }
            self.onPressed?()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
        return isAccessibilityTrusted
    }

    @discardableResult
    func update(_ shortcut: GlobalShortcut) -> Bool {
        stop()
        return start(using: shortcut)
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == shortcut.keyCode else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        return modifiers.rawValue == shortcut.modifierFlags
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

@MainActor
final class AppConfigurationStore {
    static let shared = AppConfigurationStore()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base.appendingPathComponent("XcodeSwitcher", isDirectory: true).appendingPathComponent("configuration.json")
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: fileURL), let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return configuration
    }

    func save(_ configuration: AppConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func export(_ configuration: AppConfiguration, to url: URL) throws {
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    func `import`(from url: URL) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
    }
}
