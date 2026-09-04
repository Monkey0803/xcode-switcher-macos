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
        guard let command = arguments.first else {
            print(Self.help)
            return 0
        }
        let values = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            print(Self.help)
            return 0
        case "list":
            list()
            return installations.isEmpty ? 1 : 0
        case "current":
            guard let active = installations.first(where: { $0.developerURL.path == activeDeveloperPath }) else {
                throw CLIError.failed("当前 Developer 目录未对应已发现的 Xcode：\(activeDeveloperPath ?? "未配置")")
            }
            printInstallation(active)
            return 0
        case "resolve":
            let project = try projectURL(from: values)
            let resolution = resolve(project: project)
            if let issue = resolution.issueDescription { throw CLIError.failed(issue) }
            guard let id = resolution.installationID,
                  let installation = installations.first(where: { $0.id == id }) else {
                throw CLIError.failed("无法解析项目使用的 Xcode。")
            }
            printInstallation(installation)
            if let requirement = ProjectXcodeMatcher.requirement(for: project) {
                print("source=\(requirement.source)")
            }
            return 0
        case "doctor":
            let installation = try values.first.map(findInstallation) ?? activeOrFirst()
            let report = EnvironmentDoctor.inspect(
                installation: installation,
                activeDeveloperPath: activeDeveloperPath
            )
            print(EnvironmentDoctor.render(report))
            return report.highestSeverity == .error ? 2 : (report.issueCount > 0 ? 1 : 0)
        case "use":
            guard let selector = values.first else { throw CLIError.usage("用法：xcodeswitcher use <版本、别名或路径>") }
            let installation = try findInstallation(selector)
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

    private func list() {
        for installation in installations {
            let active = installation.developerURL.path == activeDeveloperPath ? "*" : " "
            let alias = configuration.xcodeAliases[installation.id].map { " alias=\($0)" } ?? ""
            print("\(active) \(installation.displayVersion)\t\(installation.appURL.path)\(alias)")
        }
    }

    private func printInstallation(_ installation: XcodeInstallation) {
        print("name=\(installation.name)")
        print("version=\(installation.version)")
        print("build=\(installation.build)")
        print("app=\(installation.appURL.path)")
        print("developer=\(installation.developerURL.path)")
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("XcodeSwitcher/configuration.json")
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return configuration
    }

    static let help = """
    Xcode Switcher CLI

    用法：
      xcodeswitcher list
      xcodeswitcher current
      xcodeswitcher resolve <project.xcodeproj|workspace.xcworkspace>
      xcodeswitcher doctor [版本、别名或路径]
      xcodeswitcher use <版本、别名或路径>
      xcodeswitcher open <project.xcodeproj|workspace.xcworkspace>
    """
}

do {
    let status = try XcodeSwitcherCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(status)
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(2)
}
