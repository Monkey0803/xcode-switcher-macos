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
        case "list":
            list(json: options.json)
            return installations.isEmpty ? 1 : 0
        case "current":
            guard let active = installations.first(where: { $0.developerURL.path == activeDeveloperPath }) else {
                throw CLIError.failed("当前 Developer 目录未对应已发现的 Xcode：\(activeDeveloperPath ?? "未配置")")
            }
            printInstallation(active, json: options.json)
            return 0
        case "resolve":
            let project = try projectURL(from: values)
            let resolution = resolve(project: project)
            if let issue = resolution.issueDescription { throw CLIError.failed(issue) }
            guard let id = resolution.installationID,
                  let installation = installations.first(where: { $0.id == id }) else {
                throw CLIError.failed("无法解析项目使用的 Xcode。")
            }
            if options.json {
                printJSON(CLIResolveOutput(
                    installation: CLIInstallationOutput(
                        installation: installation,
                        active: installation.developerURL.path == activeDeveloperPath,
                        alias: configuration.xcodeAliases[installation.id]
                    ),
                    project: project.path,
                    requirementSource: ProjectXcodeMatcher.requirement(for: project)?.source
                ))
            } else {
                printInstallation(installation, json: false)
                if let requirement = ProjectXcodeMatcher.requirement(for: project) {
                    print("source=\(requirement.source)")
                }
            }
            return 0
        case "env":
            return try environment(values: values, json: options.json)
        case "shell-init":
            guard values.count == 1, values[0].lowercased() == "zsh" else {
                throw CLIError.usage("用法：xcodeswitcher shell-init zsh")
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
            guard let selector = values.first else { throw CLIError.usage("用法：xcodeswitcher use <版本、别名或路径>") }
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
                if options.json { printJSON(output) } else { print("[dry-run] 将激活 \(installation.name) \(installation.displayVersion)") }
                return 0
            }
            if installation.developerURL.path != activeDeveloperPath {
                try XcodeActivator.activate(installation)
            }
            guard XcodeLocator.activeDeveloperPath() == installation.developerURL.path else {
                throw CLIError.failed("切换命令完成，但 Developer 目录验证失败。")
            }
            print("已激活 \(installation.name) \(installation.displayVersion)")
            return 0
        case "open":
            let project = try projectURL(from: values)
            let resolution = resolve(project: project)
            if let issue = resolution.issueDescription { throw CLIError.failed(issue) }
            guard let id = resolution.installationID,
                  let installation = installations.first(where: { $0.id == id }) else {
                throw CLIError.failed("无法解析项目使用的 Xcode。")
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
                if options.json { printJSON(output) } else { print("[dry-run] 将使用 \(installation.name) 打开 \(project.path)") }
                return 0
            }
            if installation.developerURL.path != activeDeveloperPath {
                try XcodeActivator.activate(installation)
            }
            XcodeActions.open(project, with: installation)
            print("已使用 \(installation.name) 打开 \(project.lastPathComponent)")
            return 0
        default:
            throw CLIError.usage("未知命令：\(command)\n\n\(Self.help)")
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
            throw CLIError.failed("项目路径已失效，请移除后重新添加：\(inputURL.path)")
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
            throw CLIError.failed("目录包含多个 Xcode 项目，请显式指定项目路径：\(directory)")
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
                activeInstallationID: activeID
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

    private func projectURL(from values: [String]) throws -> URL {
        guard let path = values.first else { throw CLIError.usage("缺少项目路径。") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard ["xcodeproj", "xcworkspace"].contains(url.pathExtension) else {
            throw CLIError.usage("请选择 .xcodeproj 或 .xcworkspace。")
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
            activeInstallationID: activeID
        )
    }

    private func activeOrFirst() throws -> XcodeInstallation {
        if let active = installations.first(where: { $0.developerURL.path == activeDeveloperPath }) { return active }
        guard let first = installations.first else { throw CLIError.failed("未发现 Xcode。") }
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
        throw CLIError.failed("未找到 Xcode：\(selector)")
    }

    private static func loadConfiguration() -> AppConfiguration {
        AppConfigurationStore.shared.load()
    }

    static let help = """
    Xcode Switcher CLI

    用法：
      xcodeswitcher [--json] list
      xcodeswitcher [--json] current
      xcodeswitcher [--json] resolve <project.xcodeproj|workspace.xcworkspace>
      xcodeswitcher [--json] env [目录或项目路径]
      xcodeswitcher shell-init zsh
      xcodeswitcher [--json] doctor [版本、别名或路径]
      xcodeswitcher [--json] use [--dry-run] <版本、别名或路径>
      xcodeswitcher [--json] open [--dry-run] <project.xcodeproj|workspace.xcworkspace>

    --json 输出机器可读 JSON；--dry-run 仅显示将执行的切换/打开动作。
    env 和 shell-init zsh 只读取项目环境，不会修改 xcode-select。
    """
}

@main
private struct XcodeSwitcherCLIEntryPoint {
    static func main() {
        do {
            let status = try XcodeSwitcherCLI().run(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))
            exit(status)
        } catch {
            FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
            exit(2)
        }
    }
}
