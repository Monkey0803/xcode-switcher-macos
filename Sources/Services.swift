import AppKit
import ApplicationServices
import Darwin
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

/// One captured standard-output or standard-error stream.
///
/// Reads are non-blocking and driven by `poll`, so a child that hands its pipe
/// to a surviving grandchild (for example `xcodebuild -downloadPlatform`) can
/// never block the caller on a pipe that will not reach EOF.
private struct ProcessOutputStream {
    let fileDescriptor: Int32
    private let handle: FileHandle
    private var captured = Data()
    private(set) var isOpen = true

    init(_ handle: FileHandle) {
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    var text: String { String(data: captured, encoding: .utf8) ?? "" }

    /// Drains everything currently buffered and returns the number of bytes read.
    @discardableResult
    mutating func drain(progress: (@Sendable (String) -> Void)?) -> Int {
        guard isOpen else { return 0 }
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let data = Data(buffer[0..<count])
                captured.append(data)
                total += count
                if let progress, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    progress(chunk)
                }
                continue
            }
            if count == 0 {
                close()
                return total
            }
            if errno == EINTR { continue }
            // EAGAIN only means the pipe is momentarily empty; every other
            // failure means the descriptor is no longer usable.
            if errno != EAGAIN && errno != EWOULDBLOCK { close() }
            return total
        }
    }

    mutating func close() {
        guard isOpen else { return }
        isOpen = false
        try? handle.close()
    }
}

enum ProcessRunner {
    /// Time allowed to collect output the child already wrote after it exits.
    private static let outputDrainGrace: TimeInterval = 0.3
    /// Time allowed for a process to exit after `SIGTERM` before `SIGKILL`.
    private static let terminationGrace: TimeInterval = 1.0
    private static let pollIntervalMilliseconds: Int32 = 50

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

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // The parent must release its own write ends, otherwise the read ends
        // never observe EOF after the child exits.
        standardOutput.fileHandleForWriting.closeFile()
        standardError.fileHandleForWriting.closeFile()

        var streams = [
            ProcessOutputStream(standardOutput.fileHandleForReading),
            ProcessOutputStream(standardError.fileHandleForReading)
        ]

        let deadline = timeout.map { startedAt.addingTimeInterval($0) }
        var timedOut = false
        var cancelled = false
        var lastActivity = startedAt

        while true {
            let now = Date()
            if Task.isCancelled {
                cancelled = true
                break
            }
            if let deadline, now >= deadline {
                timedOut = true
                break
            }
            if !process.isRunning {
                let streamsClosed = !streams.contains { $0.isOpen }
                // A surviving grandchild can keep a pipe open forever; stop once
                // the direct child is gone and its remaining output has drained.
                if streamsClosed || now.timeIntervalSince(lastActivity) >= outputDrainGrace {
                    break
                }
            }
            if drain(&streams, progress: progress) > 0 {
                lastActivity = Date()
            }
        }

        if cancelled || timedOut {
            terminate(process)
        }
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: streams[0].text.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: streams[1].text.trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut,
            cancelled: cancelled
        )
    }

    /// Waits for readable output and drains it. Returns the number of bytes read.
    @discardableResult
    private static func drain(
        _ streams: inout [ProcessOutputStream],
        progress: (@Sendable (String) -> Void)?
    ) -> Int {
        var descriptors: [pollfd] = []
        var streamIndices: [Int] = []
        for (index, stream) in streams.enumerated() where stream.isOpen {
            descriptors.append(pollfd(fd: stream.fileDescriptor, events: Int16(POLLIN), revents: 0))
            streamIndices.append(index)
        }

        guard !descriptors.isEmpty else {
            // Nothing left to read: stay responsive to cancellation and to the
            // child exiting instead of spinning on an empty descriptor set.
            Thread.sleep(forTimeInterval: TimeInterval(pollIntervalMilliseconds) / 1000)
            return 0
        }

        guard poll(&descriptors, nfds_t(descriptors.count), pollIntervalMilliseconds) > 0 else {
            return 0
        }

        var total = 0
        for (position, descriptor) in descriptors.enumerated() {
            let events = Int32(descriptor.revents)
            guard events & POLLIN != 0 || events & POLLHUP != 0 || events & POLLERR != 0 else { continue }
            total += streams[streamIndices[position]].drain(progress: progress)
        }
        return total
    }

    /// Ends the process, escalating to `SIGKILL` so the caller can never block
    /// on a child that ignores `SIGTERM`.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(terminationGrace)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
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

    static func simulatorDevices(for installation: XcodeInstallation) -> [SimulatorDevice] {
        let result = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            environment: ["DEVELOPER_DIR": installation.developerURL.path],
            timeout: 30
        )
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return [] }
        return parseSimulatorDevices(data: data)
    }

    static func parseSimulatorDevices(data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceGroups = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return deviceGroups.flatMap { runtimeID, devices in
            devices.compactMap { device in
                guard let id = device["udid"] as? String,
                      let name = device["name"] as? String else { return nil }
                let state = device["state"] as? String ?? "未知"
                let available = device["isAvailable"] as? Bool ?? true
                return SimulatorDevice(id: id, name: name, state: state, runtimeID: runtimeID, isAvailable: available)
            }
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    static func simulatorAction(
        _ action: String,
        device: SimulatorDevice,
        installation: XcodeInstallation
    ) -> ProcessResult {
        ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", action, device.id],
            environment: ["DEVELOPER_DIR": installation.developerURL.path],
            timeout: 120
        )
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

// Decision (2026-09-11): `xcode-select --switch` needs root, and this app is
// distributed directly from GitHub rather than through the App Store, so the
// sandbox is not a constraint. The supported replacement for this deprecated
// symbol is a privileged helper registered with `SMAppService.daemon(plistName:)`,
// but Apple requires every app containing a LaunchDaemon to be code signed and
// notarized ("Apps that contain LaunchDaemons must be notarized", SMAppService.h),
// while this project still ships ad-hoc signed direct-distribution builds. Keeping
// the existing authorization session is therefore the lower-risk choice; revisit
// once Developer ID signing plus notarization is the primary distribution path.
// Meanwhile the root-free `DEVELOPER_DIR` route is offered directly in the UI.
//
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

    /// Xcode exposes no public URL scheme for its Settings window, so this drives
    /// its menu bar through System Events. That needs Accessibility permission and
    /// depends on the menu layout, so the outcome is reported instead of assumed.
    static func openXcodeSettings(
        for installation: XcodeInstallation,
        completion: @escaping @Sendable (Result<Void, XcodeSettingsError>) -> Void
    ) {
        guard NSWorkspace.shared.open(installation.appURL) else {
            completion(.failure(.cannotLaunch))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(.accessibilityPermissionMissing))
            return
        }
        let processName = installation.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            completion(performXcodeSettingsScript(processName: processName))
        }
    }

    /// Kept separate from the runner so the script syntax can be compiled and
    /// validated in tests without ever executing it.
    static func xcodeSettingsScript(processName: String) -> String {
        """
        tell application "System Events"
            tell process \(XcodeActivator.appleScriptQuote(processName))
                set appMenuBarItem to menu bar item 2 of menu bar 1
                click appMenuBarItem
                set didClickSettings to false
                tell menu 1 of appMenuBarItem
                    repeat with menuItem in menu items
                        set itemTitle to title of menuItem
                        if itemTitle contains "Settings" or itemTitle contains "设置" then
                            click menuItem
                            set didClickSettings to true
                            exit repeat
                        end if
                    end repeat
                end tell
                if didClickSettings then
                    return "ok"
                else
                    return "missing-settings-item"
                end if
            end tell
        end tell
        """
    }

    private static func performXcodeSettingsScript(processName: String) -> Result<Void, XcodeSettingsError> {
        guard let script = NSAppleScript(source: xcodeSettingsScript(processName: processName)) else {
            return .failure(.automationFailed("无法创建系统自动化脚本"))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error, error.count > 0 {
            return .failure(.automationFailed(describe(error)))
        }
        switch result.stringValue {
        case "ok":
            return .success(())
        case "missing-settings-item":
            return .failure(.settingsItemNotFound)
        default:
            return .failure(.automationFailed("脚本未返回预期结果"))
        }
    }

    private static func describe(_ error: NSDictionary) -> String {
        if let message = error[NSAppleScript.errorMessage] as? String, !message.isEmpty {
            return message
        }
        if let number = error[NSAppleScript.errorNumber] as? Int {
            return "错误码 \(number)"
        }
        return "未知错误"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

enum XcodeSettingsError: LocalizedError, Sendable {
    case cannotLaunch
    case accessibilityPermissionMissing
    case settingsItemNotFound
    case automationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotLaunch:
            return "无法打开该 Xcode。"
        case .accessibilityPermissionMissing:
            return "需要辅助功能权限才能自动打开 Xcode 的 Settings 窗口，请在系统设置中授权后重试。"
        case .settingsItemNotFound:
            return "没有在 Xcode 菜单中找到 Settings 项，请在 Xcode 中手动打开。"
        case let .automationFailed(detail):
            return "无法自动打开 Xcode 的 Settings 窗口（\(detail)），请在 Xcode 中手动打开。"
        }
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

final class AppConfigurationStore: @unchecked Sendable {
    static let shared = AppConfigurationStore()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base.appendingPathComponent("XcodeSwitcher", isDirectory: true).appendingPathComponent("configuration.json")
        }
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppConfiguration()
        }
        guard var configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            // Preserve an unreadable file before falling back to defaults so a
            // later manual recovery remains possible.
            backupExistingFile()
            return AppConfiguration()
        }
        configuration.migrate()
        return configuration
    }

    /// Writes the configuration and keeps a bounded history of previous versions.
    /// Throws so callers can surface a failure instead of silently losing edits.
    func save(_ configuration: AppConfiguration) throws {
        var configuration = configuration
        configuration.migrate()
        let data = try Self.encoder.encode(configuration)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        backupExistingFile()
        try data.write(to: fileURL, options: .atomic)
    }

    func export(_ configuration: AppConfiguration, to url: URL) throws {
        var configuration = configuration
        configuration.migrate()
        let data = try Self.encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    func `import`(from url: URL) throws -> AppConfiguration {
        var configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        configuration.migrate()
        return configuration
    }

    var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("json.bak")
    }

    var backupDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    func restoreBackup() throws -> AppConfiguration {
        guard hasBackup else { throw CocoaError(.fileNoSuchFile) }
        let configuration = try `import`(from: backupURL)
        try save(configuration)
        return configuration
    }

    private func backupExistingFile() {
        guard let current = try? Data(contentsOf: fileURL) else { return }
        try? FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)

        // The rolling `.bak` is what "恢复上次备份" restores, so it is always current.
        try? current.write(to: backupURL, options: .atomic)

        // The historical directory is capped, and content that is already archived
        // is not archived again, so repeated saves cannot grow it without bound.
        // The comparison checks every entry rather than only the newest one:
        // modification timestamps are not unique for rapid saves, so "newest"
        // cannot be relied on to identify the content that was last archived.
        let archived = historicalBackupURLs().contains { (try? Data(contentsOf: $0)) == current }
        if archived { return }
        // The timestamp prefix keeps the archive sorted chronologically; the
        // suffix keeps saves that land in the same microsecond distinct.
        let stamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let suffix = String(UUID().uuidString.prefix(8))
        let historicalURL = backupDirectoryURL.appendingPathComponent("configuration-\(stamp)-\(suffix).json")
        try? current.write(to: historicalURL, options: .atomic)
        for stale in historicalBackupURLs().dropFirst(Self.historicalBackupLimit) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Historical backups, newest first.
    private func historicalBackupURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("configuration-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    private static let historicalBackupLimit = 10

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
