import AppKit
import Foundation

enum SigningService {
    static func certificates() -> [SigningCertificate] {
        let result = ProcessRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        )
        guard result.succeeded else { return [] }

        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard let quoteStart = text.firstIndex(of: "\""),
                  let quoteEnd = text[text.index(after: quoteStart)...].firstIndex(of: "\"") else { return nil }
            let name = String(text[text.index(after: quoteStart)..<quoteEnd])
            let fingerprint = String(text[..<quoteStart])
                .split(separator: ")", maxSplits: 1, omittingEmptySubsequences: true)
                .last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
                .first
                .map(String.init) ?? ""
            let isValid = !text.localizedCaseInsensitiveContains("CSSMERR") &&
                !text.localizedCaseInsensitiveContains("invalid")
            return SigningCertificate(id: fingerprint.isEmpty ? name : fingerprint, name: name, fingerprint: fingerprint, isValid: isValid)
        }
    }

    static func provisioningProfiles() -> [ProvisioningProfile] {
        let urls = profileDirectories().flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        return Array(Set(urls)).filter { $0.pathExtension == "mobileprovision" }.compactMap(profile(at:)).sorted {
            ($0.expirationDate ?? .distantPast) > ($1.expirationDate ?? .distantPast)
        }
    }

    static func profileDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true),
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
        ]
    }

    static func exportCertificate(_ certificate: SigningCertificate, to url: URL) throws {
        let result = ProcessRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-certificate", "-a", "-c", certificate.name, "-p"]
        )
        guard result.succeeded, !result.stdout.isEmpty else {
            throw NSError(domain: "XcodeSwitcher.Signing", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法从钥匙串读取公钥证书。"])
        }
        try result.stdout.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func projectSigningReport(
        for projectURL: URL,
        developerURL: URL?,
        scheme requestedScheme: String? = nil,
        configuration requestedConfiguration: String? = nil
    ) -> ProjectSigningReport {
        let isWorkspace = projectURL.pathExtension == "xcworkspace"
        let containerArgument = isWorkspace ? "-workspace" : "-project"
        var environment: [String: String] = [:]
        if let developerURL { environment["DEVELOPER_DIR"] = developerURL.path }

        let listResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: [containerArgument, projectURL.path, "-list", "-json"],
            environment: environment,
            timeout: 45
        )
        guard listResult.succeeded else {
            return ProjectSigningReport(
                projectPath: projectURL.path,
                scheme: nil,
                configuration: nil,
                availableSchemes: [],
                availableConfigurations: [],
                targets: [],
                errorMessage: listResult.failureDescription
            )
        }

        let metadata = containerMetadata(from: listResult.stdout, isWorkspace: isWorkspace)
        let schemes = metadata.schemes
        let configurations = Array(Set(metadata.configurations + projectConfigurations(for: projectURL))).sorted(by: configurationOrder)
        let scheme = requestedScheme.flatMap { schemes.contains($0) ? $0 : nil } ?? schemes.first
        let configuration = requestedConfiguration.flatMap { configurations.contains($0) ? $0 : nil }
            ?? configurations.first(where: { $0 == "Debug" })
            ?? configurations.first
        var arguments = [containerArgument, projectURL.path, "-showBuildSettings", "-json"]
        if let scheme { arguments += ["-scheme", scheme] }
        if let configuration { arguments += ["-configuration", configuration] }
        let settingsResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            environment: environment,
            timeout: 120
        )
        guard settingsResult.succeeded else {
            return ProjectSigningReport(
                projectPath: projectURL.path,
                scheme: scheme,
                configuration: configuration,
                availableSchemes: schemes,
                availableConfigurations: configurations,
                targets: [],
                errorMessage: settingsResult.failureDescription
            )
        }

        let targets = targetReports(from: settingsResult.stdout, fallbackConfiguration: configuration)
        return ProjectSigningReport(
            projectPath: projectURL.path,
            scheme: scheme,
            configuration: configuration,
            availableSchemes: schemes,
            availableConfigurations: configurations,
            targets: targets,
            errorMessage: targets.isEmpty ? "未读取到签名配置，请确认项目包含可构建的 Scheme。" : nil
        )
    }

    static func reveal(_ profile: ProvisioningProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.path)])
    }

    static func openKeychainAccess() -> Bool {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            return NSWorkspace.shared.open(appURL)
        }

        let fallbackPaths = [
            "/System/Library/CoreServices/Applications/Keychain Access.app",
            "/System/Applications/Utilities/Keychain Access.app"
        ]
        guard let path = fallbackPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func profile(at url: URL) -> ProvisioningProfile? {
        let result = ProcessRunner.run(executable: "/usr/bin/security", arguments: ["cms", "-D", "-i", url.path])
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let uuid = plist["UUID"] as? String ?? url.deletingPathExtension().lastPathComponent
        let name = plist["Name"] as? String ?? "未命名 Profile"
        let teamID = (plist["TeamIdentifier"] as? [String])?.first ?? "未知"
        let entitlements = plist["Entitlements"] as? [String: Any]
        let appIdentifier = entitlements?["application-identifier"] as? String ?? "未知"
        let expiration = plist["ExpirationDate"] as? Date
        return ProvisioningProfile(
            id: uuid,
            name: name,
            uuid: uuid,
            path: url.path,
            teamID: teamID,
            appIdentifier: appIdentifier,
            expirationDate: expiration,
            isExpired: expiration.map { $0 < Date() } ?? false
        )
    }

    static func containerMetadata(from json: String, isWorkspace: Bool) -> (schemes: [String], configurations: [String]) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root[isWorkspace ? "workspace" : "project"] as? [String: Any] else { return ([], []) }
        return (
            (container["schemes"] as? [String] ?? []).sorted(),
            (container["configurations"] as? [String] ?? []).sorted(by: configurationOrder)
        )
    }

    static func targetReports(from json: String, fallbackConfiguration: String?) -> [SigningTargetReport] {
        guard let data = json.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let keys = [
            "PRODUCT_BUNDLE_IDENTIFIER",
            "PRODUCT_NAME",
            "DEVELOPMENT_TEAM",
            "CODE_SIGN_STYLE",
            "CODE_SIGN_IDENTITY",
            "PROVISIONING_PROFILE_SPECIFIER",
            "CODE_SIGN_ENTITLEMENTS",
            "SDKROOT"
        ]
        return records.enumerated().compactMap { index, record in
            guard let buildSettings = record["buildSettings"] as? [String: Any] else { return nil }
            let targetName = record["target"] as? String
                ?? buildSettings["TARGET_NAME"] as? String
                ?? buildSettings["PRODUCT_NAME"] as? String
                ?? "未命名 Target"
            let configuration = buildSettings["CONFIGURATION"] as? String ?? fallbackConfiguration ?? "默认"
            let settings = keys.map { key in
                let value = (buildSettings[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未设置"
                let warningKeys = ["PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_STYLE"]
                return SigningSetting(
                    id: "\(targetName)-\(configuration)-\(key)",
                    key: key,
                    value: value,
                    isWarning: warningKeys.contains(key) && value == "未设置"
                )
            }
            return SigningTargetReport(
                id: "\(index)-\(targetName)-\(configuration)",
                targetName: targetName,
                configurationName: configuration,
                settings: settings
            )
        }
    }

    private static func projectConfigurations(for projectURL: URL) -> [String] {
        let projectURLs: [URL]
        if projectURL.pathExtension == "xcodeproj" {
            projectURLs = [projectURL]
        } else {
            let workspaceData = projectURL.appendingPathComponent("contents.xcworkspacedata")
            guard let contents = try? String(contentsOf: workspaceData, encoding: .utf8) else { return [] }
            let pattern = #"location\s*=\s*\"(?:group:|container:)?([^\"]+\.xcodeproj)\""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            projectURLs = regex.matches(in: contents, range: NSRange(contents.startIndex..., in: contents)).compactMap { match in
                guard let range = Range(match.range(at: 1), in: contents) else { return nil }
                return projectURL.deletingLastPathComponent().appendingPathComponent(String(contents[range])).standardizedFileURL
            }
        }

        let pattern = #"isa\s*=\s*XCBuildConfiguration;[\s\S]*?name\s*=\s*(?:\"([^\"]+)\"|([^;]+));"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return projectURLs.flatMap { url -> [String] in
            let pbxproj = url.appendingPathComponent("project.pbxproj")
            guard let contents = try? String(contentsOf: pbxproj, encoding: .utf8) else { return [] }
            return regex.matches(in: contents, range: NSRange(contents.startIndex..., in: contents)).compactMap { match in
                for index in 1...2 where match.range(at: index).location != NSNotFound {
                    if let range = Range(match.range(at: index), in: contents) {
                        return String(contents[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }
        }
    }

    private static func configurationOrder(_ lhs: String, _ rhs: String) -> Bool {
        let priorities = ["Debug": 0, "Release": 1]
        let left = priorities[lhs] ?? 2
        let right = priorities[rhs] ?? 2
        if left != right { return left < right }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
