import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// Projects: their profiles, how each resolves to an Xcode, and opening them.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. This one spans
/// further than the other stores, so it takes more: the profile list is owned by
/// the configuration (read and replaced through closures rather than copied), a
/// resolution needs the installations, the active installation and the aliases, and
/// switching Xcode or bringing the window forward belongs to other objects — the
/// store asks for all of it and never reaches back into `XcodeViewModel`.
@MainActor
final class ProjectStore: ObservableObject {
    @Published var pendingProjectOpen: ProjectOpenRequest?

    /// Set by `XcodeViewModel` at construction.
    var projects: () -> [ProjectProfile] = { [] }
    var setProjects: ([ProjectProfile]) -> Void = { _ in }
    var persist: () -> Void = {}
    var installations: () -> [XcodeInstallation] = { [] }
    var activeInstallation: () -> XcodeInstallation? = { nil }
    var aliases: () -> [String: String] = { [:] }
    var activate: (XcodeInstallation, URL?) -> Void = { _, _ in }
    var showMainWindow: () -> Void = {}
    weak var status: (any StatusReporting)?

    private static let projectSnapshotLifetime: TimeInterval = 3
    private var snapshots: [UUID: ProjectSnapshot] = [:]
    private var pendingUpdate: (profile: ProjectProfile, name: String, xcodeID: String?)?
    private var updateTask: Task<Void, Never>?

    /// Cancelled here rather than from the model's `deinit`, which is nonisolated
    /// and so cannot call into this actor.
    deinit {
        updateTask?.cancel()
    }

    /// Resolving a project reads `.xcode-switcher.json`, `.xcode-version` and
    /// `.tool-versions` from disk. View bodies and the status menu ask for the
    /// result on every render, so it is cached and only re-read when the inputs
    /// change or the short lifetime expires. Actions that change system state
    /// resolve fresh instead of trusting the cache.
    private struct ProjectSnapshot {
        let resolution: ProjectXcodeResolution
        let match: ProjectXcodeMatch?
        let workspaceConflict: WorkspaceXcodeConflict?
        let isProjectPresent: Bool
        let computedAt: Date
    }

    func addProject(_ url: URL) {
        guard url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" else {
            status?.statusMessage = String(localized: "请选择 .xcodeproj 或 .xcworkspace。")
            status?.isError = true
            return
        }
        guard !projects().contains(where: { $0.path == url.path }) else {
            status?.statusMessage = String(localized: "该项目已经添加。")
            status?.isError = false
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            status?.statusMessage = String(localized: "项目路径不存在：\(url.path)")
            status?.isError = true
            return
        }
        let profile = ProjectProfile(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        setProjects(projects() + [profile])
        persist()
        if let match = automaticMatch(for: profile) {
            status?.isError = !match.isInstalled
            status?.statusMessage = match.isInstalled
                ? String(localized: "已添加项目 \(profile.name)，自动匹配 Xcode \(match.requirement.normalizedVersion)。")
                : String(localized: "已添加项目 \(profile.name)，但未安装其要求的 Xcode \(match.requirement.normalizedVersion)。")
        } else {
            status?.statusMessage = String(localized: "已添加项目 \(profile.name)。")
            status?.isError = false
        }
    }

    func removeProject(_ profile: ProjectProfile) {
        setProjects(projects().filter { $0.id != profile.id })
        persist()
    }

    var invalidProjects: [ProjectProfile] {
        projects().filter { !snapshot(for: $0).isProjectPresent }
    }

    func removeInvalidProjects() {
        let invalidIDs = Set(invalidProjects.map(\.id))
        setProjects(projects().filter { !invalidIDs.contains($0.id) })
        persist()
        status?.statusMessage = invalidIDs.isEmpty ? String(localized: "没有失效项目。") : String(localized: "已移除 \(invalidIDs.count) 个失效项目。")
        status?.isError = false
    }

    func updateProject(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        var list = projects()
        guard let index = list.firstIndex(where: { $0.id == profile.id }) else { return }
        list[index].name = name
        list[index].xcodeID = xcodeID
        setProjects(list)
        persist()
    }

    func installation(for profile: ProjectProfile) -> XcodeInstallation? {
        let resolution = snapshot(for: profile).resolution
        return resolution.installationID.flatMap { id in installations().first(where: { $0.id == id }) }
    }

    func applyAndOpen(_ profile: ProjectProfile) {
        // Opening a project changes which Xcode is used, so resolve from disk
        // rather than trusting a cached snapshot.
        let resolution = snapshot(for: profile, refreshing: true).resolution
        if let issue = resolution.issueDescription {
            status?.statusMessage = issue
            status?.isError = true
            return
        }
        guard let installationID = resolution.installationID,
              let installation = installations().first(where: { $0.id == installationID }) else {
            status?.statusMessage = String(localized: "没有可用于打开项目的 Xcode。")
            status?.isError = true
            return
        }
        guard let decision = ProjectXcodeMatcher.openDecision(
            for: resolution,
            activeInstallationID: activeInstallation()?.id
        ) else {
            status?.statusMessage = String(localized: "无法解析项目使用的 Xcode。")
            status?.isError = true
            return
        }
        switch decision {
        case .open:
            activate(installation, profile.url)
        case let .requiresConfirmation(_, source):
            guard let current = activeInstallation() else {
                activate(installation, profile.url)
                return
            }
            pendingProjectOpen = ProjectOpenRequest(
                profile: profile,
                currentInstallation: current,
                recommendedInstallation: installation,
                source: source
            )
            showMainWindow()
        }
    }

    func switchAndOpenPendingProject() {
        guard let request = pendingProjectOpen else { return }
        pendingProjectOpen = nil
        activate(request.recommendedInstallation, request.profile.url)
    }

    /// Opens the project with the recommended Xcode without touching
    /// `xcode-select`, so no administrator authorization is required and the
    /// rest of the machine keeps using the current developer directory.
    func openPendingProjectWithRecommendedXcode() {
        guard let request = pendingProjectOpen else { return }
        pendingProjectOpen = nil
        XcodeActions.open(request.profile.url, with: request.recommendedInstallation)
        status?.statusMessage = String(localized: "已用 Xcode \(request.recommendedInstallation.displayVersion) 打开 \(request.profile.name)，未修改系统开发者目录。")
        status?.isError = false
    }

    func cancelPendingProjectOpen() {
        pendingProjectOpen = nil
    }

    func automaticMatch(for profile: ProjectProfile) -> ProjectXcodeMatch? {
        snapshot(for: profile).match
    }

    func projectIssue(for profile: ProjectProfile) -> String? {
        snapshot(for: profile).resolution.issueDescription
    }

    func workspaceConflict(for profile: ProjectProfile) -> WorkspaceXcodeConflict? {
        snapshot(for: profile).workspaceConflict
    }

    /// Pins a workspace to one Xcode chosen from its conflicting child-project
    /// requirements. This records an app-level opening preference only: the
    /// workspace and every child project's version file remain untouched.
    @discardableResult
    func selectWorkspaceRequirement(
        _ requirement: WorkspaceXcodeConflict.Requirement,
        for profile: ProjectProfile
    ) -> String? {
        guard let conflict = snapshot(for: profile, refreshing: true).workspaceConflict,
              let currentRequirement = conflict.requirements.first(where: { $0.id == requirement.id }),
              let installationID = currentRequirement.installationID,
              let installation = installations().first(where: { $0.id == installationID })
        else {
            status?.statusMessage = String(localized: "该选择已过期，请重新选择项目对应的 Xcode。")
            status?.isError = true
            return nil
        }

        updateProject(profile, name: profile.name, xcodeID: installationID)
        snapshots.removeValue(forKey: profile.id)
        status?.statusMessage = String(localized: "已将 \(profile.name) 固定使用 Xcode \(installation.displayVersion)，对应 \(currentRequirement.projectName)。")
        status?.isError = false
        return installationID
    }

    /// Drops every cached project resolution. Called whenever the inputs a
    /// resolution depends on change, so the next read is fresh.
    func invalidateSnapshots() {
        snapshots.removeAll()
    }

    private func snapshot(for profile: ProjectProfile, refreshing: Bool = false) -> ProjectSnapshot {
        if !refreshing,
           let cached = snapshots[profile.id],
           Date().timeIntervalSince(cached.computedAt) < Self.projectSnapshotLifetime {
            return cached
        }

        // Walk the ancestor directories once and reuse the result for both the
        // resolution and the automatic match.
        let configurationURL = ProjectLocalConfigurationStore.configurationURL(for: profile.url)
        let localConfiguration = configurationURL.flatMap {
            ProjectLocalConfigurationStore.load(in: $0.deletingLastPathComponent())
        }
        let resolved = ProjectSnapshot(
            resolution: ProjectXcodeMatcher.resolve(
                profile: profile,
                installations: installations(),
                aliases: aliases(),
                activeInstallationID: activeInstallation()?.id,
                localConfiguration: localConfiguration
            ),
            match: Self.match(
                for: profile,
                installations: installations(),
                aliases: aliases(),
                localConfiguration: localConfiguration,
                configurationURL: configurationURL
            ),
            workspaceConflict: WorkspaceXcodeConflictDetector.conflict(
                in: profile.url,
                installations: installations(),
                aliases: aliases()
            ),
            isProjectPresent: FileManager.default.fileExists(atPath: profile.path),
            computedAt: Date()
        )
        snapshots[profile.id] = resolved
        return resolved
    }

    private static func match(
        for profile: ProjectProfile,
        installations: [XcodeInstallation],
        aliases: [String: String],
        localConfiguration: ProjectLocalConfiguration?,
        configurationURL: URL?
    ) -> ProjectXcodeMatch? {
        if let selector = localConfiguration?.xcode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selector.isEmpty,
           let installation = installations.first(where: {
               $0.id == selector || $0.appURL.path == selector || $0.developerURL.path == selector ||
               $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame ||
               aliases[$0.id]?.localizedCaseInsensitiveCompare(selector) == .orderedSame
           }),
           let normalized = ProjectXcodeMatcher.normalizeVersion(selector) ?? ProjectXcodeMatcher.normalizeVersion(installation.version) {
            return ProjectXcodeMatch(
                requirement: ProjectXcodeRequirement(
                    source: configurationURL?.path ?? ".xcode-switcher.json",
                    rawValue: selector,
                    normalizedVersion: normalized
                ),
                installationID: installation.id
            )
        }
        return ProjectXcodeMatcher.match(
            projectURL: profile.url,
            installations: installations,
            aliases: aliases
        )
    }


    /// Project name and binding edits arrive per keystroke. Debounce them so
    /// typing does not rewrite the configuration file and its backups on every
    /// character.
    func scheduleProjectUpdate(_ profile: ProjectProfile, name: String, xcodeID: String?) {
        pendingUpdate = (profile, name, xcodeID)
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushPendingProjectUpdate()
        }
    }

    /// Applies an edit that is still inside the debounce window.
    func flushPendingProjectUpdate() {
        updateTask?.cancel()
        updateTask = nil
        guard let pending = pendingUpdate else { return }
        pendingUpdate = nil
        updateProject(pending.profile, name: pending.name, xcodeID: pending.xcodeID)
    }
}
