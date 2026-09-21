import Foundation

public enum EnvironmentDoctor {
    public static func inspect(
        installation: XcodeInstallation,
        activeDeveloperPath: String?
    ) -> EnvironmentReport {
        let environment = ["DEVELOPER_DIR": installation.developerURL.path]
        var checks: [EnvironmentCheck] = []

        checks.append(pathCheck(for: installation))
        checks.append(activePathCheck(for: installation, activeDeveloperPath: activeDeveloperPath))

        let versionResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            environment: environment,
            timeout: 20
        )
        checks.append(commandCheck(
            id: "xcodebuild",
            title: String(localized: "Xcode 工具链"),
            result: versionResult,
            successDetail: versionResult.stdout,
            remediation: String(localized: "确认 Xcode.app 完整，并重新选择 Developer 目录。")
        ))

        let firstLaunchResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-checkFirstLaunchStatus"],
            environment: environment,
            timeout: 30
        )
        checks.append(commandCheck(
            id: "first-launch",
            title: String(localized: "首次启动组件"),
            result: firstLaunchResult,
            successDetail: String(localized: "首次启动任务已完成。"),
            remediation: String(localized: "打开该 Xcode，或执行 xcodebuild -runFirstLaunch。")
        ))

        let licenseResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-license", "check"],
            environment: environment,
            timeout: 20
        )
        checks.append(commandCheck(
            id: "license",
            title: String(localized: "Xcode License"),
            result: licenseResult,
            successDetail: String(localized: "License 已接受。"),
            remediation: String(localized: "打开 Xcode 阅读并接受 License。")
        ))

        let sdkResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-version"],
            environment: environment,
            timeout: 20
        )
        checks.append(commandCheck(
            id: "iphoneos-sdk",
            title: String(localized: "iPhoneOS SDK"),
            result: sdkResult,
            successDetail: sdkResult.stdout.isEmpty
                ? String(localized: "已安装。")
                : String(localized: "版本 \(sdkResult.stdout)"),
            remediation: String(localized: "检查 Xcode 安装完整性或重新安装对应平台组件。")
        ))

        let runtimes = XcodeTooling.simulatorRuntimes(for: installation)
        let availableRuntimes = runtimes.filter(\.isAvailable)
        checks.append(EnvironmentCheck(
            id: "simulator-runtime",
            title: String(localized: "Simulator Runtime"),
            detail: availableRuntimes.isEmpty
                ? String(localized: "未检测到可用的 Simulator Runtime。")
                : String(localized: "已安装 \(availableRuntimes.count) 个可用 Runtime：\(availableRuntimes.map { "\($0.name) \($0.version)" }.joined(separator: "、"))"),
            severity: availableRuntimes.isEmpty ? .warning : .healthy,
            remediation: availableRuntimes.isEmpty
                ? String(localized: "在 App 中下载 Simulator Runtime，或打开 Xcode Settings。")
                : nil
        ))

        let simulatorResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            environment: environment,
            timeout: 30
        )
        checks.append(commandCheck(
            id: "simulator-service",
            title: String(localized: "Simulator 服务"),
            result: simulatorResult,
            successDetail: String(localized: "CoreSimulator 可正常响应。"),
            remediation: String(localized: "关闭 Simulator/Xcode 后重试，必要时重启 CoreSimulator 服务。")
        ))

        checks.append(terminalToolchainProbe(installation: installation))
        checks.append(contentsOf: thirdPartyToolchainProbes(installation: installation))

        checks.append(rosettaCheck())
        checks.append(diskSpaceCheck(at: installation.appURL))

        return EnvironmentReport(
            installationID: installation.id,
            installationName: installation.name,
            version: installation.displayVersion,
            generatedAt: Date(),
            checks: checks
        )
    }

    public static func render(_ report: EnvironmentReport, redacted: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        let redact: (String) -> String = { value in
            guard redacted else { return value }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return value.replacingOccurrences(of: home, with: "~")
        }
        var lines = [
            String(localized: "Xcode Switcher 环境诊断报告"),
            String(localized: "生成时间：\(formatter.string(from: report.generatedAt))"),
            "Xcode：\(redact(report.installationName)) \(report.version)",
            String(localized: "路径：\(redact(report.installationID))"),
            String(localized: "问题数：\(report.issueCount)"),
            "",
        ]
        for check in report.checks {
            lines.append("[\(severityLabel(check.severity))] \(check.title)")
            lines.append(redact(check.detail))
            if let remediation = check.remediation { lines.append(String(localized: "建议：\(redact(remediation))")) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 终端与第三方工具链

    /// A third-party tool whose own command reports the Xcode it uses.
    ///
    /// Only such a tool can be compared: `swiftlint --version` and `xcbeautify --version`
    /// say nothing about a toolchain, and inferring one from `PATH` would be inventing a
    /// result. Every other tool inherits the terminal's toolchain, which the terminal
    /// check covers on its own.
    struct ToolchainProbe: Sendable {
        let id: String
        let title: String
        let executableNames: [String]
        let arguments: [String]
        let parse: @Sendable (String) -> String?
    }

    static let toolchainProbes: [ToolchainProbe] = [
        ToolchainProbe(
            id: "cocoapods",
            title: String(localized: "CocoaPods"),
            executableNames: ["pod"],
            arguments: ["env"],
            parse: { output in parseCocoaPodsToolchain(output) }
        )
    ]

    /// `xcodebuild -version` prints `Xcode 26.3` and `Build version 17C529`; returned in the
    /// same "26.3 (17C529)" shape `XcodeInstallation.displayVersion` uses, so the two can be
    /// compared and shown without reformatting either one.
    static func parseXcodeVersion(_ output: String) -> String? {
        var version: String?
        var build: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Xcode ") {
                version = String(trimmed.dropFirst("Xcode ".count))
            } else if trimmed.hasPrefix("Build version ") {
                build = String(trimmed.dropFirst("Build version ".count))
            }
        }
        guard let version else { return nil }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    /// `pod env` prints its stack, with the Xcode it resolved on one line:
    /// `       Xcode : 26.3 (17C529)`.
    static func parseCocoaPodsToolchain(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Xcode :") else { continue }
            let value = trimmed.dropFirst("Xcode :".count).trimmingCharacters(in: .whitespaces)
            // A Command Line Tools-only setup makes CocoaPods print an empty "()" here —
            // a real answer ("no Xcode found") rather than a version to compare against.
            if !value.isEmpty, value.contains(where: \.isNumber) { return value }
        }
        return nil
    }

    /// The terminal check's verdict, kept apart from running the shell so the judgement can
    /// be tested without one.
    static func terminalToolchainCheck(
        resolved: String?,
        persistentDeveloperDir: String?,
        installation: XcodeInstallation
    ) -> EnvironmentCheck {
        let id = "terminal-toolchain"
        let title = String(localized: "终端里的 Xcode")
        let inspected = installation.displayVersion

        if let developerDir = persistentDeveloperDir, !developerDir.isEmpty {
            if !FileManager.default.fileExists(atPath: developerDir) {
                return EnvironmentCheck(
                    id: id,
                    title: title,
                    detail: String(localized: "终端里设置了 DEVELOPER_DIR，指向不存在的路径：\(developerDir)"),
                    severity: .error,
                    remediation: String(localized: "从 ~/.zshrc 等 shell 配置里移除该设置，或改回可用的 Xcode。")
                )
            }
            if developerDir != installation.developerURL.path {
                return EnvironmentCheck(
                    id: id,
                    title: title,
                    detail: String(localized: "终端里的 DEVELOPER_DIR 指向另一个 Xcode：\(developerDir)"),
                    severity: .warning,
                    remediation: String(localized: "脚本与第三方工具会跟着终端走；需要按目录注入时，请用应用提供的 shell 集成，而不是全局设置。")
                )
            }
        }

        guard let resolved else {
            return EnvironmentCheck(
                id: id,
                title: title,
                detail: String(localized: "无法在登录 shell 中运行 xcodebuild。"),
                severity: .warning,
                remediation: String(localized: "确认 /bin/zsh 可用，且 shell 配置没有破坏 PATH。")
            )
        }

        let matches = resolved == inspected
        return EnvironmentCheck(
            id: id,
            title: title,
            detail: matches
                ? String(localized: "终端里 xcodebuild 用的就是它（\(inspected)）。")
                : String(localized: "终端里 xcodebuild 用的是 \(resolved)，正在体检的是 \(inspected)。"),
            severity: matches ? .healthy : .warning,
            remediation: matches
                ? nil
                : String(localized: "第三方工具继承终端的环境；在终端里执行「激活此版本」，或检查 shell 配置。")
        )
    }

    /// One tool's verdict, kept apart from running it so the judgement is testable without
    /// that tool installed.
    static func thirdPartyToolchainCheck(
        probe: ToolchainProbe,
        reported: String?,
        installation: XcodeInstallation
    ) -> EnvironmentCheck {
        let id = "toolchain-\(probe.id)"
        guard let reported else {
            return EnvironmentCheck(
                id: id,
                title: probe.title,
                detail: String(localized: "已安装，但读不出它使用的 Xcode。"),
                severity: .informational,
                remediation: String(localized: "在终端里手动运行该工具，确认它使用的开发者目录。")
            )
        }
        let inspected = installation.displayVersion
        let matches = reported == inspected
        return EnvironmentCheck(
            id: id,
            title: probe.title,
            detail: matches
                ? String(localized: "使用的 Xcode 与体检的一致（\(reported)）。")
                : String(localized: "使用的是 \(reported)，正在体检的是 \(inspected)。"),
            severity: matches ? .healthy : .warning,
            remediation: matches
                ? nil
                : String(localized: "它跟随终端与 xcode-select；先激活需要的版本，或在终端里确认 DEVELOPER_DIR。")
        )
    }

    /// What the user's own terminal would use, read from a **login** shell so a value set in
    /// `~/.zshrc` counts — that is exactly the case this check exists for.
    static func terminalToolchainProbe(installation: XcodeInstallation) -> EnvironmentCheck {
        let script = "printf 'DEVELOPER_DIR=%s\\n' \"$DEVELOPER_DIR\"; /usr/bin/xcodebuild -version 2>/dev/null"
        let result = ProcessRunner.run(executable: "/bin/zsh", arguments: ["-lc", script], timeout: 30)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let persistent = lines
            .first { $0.hasPrefix("DEVELOPER_DIR=") }
            .map { String($0.dropFirst("DEVELOPER_DIR=".count)) } ?? ""
        let versionOutput = lines
            .filter { !$0.hasPrefix("DEVELOPER_DIR=") }
            .joined(separator: "\n")
        return terminalToolchainCheck(
            resolved: parseXcodeVersion(versionOutput),
            persistentDeveloperDir: persistent,
            installation: installation
        )
    }

    /// One check per installed tool. A tool that is not installed produces no check at all,
    /// rather than a row saying it is missing.
    static func thirdPartyToolchainProbes(installation: XcodeInstallation) -> [EnvironmentCheck] {
        toolchainProbes.compactMap { probe in
            guard let executable = resolveExecutable(probe) else { return nil }
            let command = ([executable] + probe.arguments).map(shellQuoted).joined(separator: " ")
            let output = ProcessRunner.output(executable: "/bin/zsh", arguments: ["-lc", command])
            return thirdPartyToolchainCheck(
                probe: probe,
                reported: output.flatMap(probe.parse),
                installation: installation
            )
        }
    }

    /// Homebrew lands in `/opt/homebrew/bin` on Apple Silicon and `/usr/local/bin` on Intel;
    /// Apple's own tools live in `/usr/bin`. Looked up explicitly rather than through `PATH`,
    /// so the answer does not depend on how the app happened to be launched.
    static func resolveExecutable(_ probe: ToolchainProbe) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            for name in probe.executableNames {
                let path = "\(directory)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func severityLabel(_ severity: EnvironmentCheckSeverity) -> String {
        switch severity {
        case .healthy: return String(localized: "正常")
        case .informational: return String(localized: "信息")
        case .warning: return String(localized: "警告")
        case .error: return String(localized: "错误")
        }
    }

    private static func pathCheck(for installation: XcodeInstallation) -> EnvironmentCheck {
        let appExists = FileManager.default.fileExists(atPath: installation.appURL.path)
        let developerExists = FileManager.default.fileExists(atPath: installation.developerURL.path)
        let healthy = appExists && developerExists
        return EnvironmentCheck(
            id: "installation-path",
            title: String(localized: "安装路径"),
            detail: healthy ? installation.developerURL.path : String(localized: "Xcode.app 或 Contents/Developer 不存在。"),
            severity: healthy ? .healthy : .error,
            remediation: healthy ? nil : String(localized: "重新扫描 Xcode，或移除失效的自定义搜索路径。")
        )
    }

    private static func activePathCheck(
        for installation: XcodeInstallation,
        activeDeveloperPath: String?
    ) -> EnvironmentCheck {
        let isActive = installation.developerURL.path == activeDeveloperPath
        let currentPath = activeDeveloperPath ?? String(localized: "未配置")
        return EnvironmentCheck(
            id: "developer-directory",
            title: String(localized: "Command Line Tools"),
            detail: isActive
                ? String(localized: "xcode-select 已指向当前 Xcode。")
                : String(localized: "当前为 \(currentPath)"),
            severity: isActive ? .healthy : .informational,
            remediation: isActive ? nil : String(localized: "需要全局使用此版本时，点击“激活此版本”。")
        )
    }

    private static func commandCheck(
        id: String,
        title: String,
        result: ProcessResult,
        successDetail: String,
        remediation: String
    ) -> EnvironmentCheck {
        EnvironmentCheck(
            id: id,
            title: title,
            detail: result.succeeded ? successDetail : result.failureDescription,
            severity: result.succeeded ? .healthy : .error,
            remediation: result.succeeded ? nil : remediation
        )
    }

    private static func rosettaCheck() -> EnvironmentCheck {
        let architecture = ProcessRunner.output(executable: "/usr/bin/uname", arguments: ["-m"])
            ?? String(localized: "未知")
        guard architecture == "arm64" else {
            return EnvironmentCheck(
                id: "rosetta",
                title: String(localized: "Rosetta 2"),
                detail: String(localized: "当前 Mac 架构为 \(architecture)，无需检查 Rosetta。"),
                severity: .informational,
                remediation: nil
            )
        }
        let result = ProcessRunner.run(
            executable: "/usr/bin/arch",
            arguments: ["-x86_64", "/usr/bin/true"],
            timeout: 10
        )
        return EnvironmentCheck(
            id: "rosetta",
            title: String(localized: "Rosetta 2"),
            detail: result.succeeded
                ? String(localized: "Rosetta 2 可用。")
                : String(localized: "未检测到可用的 Rosetta 2。"),
            severity: result.succeeded ? .healthy : .warning,
            remediation: result.succeeded
                ? nil
                : String(localized: "如需运行 Intel 工具链，请执行 softwareupdate --install-rosetta。")
        )
    }

    private static func diskSpaceCheck(at url: URL) -> EnvironmentCheck {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let gigabytes = Double(available) / 1_000_000_000
        let detail = available > 0
            ? String(format: String(localized: "可用空间 %.1f GB。"), gigabytes)
            : String(localized: "无法读取可用磁盘空间。")
        if available == 0 {
            return EnvironmentCheck(
                id: "disk-space",
                title: String(localized: "磁盘空间"),
                detail: detail,
                severity: .warning,
                remediation: String(localized: "在 Finder 中检查 Xcode 所在磁盘的可用空间。")
            )
        }
        return EnvironmentCheck(
            id: "disk-space",
            title: String(localized: "磁盘空间"),
            detail: detail,
            severity: gigabytes < 40 ? .warning : .healthy,
            remediation: gigabytes < 40
                ? String(localized: "建议至少保留 40 GB，以安装 Runtime 和构建缓存。")
                : nil
        )
    }
}
