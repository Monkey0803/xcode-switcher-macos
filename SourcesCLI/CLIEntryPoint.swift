import AppKit
import Darwin
import Foundation

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case let .usage(message), let .failed(message): return message
        }
    }
}

/// Collects measurements from concurrent `du` runs. A box class because a
/// `@Sendable` closure may not mutate a captured local, and the prints have to be
/// serialized so interleaved output cannot happen.
private final class DiskUsageAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var xcodes: [DiskUsageReporter.Entry] = []
    private var runtimes: [DiskUsageReporter.Entry] = []

    /// `stream` prints the line as soon as it is measured: the bundles are measured
    /// in parallel, so waiting for all of them before printing gains nothing.
    func add(_ entry: DiskUsageReporter.Entry, isRuntime: Bool, stream: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isRuntime { runtimes.append(entry) } else { xcodes.append(entry) }
        if stream { print("  \(DiskUsageFormatter.humanReadable(bytes: entry.bytes))\t\(entry.label)") }
    }

    var xcodeEntries: [DiskUsageReporter.Entry] {
        lock.lock(); defer { lock.unlock() }
        return xcodes.sorted { $0.label < $1.label }
    }

    var runtimeEntries: [DiskUsageReporter.Entry] {
        lock.lock(); defer { lock.unlock() }
        return runtimes
    }
}

private struct XcodeSwitcherCLI {
    let configuration: AppConfiguration
    let installations: [XcodeInstallation]
    let activeDeveloperPath: String?

    init() {
        configuration = Self.loadConfiguration()
        installations = XcodeLocator.discover(searchPaths: configuration.customSearchPaths)
        activeDeveloperPath = XcodeLocator.activeDeveloperPath()
    }

    func run(arguments: [String]) throws -> Int32 {
        let options = try CLIOptions.parse(arguments)
        guard let command = options.command else {
            print(Self.help)
            return 0
        }
        let values = options.values
        switch command {
        case "help", "--help", "-h":
            print(Self.help)
            return 0
        case "version", "--version", "-v":
            print(Self.versionDescription)
            return 0
        case "pin":
            return try pinProject(options)
        case "unpin":
            return try unpinProject(options)
        case "sizes":
            return try sizes(options)
        case "clean":
            return try clean(options)
        case "workspace":
            return try setWorkspace(options)
        case "unworkspace":
            return try removeWorkspace(options)
        case "completions":
            return try printCompletions(options)
        case "alias":
            return try setAlias(options)
        case "unalias":
            return try removeAlias(options)
        case "list":
            list(json: options.json)
            return installations.isEmpty ? 1 : 0
        case "current":
            guard let active = installations.first(where: { $0.developerURL.path == activeDeveloperPath }) else {
                throw CLIError.failed(String(localized: "当前 Developer 目录未对应已发现的 Xcode：\(activeDeveloperPath ?? String(localized: "未配置"))"))
            }
            printInstallation(active, json: options.json)
            return 0
        case "resolve":
            let project = try projectURL(from: values)
            let resolution = resolve(project: project)
            if let issue = resolution.issueDescription { throw CLIError.failed(issue) }
            guard let id = resolution.installationID,
                  let installation = installations.first(where: { $0.id == id }) else {
                throw CLIError.failed(String(localized: "无法解析项目使用的 Xcode。"))
            }
            if options.json {
                printJSON(CLIResolveOutput(
                    installation: CLIInstallationOutput(
                        installation: installation,
                        active: installation.developerURL.path == activeDeveloperPath,
                        alias: configuration.xcodeAliases[installation.id]
                    ),
                    project: project.path,
                    requirementSource: ProjectLocalConfigurationStore.configurationURL(for: project)?.path
                        ?? ProjectXcodeMatcher.requirement(for: project)?.source
                ))
            } else {
                printInstallation(installation, json: false)
                let source = ProjectLocalConfigurationStore.configurationURL(for: project)?.path
                    ?? ProjectXcodeMatcher.requirement(for: project)?.source
                if let source { print("source=\(source)") }
            }
            return 0
        case "env":
            return try environment(values: values, json: options.json)
        case "shell-init":
            guard values.count == 1, values[0].lowercased() == "zsh" else {
                throw CLIError.usage(String(localized: "用法：xcodeswitcher shell-init zsh"))
            }
            print(ZshProjectEnvironmentHook.source, terminator: "")
            return 0
        case "doctor":
            let installation = try values.first.map(findInstallation) ?? activeOrFirst()
            let report = EnvironmentDoctor.inspect(
                installation: installation,
                activeDeveloperPath: activeDeveloperPath
            )
            if options.json {
                printJSON(report)
            } else {
                print(EnvironmentDoctor.render(report))
            }
            return report.highestSeverity == .error ? 2 : (report.issueCount > 0 ? 1 : 0)
        case "use":
            guard let selector = values.first else { throw CLIError.usage(String(localized: "用法：xcodeswitcher use <版本、别名或路径>")) }
            let installation = try findInstallation(selector)
            if options.dryRun {
                let output = CLIOperationOutput(
                    action: "use",
                    installation: CLIInstallationOutput(
                        installation: installation,
                        active: installation.developerURL.path == activeDeveloperPath,
                        alias: configuration.xcodeAliases[installation.id]
                    ),
                    project: nil,
                    dryRun: true
                )
                if options.json { printJSON(output) } else { print(String(localized: "[dry-run] 将激活 \(installation.name) \(installation.displayVersion)")) }
                return 0
            }
            if installation.developerURL.path != activeDeveloperPath {
                let running = XcodeProcessInspector.runningInstallations(among: installations)
                if !running.isEmpty, !options.force {
                    let names = running.map { "\($0.name) \($0.displayVersion)" }.joined(separator: "、")
                    throw CLIError.failed(String(localized: "Xcode 正在运行（\(names)）。切换会改变它正在使用的工具链，确认请加 --force。"))
                }
                try XcodeActivator.activate(installation)
            }
            guard XcodeLocator.activeDeveloperPath() == installation.developerURL.path else {
                throw CLIError.failed(String(localized: "切换命令完成，但 Developer 目录验证失败。"))
            }
            print(String(localized: "已激活 \(installation.name) \(installation.displayVersion)"))
            return 0
        case "open":
            let project = try projectURL(from: values)
            let resolution = resolve(project: project)
            if let issue = resolution.issueDescription { throw CLIError.failed(issue) }
            guard let id = resolution.installationID,
                  let installation = installations.first(where: { $0.id == id }) else {
                throw CLIError.failed(String(localized: "无法解析项目使用的 Xcode。"))
            }
            if options.dryRun {
                let output = CLIOperationOutput(
                    action: "open",
                    installation: CLIInstallationOutput(
                        installation: installation,
                        active: installation.developerURL.path == activeDeveloperPath,
                        alias: configuration.xcodeAliases[installation.id]
                    ),
                    project: project.path,
                    dryRun: true
                )
                if options.json { printJSON(output) } else { print(String(localized: "[dry-run] 将使用 \(installation.name) 打开 \(project.path)")) }
                return 0
            }
            if installation.developerURL.path != activeDeveloperPath {
                try XcodeActivator.activate(installation)
            }
            XcodeActions.open(project, with: installation)
            print(String(localized: "已使用 \(installation.name) 打开 \(project.lastPathComponent)"))
            return 0
        default:
            throw CLIError.usage("\(String(localized: "未知命令：\(command)"))\n\n\(Self.help)")
        }
    }

    private func environment(values: [String], json: Bool) throws -> Int32 {
        let inputURL: URL
        if let path = values.first {
            inputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            inputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        }
        if values.first != nil,
           ["xcodeproj", "xcworkspace"].contains(inputURL.pathExtension),
           !FileManager.default.fileExists(atPath: inputURL.path) {
            throw CLIError.failed(String(localized: "项目路径已失效，请移除后重新添加：\(inputURL.path)"))
        }
        switch ProjectDirectoryLocator.resolve(startingAt: inputURL) {
        case .none:
            if json {
                printJSON(CLIEnvironmentOutput(project: nil, developer: nil, restoreOriginal: true))
            } else {
                print(ProjectEnvironmentOutput.restoreOriginal.shellSource)
            }
            return 0
        case let .ambiguous(directory):
            throw CLIError.failed(String(localized: "目录包含多个 Xcode 项目，请显式指定项目路径：\(directory)"))
        case let .project(project):
            let savedProfile = configuration.projects.first {
                $0.url.standardizedFileURL == project.standardizedFileURL
            }
            let profile = savedProfile ?? ProjectProfile(
                name: project.deletingPathExtension().lastPathComponent,
                path: project.path
            )
            let activeID = installations.first { $0.developerURL.path == activeDeveloperPath }?.id
            let result = ProjectEnvironmentResolver.resolve(
                for: profile,
                installations: installations,
                aliases: configuration.xcodeAliases,
                activeInstallationID: activeID,
                localConfiguration: ProjectLocalConfigurationStore.load(for: project)
            )
            switch result {
            case let .issue(message): throw CLIError.failed(message)
            case let .output(output):
                if json {
                    let developer: String?
                    switch output {
                    case let .exportDeveloperDirectory(path): developer = path
                    case .restoreOriginal: developer = nil
                    }
                    printJSON(CLIEnvironmentOutput(
                        project: project.path,
                        developer: developer,
                        restoreOriginal: output == .restoreOriginal
                    ))
                } else {
                    print(output.shellSource)
                }
                return 0
            }
        }
    }

    private func list(json: Bool) {
        if json {
            printJSON(installations.map {
                CLIInstallationOutput(
                    installation: $0,
                    active: $0.developerURL.path == activeDeveloperPath,
                    alias: configuration.xcodeAliases[$0.id]
                )
            })
            return
        }
        for installation in installations {
            let active = installation.developerURL.path == activeDeveloperPath ? "*" : " "
            let alias = configuration.xcodeAliases[installation.id].map { " alias=\($0)" } ?? ""
            print("\(active) \(installation.displayVersion)\t\(installation.appURL.path)\(alias)")
        }
    }

    private func printInstallation(_ installation: XcodeInstallation, json: Bool) {
        if json {
            printJSON(CLIInstallationOutput(
                installation: installation,
                active: installation.developerURL.path == activeDeveloperPath,
                alias: configuration.xcodeAliases[installation.id]
            ))
            return
        }
        print("name=\(installation.name)")
        print("version=\(installation.version)")
        print("build=\(installation.build)")
        print("app=\(installation.appURL.path)")
        print("developer=\(installation.developerURL.path)")
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    }

    private func setWorkspace(_ options: CLIOptions) throws -> Int32 {
        guard let name = options.values.first else {
            throw CLIError.usage(String(localized: "用法：xcodeswitcher workspace <工作区文件名> [项目路径]"))
        }
        let project = try boundProjectURL(from: Array(options.values.dropFirst()))
        let label = project.lastPathComponent
        guard FileManager.default.fileExists(atPath: project.deletingLastPathComponent().appendingPathComponent(name).path) else {
            throw CLIError.failed(String(localized: "未找到工作区文件：\(name)"))
        }
        let confirmation = String(localized: "已把 \(label) 的工作区设为 \(name)。")
        if options.dryRun {
            print("[dry-run] " + confirmation)
            return 0
        }
        _ = try ProjectLocalConfigurationStore.save(workspace: name, for: project)
        print(confirmation)
        return 0
    }

    private func removeWorkspace(_ options: CLIOptions) throws -> Int32 {
        let project = try boundProjectURL(from: options.values)
        let label = project.lastPathComponent
        guard ProjectLocalConfigurationStore.load(for: project)?.workspace != nil else {
            throw CLIError.failed(String(localized: "\(label) 没有工作区绑定。"))
        }
        let confirmation = String(localized: "已移除 \(label) 的工作区绑定。")
        if options.dryRun {
            print("[dry-run] " + confirmation)
            return 0
        }
        _ = try ProjectLocalConfigurationStore.save(workspace: nil, for: project)
        print(confirmation)
        return 0
    }

    private func printCompletions(_ options: CLIOptions) throws -> Int32 {
        guard let shell = options.values.first?.lowercased(), let script = Self.completionScripts[shell] else {
            throw CLIError.usage(String(localized: "用法：xcodeswitcher completions <zsh|bash|fish>"))
        }
        print(script)
        return 0
    }

    /// Completion scripts are plain shell, so they need no translation. Zsh and
    /// bash complete the subcommand list; fish is one line by design.
    private static let completionScripts: [String: String] = [
        "zsh": """
        #compdef xcodeswitcher
        _xcodeswitcher() {
          local -a commands
          commands=(list version sizes alias unalias current resolve env shell-init doctor use pin unpin open workspace unworkspace completions)
          (( CURRENT == 2 )) && compadd -a commands
        }
        compdef _xcodeswitcher xcodeswitcher
        """,
        "bash": """
        _xcodeswitcher() {
          local commands="list version sizes alias unalias current resolve env shell-init doctor use pin unpin open workspace unworkspace completions"
          [ "$COMP_CWORD" -eq 1 ] && COMPREPLY=( $(compgen -W "$commands" -- "${COMP_WORDS[COMP_CWORD]}") )
        }
        complete -F _xcodeswitcher xcodeswitcher
        """,
        "fish": """
        complete -c xcodeswitcher -f
        complete -c xcodeswitcher -n '__fish_use_subcommand' -a 'list version sizes alias unalias current resolve env shell-init doctor use pin unpin open workspace unworkspace completions'
        """,
    ]

    /// Aliases live in the app configuration, which is the same file the app
    /// writes; the CLI only reads it elsewhere.
    private func setAlias(_ options: CLIOptions) throws -> Int32 {
        guard options.values.count >= 2 else {
            throw CLIError.usage(String(localized: "用法：xcodeswitcher alias <别名> <版本、别名或路径>"))
        }
        let alias = options.values[0]
        let installation = try findInstallation(options.values[1])
        let label = "\(installation.name) \(installation.displayVersion)"

        // The matcher compares aliases case-insensitively, so a duplicate would
        // make one of them unreachable.
        if let clash = configuration.xcodeAliases.first(where: {
            $0.key != installation.id && $0.value.localizedCaseInsensitiveCompare(alias) == .orderedSame
        }) {
            let owner = installations.first { $0.id == clash.key }
                .map { "\($0.name) \($0.displayVersion)" } ?? clash.value
            throw CLIError.failed(String(localized: "别名 \(alias) 已被 \(owner) 使用。"))
        }

        if options.dryRun {
            print("[dry-run] " + String(localized: "已将 \(label) 的别名设为 \(alias)。"))
            return 0
        }
        var updated = configuration
        updated.xcodeAliases[installation.id] = alias
        try saveConfiguration(updated)
        print(String(localized: "已将 \(label) 的别名设为 \(alias)。"))
        return 0
    }

    private func removeAlias(_ options: CLIOptions) throws -> Int32 {
        guard let selector = options.values.first else {
            throw CLIError.usage(String(localized: "用法：xcodeswitcher unalias <版本、别名或路径>"))
        }
        let installation = try findInstallation(selector)
        let label = "\(installation.name) \(installation.displayVersion)"
        guard configuration.xcodeAliases[installation.id] != nil else {
            throw CLIError.failed(String(localized: "\(label) 没有别名。"))
        }
        if options.dryRun {
            print("[dry-run] " + String(localized: "已移除 \(label) 的别名。"))
            return 0
        }
        var updated = configuration
        updated.xcodeAliases.removeValue(forKey: installation.id)
        try saveConfiguration(updated)
        print(String(localized: "已移除 \(label) 的别名。"))
        return 0
    }

    private func saveConfiguration(_ configuration: AppConfiguration) throws {
        do {
            try AppConfigurationStore().save(configuration)
        } catch {
            throw CLIError.failed(String(localized: "写入应用配置失败：\(error.localizedDescription)"))
        }
    }

    private func sizes(_ options: CLIOptions) throws -> Int32 {
        let selected = try options.values.first.map { [try findInstallation($0)] } ?? installations
        let stream = !options.json

        // Measured on three Xcodes: 8.4s sequentially, 1.7s in parallel — `du` is
        // traversal-bound, so the slowest bundle gates the wait instead of the sum.
        // simctl reports runtime sizes itself and costs no traversal, so it runs
        // alongside them.
        let accumulator = DiskUsageAccumulator()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.yostar.xcodeswitcher.sizes", attributes: .concurrent)

        if stream { print(String(localized: "Xcode 安装")) }
        for installation in selected {
            group.enter()
            queue.async {
                defer { group.leave() }
                guard let bytes = DiskUsageReporter.allocatedBytes(ofPath: installation.appURL.path) else { return }
                accumulator.add(
                    DiskUsageReporter.Entry(
                        label: "\(installation.name) \(installation.displayVersion)",
                        path: installation.appURL.path,
                        bytes: bytes
                    ),
                    isRuntime: false,
                    stream: stream
                )
            }
        }
        group.enter()
        queue.async {
            defer { group.leave() }
            for runtime in DiskUsageReporter.simulatorRuntimes() {
                accumulator.add(
                    DiskUsageReporter.Entry(label: runtime.label, path: runtime.path, bytes: runtime.bytes),
                    isRuntime: true,
                    stream: false
                )
            }
        }
        group.wait()

        let xcodes = accumulator.xcodeEntries
        let runtimes = accumulator.runtimeEntries
        let total = (xcodes + runtimes).reduce(Int64(0)) { $0 + $1.bytes }

        if options.json {
            func output(_ entries: [DiskUsageReporter.Entry]) -> [CLIDiskUsageOutput.Entry] {
                entries.map {
                    CLIDiskUsageOutput.Entry(
                        label: $0.label,
                        path: $0.path,
                        bytes: $0.bytes,
                        size: DiskUsageFormatter.humanReadable(bytes: $0.bytes)
                    )
                }
            }
            printJSON(CLIDiskUsageOutput(
                installations: output(xcodes),
                runtimes: output(runtimes),
                totalBytes: total,
                total: DiskUsageFormatter.humanReadable(bytes: total)
            ))
            return 0
        }

        // The Xcode lines already streamed; the rest prints once everything is in.
        if !runtimes.isEmpty {
            print(String(localized: "模拟器运行时"))
            for entry in runtimes {
                print("  \(DiskUsageFormatter.humanReadable(bytes: entry.bytes))\t\(entry.label)")
            }
        }
        // A path that cannot be measured is reported rather than silently dropped,
        // so an incomplete total is never mistaken for a complete one.
        let unmeasured = selected.count + runtimes.count - xcodes.count - runtimes.count
        if unmeasured > 0 {
            print(String(localized: "无法读取占用：\(unmeasured)"))
        }
        print(String(localized: "合计：\(DiskUsageFormatter.humanReadable(bytes: total))"))
        return 0
    }

    /// The CLI's only destructive command, so it previews by default: removal needs
    /// an explicit `--force`, and the entries Xcode cannot rebuild on its own (an
    /// archive, device support, a package cache) need `--all` as well. `.safe`
    /// entries are deleted outright; `.caution` ones go to the Trash, as in the app.
    private func clean(_ options: CLIOptions) throws -> Int32 {
        let candidates = XcodeCleanupReporter.entries()
        let selected = options.all ? candidates : candidates.filter { $0.safety == .safe }
        let skipped = options.all ? [] : candidates.filter { $0.safety == .caution }
        let total = selected.reduce(Int64(0)) { $0 + $1.bytes }
        let performed = options.force && !options.dryRun

        var removed: [XcodeCleanupEntry] = []
        var failures: [String] = []
        if performed {
            for entry in selected {
                do {
                    try XcodeCleanupReporter.remove(entry)
                    removed.append(entry)
                } catch {
                    failures.append("\(entry.label): \(error.localizedDescription)")
                }
            }
        }

        if options.json {
            printJSON(CLICleanupOutput(
                entries: selected.map {
                    CLICleanupOutput.Entry(
                        label: $0.label,
                        path: $0.path,
                        bytes: $0.bytes,
                        size: $0.displaySize,
                        safety: $0.safety == .safe ? "safe" : "caution"
                    )
                },
                removed: removed.map(\.label),
                skipped: skipped.map(\.label),
                failures: failures,
                totalBytes: total,
                total: DiskUsageFormatter.humanReadable(bytes: total),
                performed: performed
            ))
            return failures.isEmpty ? 0 : 1
        }

        guard !selected.isEmpty else {
            print(String(localized: "未发现可清理目录。"))
            return 0
        }

        for entry in selected {
            print("  \(entry.displaySize)\t\(entry.label)  [\(entry.safety.title)]")
        }
        print(String(localized: "共 \(selected.count) 个目录，可释放约 \(DiskUsageFormatter.humanReadable(bytes: total))。"))
        if !skipped.isEmpty {
            print(String(localized: "已跳过 \(skipped.count) 项 Xcode 无法自动重建的内容；加 --all 会将它们移到废纸篓。"))
        }

        guard performed else {
            print(String(localized: "[dry-run] 未删除任何内容；加 --force 才会真正清理。"))
            return 0
        }

        for entry in removed {
            switch entry.safety {
            case .safe: print(String(localized: "已清理 \(entry.label)。"))
            case .caution: print(String(localized: "已移到废纸篓：\(entry.label)。"))
            }
        }
        for failure in failures {
            FileHandle.standardError.write(Data((String(localized: "清理失败：\(failure)") + "\n").utf8))
        }
        return failures.isEmpty ? 0 : 1
    }

    /// The project to bind: an explicit path, or the project in the current directory.
    private func boundProjectURL(from values: [String]) throws -> URL {
        guard let path = values.first else {
            let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            switch ProjectDirectoryLocator.resolve(startingAt: here) {
            case let .project(url):
                return url.standardizedFileURL
            case .ambiguous:
                throw CLIError.failed(String(localized: "目录包含多个 Xcode 项目，请显式指定项目路径：\(FileManager.default.currentDirectoryPath)"))
            case .none:
                throw CLIError.failed(String(localized: "当前目录下未找到 Xcode 项目，请显式指定项目路径。"))
            }
        }
        return try projectURL(from: [path])
    }

    private func pinProject(_ options: CLIOptions) throws -> Int32 {
        guard let selector = options.values.first else {
            throw CLIError.usage(String(localized: "用法：xcodeswitcher pin <版本、别名或路径> [项目路径]"))
        }
        let installation = try findInstallation(selector)
        let project = try boundProjectURL(from: Array(options.values.dropFirst()))
        if options.dryRun {
            print(String(localized: "[dry-run] 将把 \(project.lastPathComponent) 绑定到 \(installation.name) \(installation.displayVersion)"))
            return 0
        }
        guard try ProjectLocalConfigurationStore.save(xcode: selector, for: project) != nil else {
            throw CLIError.failed(String(localized: "无法写入项目绑定：项目没有可写入的目录。"))
        }
        print(String(localized: "已将 \(project.lastPathComponent) 绑定到 \(installation.name) \(installation.displayVersion)。"))
        return 0
    }

    private func unpinProject(_ options: CLIOptions) throws -> Int32 {
        let project = try boundProjectURL(from: options.values)
        if options.dryRun {
            print("[dry-run] " + String(localized: "已解除 %@ 的项目绑定。"))
            return 0
        }
        guard try ProjectLocalConfigurationStore.clear(for: project) else {
            throw CLIError.failed(String(localized: "\(project.lastPathComponent) 没有项目绑定。"))
        }
        print(String(localized: "已解除 %@ 的项目绑定。"))
        return 0
    }

    private func projectURL(from values: [String]) throws -> URL {
        guard let path = values.first else { throw CLIError.usage(String(localized: "缺少项目路径。")) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard ["xcodeproj", "xcworkspace"].contains(url.pathExtension) else {
            throw CLIError.usage(String(localized: "请选择 .xcodeproj 或 .xcworkspace。"))
        }
        return url
    }

    private func resolve(project: URL) -> ProjectXcodeResolution {
        let savedProfile = configuration.projects.first { $0.url.standardizedFileURL == project.standardizedFileURL }
        let profile = savedProfile ?? ProjectProfile(
            name: project.deletingPathExtension().lastPathComponent,
            path: project.path
        )
        let activeID = installations.first { $0.developerURL.path == activeDeveloperPath }?.id
        return ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: installations,
            aliases: configuration.xcodeAliases,
            activeInstallationID: activeID,
            localConfiguration: ProjectLocalConfigurationStore.load(for: project)
        )
    }

    private func activeOrFirst() throws -> XcodeInstallation {
        if let active = installations.first(where: { $0.developerURL.path == activeDeveloperPath }) { return active }
        guard let first = installations.first else { throw CLIError.failed(String(localized: "未发现 Xcode。")) }
        return first
    }

    private func findInstallation(_ selector: String) throws -> XcodeInstallation {
        let expanded = (selector as NSString).expandingTildeInPath
        if let exact = installations.first(where: {
            $0.id == expanded || $0.developerURL.path == expanded ||
                $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame ||
                configuration.xcodeAliases[$0.id]?.localizedCaseInsensitiveCompare(selector) == .orderedSame
        }) {
            return exact
        }
        if let version = ProjectXcodeMatcher.normalizeVersion(selector),
           let match = installations.first(where: { ProjectXcodeMatcher.version($0.version, matches: version) }) {
            return match
        }
        throw CLIError.failed(String(localized: "未找到 Xcode：\(selector)"))
    }

    private static func loadConfiguration() -> AppConfiguration {
        AppConfigurationStore.shared.load()
    }

    /// Read from the enclosing app bundle, which is where this tool lives. A copy
    /// that was moved out of it reports "unknown" instead of guessing.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    static let help = String(localized: """
    Xcode Switcher CLI

    用法：
      xcodeswitcher [--json] list
      xcodeswitcher version
      xcodeswitcher sizes [版本、别名或路径]
      xcodeswitcher clean [--force] [--all]
      xcodeswitcher workspace <工作区文件名> [项目路径]
      xcodeswitcher unworkspace [项目路径]
      xcodeswitcher completions <zsh|bash|fish>
      xcodeswitcher alias <别名> <版本、别名或路径>
      xcodeswitcher unalias <版本、别名或路径>
      xcodeswitcher [--json] current
      xcodeswitcher [--json] resolve <project.xcodeproj|workspace.xcworkspace>
      xcodeswitcher [--json] env [目录或项目路径]
      xcodeswitcher shell-init zsh
      xcodeswitcher [--json] doctor [版本、别名或路径]
      xcodeswitcher [--json] use [--dry-run] <版本、别名或路径>
      xcodeswitcher pin <版本、别名或路径> [项目路径]
      xcodeswitcher unpin [项目路径]
      xcodeswitcher [--json] open [--dry-run] <project.xcodeproj|workspace.xcworkspace>

    --json 输出机器可读 JSON；--dry-run 仅显示将执行的切换/打开动作。
    --force 即使有 Xcode 正在运行也继续切换；clean 则用它表示真正执行清理。
    clean 默认只预览并列出可直接清理的缓存；--all 会一并处理 Xcode 无法自动
    重建的内容（归档、真机支持、包缓存），这些会移到废纸篓。clean 不处理
    Simulator Runtime，请在应用中清理。
    env 和 shell-init zsh 只读取项目环境，不会修改 xcode-select。
    """)
}

@main
private struct XcodeSwitcherCLIEntryPoint {
    /// A symlink installed outside the bundle — by a package manager, for example —
    /// makes Foundation derive `Bundle.main` from the invocation path, so every
    /// `String(localized:)` silently falls back to the source language. Re-exec
    /// through the resolved path once so the whole process, including the shared
    /// sources the CLI prints, sees the app bundle. `execv` replaces the process,
    /// so there is no second run to loop.
    private static func reexecThroughAppBundleIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }

        // `Bundle.main.executableURL` is nil precisely in the case that matters — a
        // process outside a bundle — so ask the kernel for the invocation path and
        // resolve the symlink ourselves.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(PATH_MAX)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()

        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                var arguments = ProcessInfo.processInfo.arguments
                arguments[0] = executable.path
                // The array must be passed by reference: `execv` takes a mutable
                // pointer, and a bridged temporary would not carry the NULs.
                var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
                argv.append(nil)
                execv(executable.path, &argv)
                return
            }
            directory = directory.deletingLastPathComponent()
        }
    }

    static func main() {
        reexecThroughAppBundleIfNeeded()
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        do {
            let status = try XcodeSwitcherCLI().run(arguments: arguments)
            exit(status)
        } catch {
            let message = (error as? CLIError)?.description ?? error.localizedDescription
            if arguments.contains("--json") {
                let code: String
                if case CLIError.usage = error { code = "usage" } else { code = "failed" }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let output = CLIErrorOutput(code: code, message: message)
                if let data = try? encoder.encode(output) {
                    FileHandle.standardError.write(data)
                    FileHandle.standardError.write(Data("\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data((String(localized: "错误：\(message)") + "\n").utf8))
            }
            exit(2)
        }
    }
}
