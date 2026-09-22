import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// Environment checks and the reports they produce.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. It needs the
/// active developer path (the check compares against it) and somewhere to report a
/// result, both injected, so it never reaches back into the model.
@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var reportsByID: [String: EnvironmentReport] = [:]
    @Published private(set) var runningIDs: Set<String> = []

    /// Set by `XcodeViewModel` at construction.
    weak var status: (any StatusReporting)?
    var activeDeveloperPath: () -> String? = { nil }
    var inspect: @Sendable (XcodeInstallation, String?) -> EnvironmentReport = { installation, activeDeveloperPath in
        EnvironmentDoctor.inspect(installation: installation, activeDeveloperPath: activeDeveloperPath)
    }

    private var tasks: [String: Task<Void, Never>] = [:]

    /// Cancelled here rather than from the model's `deinit`, which is nonisolated
    /// and so cannot call into this actor.
    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func runEnvironmentDoctor(for installation: XcodeInstallation) {
        guard tasks[installation.id] == nil else { return }
        runningIDs.insert(installation.id)
        status?.statusMessage = String(localized: "正在体检 Xcode \(installation.displayVersion)…")
        status?.isError = false
        let activePath = activeDeveloperPath()
        let inspect = inspect
        tasks[installation.id] = Task.detached(priority: .userInitiated) { [weak self] in
            let report = inspect(installation, activePath)
            guard !Task.isCancelled else {
                await self?.completeEnvironmentDoctor(for: installation.id, report: nil)
                return
            }
            await self?.completeEnvironmentDoctor(for: installation.id, report: report)
        }
    }

    func isEnvironmentDoctorRunning(for installation: XcodeInstallation) -> Bool {
        runningIDs.contains(installation.id)
    }

    func copyEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = reportsByID[installation.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EnvironmentDoctor.render(report), forType: .string)
        status?.statusMessage = String(localized: "环境诊断报告已复制。")
        status?.isError = false
    }

    func copyRedactedEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = reportsByID[installation.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EnvironmentDoctor.render(report, redacted: true), forType: .string)
        status?.statusMessage = String(localized: "脱敏环境诊断报告已复制。")
        status?.isError = false
    }

    func exportEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = reportsByID[installation.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(installation.name)-environment-report.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EnvironmentDoctor.render(report).write(to: url, atomically: true, encoding: .utf8)
            status?.statusMessage = String(localized: "环境诊断报告已导出。")
            status?.isError = false
        } catch {
            status?.statusMessage = String(localized: "报告导出失败：\(error.localizedDescription)")
            status?.isError = true
        }
    }

    func exportRedactedEnvironmentReport(for installation: XcodeInstallation) {
        guard let report = reportsByID[installation.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(installation.name)-environment-report-redacted.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EnvironmentDoctor.render(report, redacted: true).write(to: url, atomically: true, encoding: .utf8)
            status?.statusMessage = String(localized: "脱敏环境诊断报告已导出。")
            status?.isError = false
        } catch {
            status?.statusMessage = String(localized: "报告导出失败：\(error.localizedDescription)")
            status?.isError = true
        }
    }

    private func completeEnvironmentDoctor(for id: String, report: EnvironmentReport?) {
        if let report {
            reportsByID[id] = report
            status?.isError = report.highestSeverity == .error
            status?.statusMessage = report.issueCount == 0
                ? String(localized: "环境体检完成，未发现问题。")
                : String(localized: "环境体检完成，发现 \(report.issueCount) 项需要关注。")
        }
        runningIDs.remove(id)
        tasks[id] = nil
    }
}
