import Foundation

enum ProjectXcodeResolution: Equatable, Sendable {
    case resolved(installationID: String, automaticRequirement: ProjectXcodeRequirement?)
    case missingProject(path: String)
    case missingBoundXcode(path: String)
    case missingRequiredXcode(ProjectXcodeRequirement)
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
        case .noInstallation:
            return "本机没有可用的 Xcode。"
        }
    }
}

enum ProjectXcodeMatcher {
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
        fileManager: FileManager = .default
    ) -> ProjectXcodeResolution {
        guard fileManager.fileExists(atPath: profile.path) else {
            return .missingProject(path: profile.path)
        }
        if let boundID = profile.xcodeID {
            guard installations.contains(where: { $0.id == boundID }) else {
                return .missingBoundXcode(path: boundID)
            }
            return .resolved(installationID: boundID, automaticRequirement: nil)
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
            return .resolved(installationID: installationID, automaticRequirement: automaticMatch.requirement)
        }
        if let activeInstallationID,
           installations.contains(where: { $0.id == activeInstallationID }) {
            return .resolved(installationID: activeInstallationID, automaticRequirement: nil)
        }
        guard let first = installations.first else { return .noInstallation }
        return .resolved(installationID: first.id, automaticRequirement: nil)
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
