import Foundation

enum EnvironmentDoctor {
    static func inspect(
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
            title: "Xcode 工具链",
            result: versionResult,
            successDetail: versionResult.stdout,
            remediation: "确认 Xcode.app 完整，并重新选择 Developer 目录。"
        ))

        let firstLaunchResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-checkFirstLaunchStatus"],
            environment: environment,
            timeout: 30
        )
        checks.append(commandCheck(
            id: "first-launch",
            title: "首次启动组件",
            result: firstLaunchResult,
            successDetail: "首次启动任务已完成。",
            remediation: "打开该 Xcode，或执行 xcodebuild -runFirstLaunch。"
        ))

        let licenseResult = ProcessRunner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-license", "check"],
            environment: environment,
            timeout: 20
        )
        checks.append(commandCheck(
            id: "license",
            title: "Xcode License",
            result: licenseResult,
            successDetail: "License 已接受。",
            remediation: "打开 Xcode 阅读并接受 License。"
        ))

        let sdkResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-version"],
            environment: environment,
            timeout: 20
        )
        checks.append(commandCheck(
            id: "iphoneos-sdk",
            title: "iPhoneOS SDK",
            result: sdkResult,
            successDetail: sdkResult.stdout.isEmpty ? "已安装。" : "版本 \(sdkResult.stdout)",
            remediation: "检查 Xcode 安装完整性或重新安装对应平台组件。"
        ))

        let runtimes = XcodeTooling.simulatorRuntimes(for: installation)
        let availableRuntimes = runtimes.filter(\.isAvailable)
        checks.append(EnvironmentCheck(
            id: "simulator-runtime",
            title: "Simulator Runtime",
            detail: availableRuntimes.isEmpty
                ? "未检测到可用的 Simulator Runtime。"
                : "已安装 \(availableRuntimes.count) 个可用 Runtime：\(availableRuntimes.map { "\($0.name) \($0.version)" }.joined(separator: "、"))",
            severity: availableRuntimes.isEmpty ? .warning : .healthy,
            remediation: availableRuntimes.isEmpty ? "在 App 中下载 iOS Runtime，或打开 Xcode Settings。" : nil
        ))

        let simulatorResult = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            environment: environment,
            timeout: 30
        )
        checks.append(commandCheck(
            id: "simulator-service",
            title: "Simulator 服务",
            result: simulatorResult,
            successDetail: "CoreSimulator 可正常响应。",
            remediation: "关闭 Simulator/Xcode 后重试，必要时重启 CoreSimulator 服务。"
        ))

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

    static func render(_ report: EnvironmentReport) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Xcode Switcher 环境诊断报告",
            "生成时间：\(formatter.string(from: report.generatedAt))",
            "Xcode：\(report.installationName) \(report.version)",
            "路径：\(report.installationID)",
            "问题数：\(report.issueCount)",
            "",
        ]
        for check in report.checks {
            lines.append("[\(severityLabel(check.severity))] \(check.title)")
            lines.append(check.detail)
            if let remediation = check.remediation { lines.append("建议：\(remediation)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func severityLabel(_ severity: EnvironmentCheckSeverity) -> String {
        switch severity {
        case .healthy: return "正常"
        case .informational: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    private static func pathCheck(for installation: XcodeInstallation) -> EnvironmentCheck {
        let appExists = FileManager.default.fileExists(atPath: installation.appURL.path)
        let developerExists = FileManager.default.fileExists(atPath: installation.developerURL.path)
        let healthy = appExists && developerExists
        return EnvironmentCheck(
            id: "installation-path",
            title: "安装路径",
            detail: healthy ? installation.developerURL.path : "Xcode.app 或 Contents/Developer 不存在。",
            severity: healthy ? .healthy : .error,
            remediation: healthy ? nil : "重新扫描 Xcode，或移除失效的自定义搜索路径。"
        )
    }

    private static func activePathCheck(
        for installation: XcodeInstallation,
        activeDeveloperPath: String?
    ) -> EnvironmentCheck {
        let isActive = installation.developerURL.path == activeDeveloperPath
        return EnvironmentCheck(
            id: "developer-directory",
            title: "Command Line Tools",
            detail: isActive
                ? "xcode-select 已指向当前 Xcode。"
                : "当前为 \(activeDeveloperPath ?? "未配置")",
            severity: isActive ? .healthy : .informational,
            remediation: isActive ? nil : "需要全局使用此版本时，点击“激活此版本”。"
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
        let architecture = ProcessRunner.output(executable: "/usr/bin/uname", arguments: ["-m"]) ?? "未知"
        guard architecture == "arm64" else {
            return EnvironmentCheck(
                id: "rosetta",
                title: "Rosetta 2",
                detail: "当前 Mac 架构为 \(architecture)，无需检查 Rosetta。",
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
            title: "Rosetta 2",
            detail: result.succeeded ? "Rosetta 2 可用。" : "未检测到可用的 Rosetta 2。",
            severity: result.succeeded ? .healthy : .warning,
            remediation: result.succeeded ? nil : "如需运行 Intel 工具链，请执行 softwareupdate --install-rosetta。"
        )
    }

    private static func diskSpaceCheck(at url: URL) -> EnvironmentCheck {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let gigabytes = Double(available) / 1_000_000_000
        let detail = available > 0 ? String(format: "可用空间 %.1f GB。", gigabytes) : "无法读取可用磁盘空间。"
        if available == 0 {
            return EnvironmentCheck(
                id: "disk-space",
                title: "磁盘空间",
                detail: detail,
                severity: .warning,
                remediation: "在 Finder 中检查 Xcode 所在磁盘的可用空间。"
            )
        }
        return EnvironmentCheck(
            id: "disk-space",
            title: "磁盘空间",
            detail: detail,
            severity: gigabytes < 40 ? .warning : .healthy,
            remediation: gigabytes < 40 ? "建议至少保留 40 GB，以安装 Runtime 和构建缓存。" : nil
        )
    }
}
