import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// A single, cached compatibility result for a configured project. Keeping this
/// as data lets both the overview header and an individual row present the same
/// answer without each view independently interpreting the resolver result.
struct ProjectCompatibilityItem: Identifiable {
    let profile: ProjectProfile
    let resolution: ProjectXcodeResolution
    let automaticMatch: ProjectXcodeMatch?
    let workspaceConflict: WorkspaceXcodeConflict?
    let installation: XcodeInstallation?
    let localXcodeBindingPath: String?
    let isProjectPresent: Bool
    let isActiveInstallation: Bool

    var id: UUID { profile.id }
    var issueDescription: String? { resolution.issueDescription }
    var resolvedSource: ProjectXcodeResolutionSource? {
        guard case let .resolved(_, source) = resolution else { return nil }
        return source
    }
    /// Only app-level bindings can be repaired automatically. A missing version
    /// declared in a repository file still needs that Xcode installed, and a
    /// malformed local config must be fixed in the project itself.
    var hasRepairableMissingBinding: Bool {
        guard profile.xcodeID != nil else { return false }
        guard localXcodeBindingPath == nil else { return false }
        guard case .missingBoundXcode = resolution else { return false }
        return true
    }
}

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
    var projectSearchPaths: () -> [String] = { [] }
    var setProjectSearchPaths: ([String]) -> Void = { _ in }
    var persist: () -> Void = {}
    var installations: () -> [XcodeInstallation] = { [] }
    var activeInstallation: () -> XcodeInstallation? = { nil }
    var aliases: () -> [String: String] = { [:] }
    var activate: (XcodeInstallation, URL?) -> Void = { _, _ in }
    var openProject: (URL, XcodeInstallation) -> Void = XcodeActions.open
    var openTerminal: (URL, String) -> Bool = XcodeActions.openTerminal
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
        let localXcodeBindingPath: String?
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
        if let issue = projectIssue(for: profile) {
            status?.statusMessage = String(localized: "已添加项目 \(profile.name)，但需要处理：\(issue)")
            status?.isError = true
        } else if let match = automaticMatch(for: profile) {
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

    func addProjectSearchPath(_ url: URL) {
        let normalized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            status?.statusMessage = String(localized: "项目扫描目录不存在：\(normalized.path)")
            status?.isError = true
            return
        }
        guard !projectSearchPaths().contains(where: {
            URL(fileURLWithPath: $0).standardizedFileURL.path == normalized.path
        }) else {
            status?.statusMessage = String(localized: "该项目扫描目录已经添加。")
            status?.isError = false
            return
        }
        setProjectSearchPaths(projectSearchPaths() + [normalized.path])
        persist()
        status?.statusMessage = String(localized: "已添加项目扫描目录：\(normalized.lastPathComponent)")
        status?.isError = false
    }

    func removeProjectSearchPath(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        setProjectSearchPaths(projectSearchPaths().filter {
            URL(fileURLWithPath: $0).standardizedFileURL.path != normalized
        })
        persist()
    }

    /// Adds newly discovered project packages but never removes a manually
    /// configured profile. Removing projects remains an explicit user action.
    @discardableResult
    func scanProjectSearchPaths() -> Int {
        let searchPaths = projectSearchPaths()
        guard !searchPaths.isEmpty else {
            status?.statusMessage = String(localized: "请先添加项目扫描目录。")
            status?.isError = false
            return 0
        }
        let discovered = ProjectDirectoryScanner.scan(
            roots: searchPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        let existingPaths = Set(projects().map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let additions = discovered
            .filter { !existingPaths.contains($0.path) }
            .map { ProjectProfile(name: $0.deletingPathExtension().lastPathComponent, path: $0.path) }
        if !additions.isEmpty {
            setProjects(projects() + additions)
            persist()
            invalidateSnapshots()
        }
        status?.statusMessage = String(localized: "项目扫描完成：发现 \(discovered.count) 个项目和 Workspace，新增 \(additions.count) 个。")
        status?.isError = false
        return additions.count
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

    var projectCompatibilityItems: [ProjectCompatibilityItem] {
        projects().map { profile in
            let snapshot = snapshot(for: profile)
            let installation = snapshot.resolution.installationID.flatMap { id in
                installations().first(where: { $0.id == id })
            }
            return ProjectCompatibilityItem(
                profile: profile,
                resolution: snapshot.resolution,
                automaticMatch: snapshot.match,
                workspaceConflict: snapshot.workspaceConflict,
                installation: installation,
                localXcodeBindingPath: snapshot.localXcodeBindingPath,
                isProjectPresent: snapshot.isProjectPresent,
                isActiveInstallation: installation?.id == activeInstallation()?.id
            )
        }
        .sorted { lhs, rhs in
            let lhsNeedsAttention = lhs.issueDescription != nil || lhs.workspaceConflict != nil
            let rhsNeedsAttention = rhs.issueDescription != nil || rhs.workspaceConflict != nil
            if lhsNeedsAttention != rhsNeedsAttention { return lhsNeedsAttention }
            return lhs.profile.name.localizedStandardCompare(rhs.profile.name) == .orderedAscending
        }
    }

    var repairableMissingProjectBindings: [ProjectProfile] {
        projectCompatibilityItems.filter(\.hasRepairableMissingBinding).map(\.profile)
    }

    /// Clears only stale app-level bindings. The next resolution then follows the
    /// project's declared version or the current Xcode; it never writes a version
    /// file or chooses an arbitrary Xcode on the user's behalf.
    @discardableResult
    func repairMissingProjectBindings() -> Int {
        let repairableIDs = Set(repairableMissingProjectBindings.map(\.id))
        guard !repairableIDs.isEmpty else {
            status?.statusMessage = String(localized: "没有需要修复的失效 Xcode 绑定。")
            status?.isError = false
            return 0
        }
        let repaired = projects().map { profile -> ProjectProfile in
            guard repairableIDs.contains(profile.id) else { return profile }
            var repaired = profile
            repaired.xcodeID = nil
            return repaired
        }
        setProjects(repaired)
        persist()
        invalidateSnapshots()
        status?.statusMessage = String(localized: "已移除 \(repairableIDs.count) 个失效 Xcode 绑定，并重新启用自动匹配。")
        status?.isError = false
        return repairableIDs.count
    }

    func refreshProjectCompatibility() {
        invalidateSnapshots()
        status?.statusMessage = String(localized: "已刷新项目兼容性状态。")
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

    private func resolvedAction(for profile: ProjectProfile) -> (ProjectProfile, XcodeInstallation, ProjectXcodeResolution)? {
        // A row may still hold a value from an earlier render. Use the current
        // profile and re-read project files before performing either action.
        let currentProfile = projects().first(where: { $0.id == profile.id }) ?? profile
        let resolution = snapshot(for: currentProfile, refreshing: true).resolution
        if let issue = resolution.issueDescription {
            status?.statusMessage = issue
            status?.isError = true
            return nil
        }
        guard let installationID = resolution.installationID,
              let installation = installations().first(where: { $0.id == installationID }) else {
            status?.statusMessage = String(localized: "没有可用于打开项目的 Xcode。")
            status?.isError = true
            return nil
        }
        return (currentProfile, installation, resolution)
    }

    /// Opens with the Xcode selected by the project's effective binding. The
    /// machine-wide developer directory and administrator authorization are untouched.
    func openProjectWithoutSwitch(_ profile: ProjectProfile) {
        guard let (profile, installation, _) = resolvedAction(for: profile) else { return }
        openProject(profile.url, installation)
        status?.statusMessage = String(localized: "已请求使用 Xcode \(installation.displayVersion) 打开 \(profile.name)，未修改系统开发者目录。")
        status?.isError = false
    }

    func openProjectTerminal(_ profile: ProjectProfile) {
        guard let (profile, installation, _) = resolvedAction(for: profile) else { return }
        let directory = profile.url.deletingLastPathComponent()
        let success = openTerminal(directory, installation.developerURL.path)
        status?.isError = !success
        status?.statusMessage = success
            ? String(localized: "已在 \(directory.path) 打开终端，DEVELOPER_DIR 指向 Xcode \(installation.displayVersion)。")
            : String(localized: "无法在 \(directory.path) 打开项目终端。")
    }

    func applyAndOpen(_ profile: ProjectProfile) {
        guard let (profile, installation, resolution) = resolvedAction(for: profile) else { return }
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
        openProject(request.profile.url, request.recommendedInstallation)
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
        // SwiftUI rows can hold the value from the render that initiated an
        // action. Resolve by ID from configuration first so a just-repaired or
        // edited binding is never evaluated with that stale value.
        let profile = projects().first(where: { $0.id == profile.id }) ?? profile
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
        let localControlsXcode = localConfiguration?.xcode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || (configurationURL != nil && localConfiguration == nil)
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
            localXcodeBindingPath: localControlsXcode ? configurationURL?.path : nil,
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
           !selector.isEmpty {
            let resolution = XcodeSelector.resolve(selector, among: installations, aliases: aliases)
            let ids: [String]
            switch resolution {
            case let .resolved(id): ids = [id]
            case let .ambiguous(candidateIDs): ids = candidateIDs
            case .notFound: ids = []
            }
            if let installation = ids.first.flatMap({ id in installations.first { $0.id == id } }),
               let normalized = ProjectXcodeMatcher.normalizeVersion(selector)
                    ?? (ids.count == 1 ? ProjectXcodeMatcher.normalizeVersion(installation.version) : nil) {
                return ProjectXcodeMatch(
                    requirement: ProjectXcodeRequirement(
                        source: configurationURL?.path ?? ".xcode-switcher.json",
                        rawValue: selector,
                        normalizedVersion: normalized
                    ),
                    installationID: ids.count == 1 ? ids[0] : nil,
                    candidateIDs: ids
                )
            }
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
