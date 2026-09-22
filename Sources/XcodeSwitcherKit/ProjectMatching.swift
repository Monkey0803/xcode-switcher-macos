import Foundation

public struct ProjectLocalConfiguration: Codable, Equatable, Sendable {
    public let xcode: String?
    public let workspace: String?
}

public enum ProjectLocalConfigurationStore {
    public static func configurationURL(for projectURL: URL, fileManager: FileManager = .default) -> URL? {
        var directory = projectURL.deletingLastPathComponent().standardizedFileURL
        while true {
            let url = directory.appendingPathComponent(".xcode-switcher.json")
            if fileManager.fileExists(atPath: url.path) { return url }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory || directory.path == "/" { return nil }
            directory = parent
        }
    }

    public static func load(in directory: URL, fileManager: FileManager = .default) -> ProjectLocalConfiguration? {
        let url = directory.appendingPathComponent(".xcode-switcher.json")
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)
    }

    public static func load(for projectURL: URL, fileManager: FileManager = .default) -> ProjectLocalConfiguration? {
        guard let url = configurationURL(for: projectURL, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)
    }

    static func validationIssue(for projectURL: URL, fileManager: FileManager = .default) -> String? {
        guard let url = configurationURL(for: projectURL, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path),
              (try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)) == nil else { return nil }
        return String(localized: "项目配置文件格式无效，请检查：\(url.path)")
    }
    /// Writes `.xcode-switcher.json` next to the project. Other keys are preserved,
    /// so binding an Xcode never drops the workspace preference.
    ///
    /// Returns the URL written, or nil when the project has no directory to write
    /// into. `xcode` is a selector — identifier, path, name, alias or version — the
    /// same shapes `ProjectXcodeMatcher` resolves.
    @discardableResult
    public static func save(xcode: String, for projectURL: URL, fileManager: FileManager = .default) throws -> URL? {
        // configurationURL only answers when a configuration already exists further
        // up the tree, which is what we want to honour; a fresh project gets one
        // next to itself.
        let url = configurationURL(for: projectURL, fileManager: fileManager)
            ?? projectURL.deletingLastPathComponent().appendingPathComponent(".xcode-switcher.json")
        let existing = load(in: url.deletingLastPathComponent(), fileManager: fileManager)
        return try write(ProjectLocalConfiguration(xcode: xcode, workspace: existing?.workspace), to: url)
    }

    /// Removes the Xcode binding, keeping the file while it still holds a workspace.
    /// Returns true when a binding was actually removed.
    @discardableResult
    public static func clear(for projectURL: URL, fileManager: FileManager = .default) throws -> Bool {
        guard let url = configurationURL(for: projectURL, fileManager: fileManager),
              let existing = load(in: url.deletingLastPathComponent(), fileManager: fileManager),
              existing.xcode != nil else { return false }
        if existing.workspace == nil {
            try fileManager.removeItem(at: url)
        } else {
            _ = try write(ProjectLocalConfiguration(xcode: nil, workspace: existing.workspace), to: url)
        }
        return true
    }

    /// Sets or clears the workspace preference, keeping the Xcode binding. Writes
    /// the same file `save(xcode:)` does, and removes it when nothing is left to
    /// remember.
    @discardableResult
    public static func save(workspace: String?, for projectURL: URL, fileManager: FileManager = .default) throws -> URL? {
        let url = configurationURL(for: projectURL, fileManager: fileManager)
            ?? projectURL.deletingLastPathComponent().appendingPathComponent(".xcode-switcher.json")
        let existing = load(in: url.deletingLastPathComponent(), fileManager: fileManager)
        if workspace == nil, existing?.xcode == nil {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return nil
        }
        return try write(ProjectLocalConfiguration(xcode: existing?.xcode, workspace: workspace), to: url)
    }

    private static func write(_ configuration: ProjectLocalConfiguration, to url: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        return url
    }

}

public enum ProjectXcodeResolution: Equatable, Sendable {
    case resolved(installationID: String, source: ProjectXcodeResolutionSource)
    case missingProject(path: String)
    case missingBoundXcode(path: String)
    case missingRequiredXcode(ProjectXcodeRequirement)
    case invalidProjectConfiguration(path: String)
    case noInstallation

    public var installationID: String? {
        guard case let .resolved(installationID, _) = self else { return nil }
        return installationID
    }

    public var issueDescription: String? {
        switch self {
        case .resolved:
            return nil
        case let .missingProject(path):
            return String(localized: "项目路径已失效，请移除后重新添加：\(path)")
        case let .missingBoundXcode(path):
            return String(localized: "绑定的 Xcode 已不存在：\(URL(fileURLWithPath: path).lastPathComponent)。请重新绑定后再打开。")
        case let .missingRequiredXcode(requirement):
            return String(localized: "项目要求 Xcode \(requirement.normalizedVersion)，但本机未安装（来自 \(URL(fileURLWithPath: requirement.source).lastPathComponent)）。")
        case let .invalidProjectConfiguration(path):
            return String(localized: "项目配置文件格式无效，请检查：\(path)")
        case .noInstallation:
            return String(localized: "本机没有可用的 Xcode。")
        }
    }
}

public enum ProjectXcodeResolutionSource: Equatable, Sendable {
    case explicitBinding
    case localConfiguration(String)
    case automaticRequirement(ProjectXcodeRequirement)
    case currentInstallationFallback
    case firstInstallationFallback

    public var displayName: String {
        switch self {
        case .explicitBinding:
            return String(localized: "项目固定绑定")
        case .localConfiguration:
            return ".xcode-switcher.json"
        case let .automaticRequirement(requirement):
            return URL(fileURLWithPath: requirement.source).lastPathComponent
        case .currentInstallationFallback, .firstInstallationFallback:
            return String(localized: "默认选择")
        }
    }
}

public enum ProjectXcodeOpenDecision: Equatable, Sendable {
    case open(installationID: String)
    case requiresConfirmation(installationID: String, source: ProjectXcodeResolutionSource)
}

public enum ProjectXcodeMatcher {
    public static func openDecision(
        for resolution: ProjectXcodeResolution,
        activeInstallationID: String?
    ) -> ProjectXcodeOpenDecision? {
        guard case let .resolved(installationID, source) = resolution else { return nil }
        guard installationID != activeInstallationID else { return .open(installationID: installationID) }
        switch source {
        case .explicitBinding, .localConfiguration, .automaticRequirement:
            return .requiresConfirmation(installationID: installationID, source: source)
        case .currentInstallationFallback, .firstInstallationFallback:
            return .open(installationID: installationID)
        }
    }

    public static func requirement(for projectURL: URL, fileManager: FileManager = .default) -> ProjectXcodeRequirement? {
        let startDirectory = projectURL.hasDirectoryPath || ["xcodeproj", "xcworkspace"].contains(projectURL.pathExtension)
            ? projectURL.deletingLastPathComponent()
            : projectURL

        for directory in ancestorDirectories(startingAt: startDirectory) {
            let xcodeVersionURL = directory.appendingPathComponent(".xcode-version")
            if let value = firstMeaningfulLine(at: xcodeVersionURL, fileManager: fileManager),
               let normalized = normalizeVersion(value) {
                return ProjectXcodeRequirement(
                    source: xcodeVersionURL.path,
                    rawValue: value,
                    normalizedVersion: normalized
                )
            }

            let toolVersionsURL = directory.appendingPathComponent(".tool-versions")
            if let contents = try? String(contentsOf: toolVersionsURL, encoding: .utf8) {
                for line in contents.split(whereSeparator: \.isNewline) {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    guard fields.count >= 2, fields[0].lowercased() == "xcode" else { continue }
                    let value = String(fields[1])
                    if let normalized = normalizeVersion(value) {
                        return ProjectXcodeRequirement(
                            source: toolVersionsURL.path,
                            rawValue: value,
                            normalizedVersion: normalized
                        )
                    }
                }
            }
        }
        return nil
    }

    public static func match(
        projectURL: URL,
        installations: [XcodeInstallation],
        aliases: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> ProjectXcodeMatch? {
        guard let requirement = requirement(for: projectURL, fileManager: fileManager) else { return nil }
        let required = requirement.normalizedVersion
        let installation = installations.first { installation in
            version(installation.version, matches: required) ||
                normalizeVersion(installation.name).map { version($0, matches: required) } == true ||
                aliases[installation.id].flatMap(normalizeVersion).map { version($0, matches: required) } == true
        }
        return ProjectXcodeMatch(requirement: requirement, installationID: installation?.id)
    }

    public static func resolve(
        profile: ProjectProfile,
        installations: [XcodeInstallation],
        aliases: [String: String] = [:],
        activeInstallationID: String?,
        localConfiguration: ProjectLocalConfiguration? = nil,
        fileManager: FileManager = .default
    ) -> ProjectXcodeResolution {
        guard fileManager.fileExists(atPath: profile.path) else {
            return .missingProject(path: profile.path)
        }
        if ProjectLocalConfigurationStore.validationIssue(for: profile.url, fileManager: fileManager) != nil,
           let url = ProjectLocalConfigurationStore.configurationURL(for: profile.url, fileManager: fileManager) {
            return .invalidProjectConfiguration(path: url.path)
        }
        if let selector = localConfiguration?.xcode?.trimmingCharacters(in: .whitespacesAndNewlines), !selector.isEmpty {
            if let installation = installations.first(where: {
                $0.id == selector || $0.appURL.path == selector || $0.developerURL.path == selector ||
                    $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame ||
                    aliases[$0.id]?.localizedCaseInsensitiveCompare(selector) == .orderedSame
            }) {
                return .resolved(installationID: installation.id, source: .localConfiguration(selector))
            }
            if let required = normalizeVersion(selector) {
                return installations.first(where: { version($0.version, matches: required) })
                    .map { .resolved(installationID: $0.id, source: .localConfiguration(selector)) }
                    ?? .missingRequiredXcode(ProjectXcodeRequirement(
                        source: ProjectLocalConfigurationStore.configurationURL(for: profile.url, fileManager: fileManager)?.path
                            ?? profile.url.deletingLastPathComponent().appendingPathComponent(".xcode-switcher.json").path,
                        rawValue: selector,
                        normalizedVersion: required
                    ))
            }
            return .missingBoundXcode(path: selector)
        }
        if let boundID = profile.xcodeID {
            guard installations.contains(where: { $0.id == boundID }) else {
                return .missingBoundXcode(path: boundID)
            }
            return .resolved(installationID: boundID, source: .explicitBinding)
        }
        if let automaticMatch = match(
            projectURL: profile.url,
            installations: installations,
            aliases: aliases,
            fileManager: fileManager
        ) {
            guard let installationID = automaticMatch.installationID else {
                return .missingRequiredXcode(automaticMatch.requirement)
            }
            return .resolved(installationID: installationID, source: .automaticRequirement(automaticMatch.requirement))
        }
        if let activeInstallationID,
           installations.contains(where: { $0.id == activeInstallationID }) {
            return .resolved(installationID: activeInstallationID, source: .currentInstallationFallback)
        }
        guard let first = installations.first else { return .noInstallation }
        return .resolved(installationID: first.id, source: .firstInstallationFallback)
    }

    public static func normalizeVersion(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let pattern = #"(?i)(?:^|[^0-9])([0-9]+(?:\.[0-9]+){0,3})(?:[^0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    public static func version(_ installed: String, matches required: String) -> Bool {
        var lhs = installed.split(separator: ".").compactMap { Int($0) }
        var rhs = required.split(separator: ".").compactMap { Int($0) }
        guard !lhs.isEmpty, lhs.count == installed.split(separator: ".").count,
              !rhs.isEmpty, rhs.count == required.split(separator: ".").count else { return false }
        while lhs.last == 0 { lhs.removeLast() }
        while rhs.last == 0 { rhs.removeLast() }
        return lhs == rhs
    }

    private static func firstMeaningfulLine(at url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func ancestorDirectories(startingAt startURL: URL) -> [URL] {
        var directories: [URL] = []
        var current = startURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        for _ in 0..<12 {
            directories.append(current)
            if current == home || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return directories
    }
}

/// A version disagreement among projects referenced by one `.xcworkspace`.
/// Only explicit project requirements participate: a project that merely falls
/// back to the active Xcode must not turn a workspace into a false conflict.
public struct WorkspaceXcodeConflict: Equatable, Sendable {
    public struct Requirement: Equatable, Sendable, Identifiable {
        public let projectName: String
        public let version: String
        public let source: String
        /// The locally installed Xcode that satisfies this requirement. A
        /// missing requirement stays visible in the conflict warning, but it
        /// cannot be selected as the workspace's opening preference.
        public let installationID: String?

        public var id: String { "\(projectName)|\(version)|\(source)" }

        public init(
            projectName: String,
            version: String,
            source: String,
            installationID: String? = nil
        ) {
            self.projectName = projectName
            self.version = version
            self.source = source
            self.installationID = installationID
        }
    }

    public let workspaceURL: URL
    public let requirements: [Requirement]

    public var versions: [String] {
        Array(Set(requirements.map(\.version))).sorted { lhs, rhs in
            Self.isEarlier(lhs, than: rhs)
        }
    }

    public var hasConflict: Bool { versions.count > 1 }

    public init(workspaceURL: URL, requirements: [Requirement]) {
        self.workspaceURL = workspaceURL
        self.requirements = requirements
    }

    private static func isEarlier(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhsPart = index < left.count ? left[index] : 0
            let rhsPart = index < right.count ? right[index] : 0
            if lhsPart != rhsPart { return lhsPart < rhsPart }
        }
        return false
    }
}

/// Reads the projects a workspace references and resolves each project's local
/// Xcode requirement. This is intentionally separate from project opening:
/// detection never changes `DEVELOPER_DIR` or writes project files.
public enum WorkspaceXcodeConflictDetector {
    public static func conflict(
        in workspaceURL: URL,
        installations: [XcodeInstallation],
        aliases: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> WorkspaceXcodeConflict? {
        guard workspaceURL.pathExtension == "xcworkspace",
              fileManager.fileExists(atPath: workspaceURL.path),
              let contents = try? String(
                  contentsOf: workspaceURL.appendingPathComponent("contents.xcworkspacedata"),
                  encoding: .utf8
              )
        else { return nil }

        let projectURLs = referencedProjectURLs(in: contents, workspaceURL: workspaceURL)
        let requirements = projectURLs.compactMap { projectURL -> WorkspaceXcodeConflict.Requirement? in
            let profile = ProjectProfile(
                name: projectURL.deletingPathExtension().lastPathComponent,
                path: projectURL.path
            )
            let configurationURL = ProjectLocalConfigurationStore.configurationURL(for: projectURL, fileManager: fileManager)
            let localConfiguration = configurationURL.flatMap {
                ProjectLocalConfigurationStore.load(in: $0.deletingLastPathComponent(), fileManager: fileManager)
            }
            let resolution = ProjectXcodeMatcher.resolve(
                profile: profile,
                installations: installations,
                aliases: aliases,
                activeInstallationID: nil,
                localConfiguration: localConfiguration,
                fileManager: fileManager
            )
            switch resolution {
            case let .resolved(installationID, source):
                let hasExplicitRequirement: Bool
                switch source {
                case .localConfiguration, .automaticRequirement:
                    hasExplicitRequirement = true
                case .explicitBinding, .currentInstallationFallback, .firstInstallationFallback:
                    hasExplicitRequirement = false
                }
                guard hasExplicitRequirement,
                      let installation = installations.first(where: { $0.id == installationID })
                else { return nil }
                return WorkspaceXcodeConflict.Requirement(
                    projectName: profile.name,
                    version: installation.version,
                    source: source.displayName,
                    installationID: installation.id
                )
            case let .missingRequiredXcode(requirement):
                return WorkspaceXcodeConflict.Requirement(
                    projectName: profile.name,
                    version: requirement.normalizedVersion,
                    source: URL(fileURLWithPath: requirement.source).lastPathComponent
                )
            case .missingProject, .missingBoundXcode, .invalidProjectConfiguration, .noInstallation:
                return nil
            }
        }
        let conflict = WorkspaceXcodeConflict(workspaceURL: workspaceURL, requirements: requirements)
        return conflict.hasConflict ? conflict : nil
    }

    private static func referencedProjectURLs(in contents: String, workspaceURL: URL) -> [URL] {
        let pattern = #"location\s*=\s*\"(?:group:|container:)?([^\"]+\.xcodeproj)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(contents.startIndex..., in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            guard let locationRange = Range(match.range(at: 1), in: contents) else { return nil }
            return workspaceURL.deletingLastPathComponent()
                .appendingPathComponent(String(contents[locationRange]))
                .standardizedFileURL
        }
    }
}
