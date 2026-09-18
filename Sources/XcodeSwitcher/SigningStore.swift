import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import XcodeSwitcherKit

/// Everything the app knows about code-signing identities.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. Signing is one
/// responsibility, and it needs only three things from the rest of the model: how
/// a project resolves to an installation, why a project cannot be read, and
/// somewhere to report a user-visible result. Those arrive as closures so this
/// type never reaches back into the model that owns it.
@MainActor
final class SigningStore: ObservableObject {
    @Published private(set) var certificates: [SigningCertificate] = []
    @Published private(set) var profiles: [ProvisioningProfile] = []
    @Published private(set) var report: ProjectSigningReport?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingReport = false

    /// Set by `XcodeViewModel` at construction.
    var resolveInstallation: (ProjectProfile) -> XcodeInstallation? = { _ in nil }
    var projectIssue: (ProjectProfile) -> String? = { _ in nil }
    var reportStatus: (String, Bool) -> Void = { _, _ in }

    private var reportTask: Task<Void, Never>?

    /// `deinit` is nonisolated, so the cancellation lives here rather than in a
    /// method the model would have to reach across the actor to call.
    deinit {
        reportTask?.cancel()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await Task.detached(priority: .utility) {
                (SigningService.certificates(), SigningService.provisioningProfiles())
            }.value
            certificates = result.0
            profiles = result.1
            isRefreshing = false
        }
    }

    func refreshReport(for profile: ProjectProfile) {
        refreshReport(for: profile, scheme: nil, configuration: nil)
    }

    func refreshReport(for profile: ProjectProfile, scheme: String?, configuration: String?) {
        reportTask?.cancel()
        if let issue = projectIssue(profile) {
            report = ProjectSigningReport(
                projectPath: profile.path,
                scheme: scheme,
                configuration: configuration,
                availableSchemes: report?.availableSchemes ?? [],
                availableConfigurations: report?.availableConfigurations ?? [],
                targets: [],
                errorMessage: issue
            )
            isLoadingReport = false
            return
        }
        guard let installation = resolveInstallation(profile) else { return }
        report = nil
        isLoadingReport = true
        reportTask = Task.detached(priority: .utility) { [weak self] in
            let value = SigningService.projectSigningReport(
                for: profile.url,
                developerURL: installation.developerURL,
                scheme: scheme,
                configuration: configuration
            )
            guard !Task.isCancelled else { return }
            await self?.complete(value)
        }
    }

    private func complete(_ value: ProjectSigningReport) {
        report = value
        isLoadingReport = false
        reportTask = nil
    }

    func exportCertificate(_ certificate: SigningCertificate) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(certificate.name.replacingOccurrences(of: "/", with: "-" )).cer"
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SigningService.exportCertificate(certificate, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            reportStatus(String(localized: "公钥证书已导出并在 Finder 中显示。"), false)
        } catch {
            reportStatus(String(localized: "证书导出失败：\(error.localizedDescription)"), true)
        }
    }

    func openKeychainAccess() {
        if SigningService.openKeychainAccess() {
            reportStatus(String(localized: "已打开钥匙串访问。"), false)
        } else {
            reportStatus(String(localized: "无法打开钥匙串访问。"), true)
        }
    }

    func revealProfilesFolder() {
        let directories = SigningService.profileDirectories()
        let directory = directories.first(where: { url in
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.contains(where: { $0.pathExtension == "mobileprovision" }) == true
        }) ?? directories.last!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }
}
