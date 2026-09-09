import Foundation

struct ProjectLocalConfiguration: Codable, Equatable, Sendable {
    let xcode: String?
    let workspace: String?
}

enum ProjectLocalConfigurationStore {
    static func configurationURL(for projectURL: URL, fileManager: FileManager = .default) -> URL? {
        var directory = projectURL.deletingLastPathComponent().standardizedFileURL
        while true {
            let url = directory.appendingPathComponent(".xcode-switcher.json")
            if fileManager.fileExists(atPath: url.path) { return url }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory || directory.path == "/" { return nil }
            directory = parent
        }
    }

    static func load(in directory: URL, fileManager: FileManager = .default) -> ProjectLocalConfiguration? {
        let url = directory.appendingPathComponent(".xcode-switcher.json")
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)
    }

    static func load(for projectURL: URL, fileManager: FileManager = .default) -> ProjectLocalConfiguration? {
        guard let url = configurationURL(for: projectURL, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)
    }

    static func validationIssue(for projectURL: URL, fileManager: FileManager = .default) -> String? {
        guard let url = configurationURL(for: projectURL, fileManager: fileManager),
              let data = fileManager.contents(atPath: url.path),
              (try? JSONDecoder().decode(ProjectLocalConfiguration.self, from: data)) == nil else { return nil }
        return "项目配置文件格式无效，请检查：\(url.path)"
    }
}

enum ProjectXcodeResolution: Equatable, Sendable {
    case resolved(installationID: String, source: ProjectXcodeResolutionSource)
    case missingProject(path: String)
    case missingBoundXcode(path: String)
    case missingRequiredXcode(ProjectXcodeRequirement)
    case invalidProjectConfiguration(path: String)
    case noInstallation

    var installationID: String? {
        guard case let .resolved(installationID, _) = self else { return nil }
        return installationID
    }

    var issueDescription: String? {
        switch self {
        case .resolved:
            return nil
        case let .missingProject(path):
            return "项目路径已失效，请移除后重新添加：\(path)"
        case let .missingBoundXcode(path):
            return "绑定的 Xcode 已不存在：\(URL(fileURLWithPath: path).lastPathComponent)。请重新绑定后再打开。"
        case let .missingRequiredXcode(requirement):
            return "项目要求 Xcode \(requirement.normalizedVersion)，但本机未安装（来自 \(URL(fileURLWithPath: requirement.source).lastPathComponent)）。"
        case let .invalidProjectConfiguration(path):
            return "项目配置文件格式无效，请检查：\(path)"
        case .noInstallation:
            return "本机没有可用的 Xcode。"
        }
    }
}

enum ProjectXcodeResolutionSource: Equatable, Sendable {
    case explicitBinding
    case localConfiguration(String)
    case automaticRequirement(ProjectXcodeRequirement)
    case currentInstallationFallback
    case firstInstallationFallback

    var displayName: String {
        switch self {
        case .explicitBinding:
            return "项目固定绑定"
        case .localConfiguration:
            return ".xcode-switcher.json"
        case let .automaticRequirement(requirement):
            return URL(fileURLWithPath: requirement.source).lastPathComponent
        case .currentInstallationFallback, .firstInstallationFallback:
            return "默认选择"
        }
    }
}

enum ProjectXcodeOpenDecision: Equatable, Sendable {
    case open(installationID: String)
    case requiresConfirmation(installationID: String, source: ProjectXcodeResolutionSource)
}

enum ProjectXcodeMatcher {
    static func openDecision(
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

    static func requirement(for projectURL: URL, fileManager: FileManager = .default) -> ProjectXcodeRequirement? {
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

    static func match(
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

    static func resolve(
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

    static func normalizeVersion(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let pattern = #"(?i)(?:^|[^0-9])([0-9]+(?:\.[0-9]+){0,3})(?:[^0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    static func version(_ installed: String, matches required: String) -> Bool {
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
