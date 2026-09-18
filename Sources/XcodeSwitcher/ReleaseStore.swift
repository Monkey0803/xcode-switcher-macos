import AppKit
import Combine
import Foundation
import XcodeSwitcherKit

/// The community release index, per-installation build details, and the update
/// check.
///
/// Split out of `XcodeViewModel`, which owned every domain at once. It needs the
/// installations (to mark which index rows are installed here) and somewhere to
/// report a result, both injected, so it never reaches back into the model.
@MainActor
final class ReleaseStore: ObservableObject {
    init(releaseCatalogStore: XcodeReleaseCatalogStore = .live) {
        self.releaseCatalogStore = releaseCatalogStore
    }

    /// How the release-index fetch is going, so the panel can tell "not fetched
    /// yet" from "network unreachable" from "showing a stale copy".
    enum ReleaseCatalogState: Equatable, Sendable {
        case idle
        case loading
        case loaded(cachedAt: Date?, refreshFailed: Bool)
        case unavailable(String)
    }

    @Published private(set) var releaseCatalog: [XcodeReleaseInfo] = []
    @Published private(set) var releaseCatalogState: ReleaseCatalogState = .idle
    @Published private(set) var installDetailsByID: [String: XcodeInstallDetails] = [:]
    @Published private(set) var isCheckingRelease = false
    @Published private(set) var releaseCheckMessage = ""

    /// Set by `XcodeViewModel` at construction.
    weak var status: (any StatusReporting)?
    var installations: () -> [XcodeInstallation] = { [] }

    private let releaseCatalogStore: XcodeReleaseCatalogStore
    private var releaseCatalogTask: Task<Void, Never>?

    /// Cancelled here rather than from the model's `deinit`, which is nonisolated
    /// and so cannot call into this actor.
    deinit {
        releaseCatalogTask?.cancel()
    }

    func loadInstallDetails(for installation: XcodeInstallation) {
        guard installDetailsByID[installation.id] == nil else { return }
        installDetailsByID[installation.id] = XcodeInstallDetails.read(
            appURL: installation.appURL,
            fallbackBuild: installation.build
        )
    }

    func installDetails(for installation: XcodeInstallation) -> XcodeInstallDetails? {
        installDetailsByID[installation.id]
    }

    /// The index entry for an installation, matched on Apple's published build.
    func releaseInfo(for installation: XcodeInstallation) -> XcodeReleaseInfo? {
        XcodeReleaseCatalog.release(matchingBuild: installation.build, in: releaseCatalog)
    }

    /// One row per build across the whole index, for the "every version" window.
    var allReleases: [XcodeReleaseInfo] {
        XcodeReleaseCatalog.uniqueReleases(from: releaseCatalog)
    }

    /// The builds installed here, so the list can mark them. Uses the public build
    /// string, which is what the index is keyed by.
    var installedBuilds: Set<String> {
        Set(installations().map { $0.build.lowercased() })
    }

    /// The installation a catalogue entry corresponds to, when it is installed here.
    func installation(matching release: XcodeReleaseInfo) -> XcodeInstallation? {
        installations().first { $0.build.lowercased() == release.build.lowercased() }
    }
    func loadReleaseCatalog(force: Bool = false) {
        if !force {
            switch releaseCatalogState {
            case .loading, .loaded: return
            case .idle, .unavailable: break
            }
        }
        releaseCatalogTask?.cancel()
        releaseCatalogState = .loading
        let store = releaseCatalogStore
        releaseCatalogTask = Task { [weak self] in
            let result = await store.load(forceRefresh: force)
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                releaseCatalog = snapshot.releases
                releaseCatalogState = .loaded(cachedAt: snapshot.cachedAt, refreshFailed: snapshot.refreshFailed)
            case .failure(let error):
                releaseCatalogState = .unavailable(
                    error.errorDescription ?? String(localized: "无法获取发布信息。")
                )
            }
        }
    }
    var isUpdateServiceAvailable: Bool {
        UpdateService.shared.isAvailable
    }

    var updateServiceMessage: String {
        if !releaseCheckMessage.isEmpty { return releaseCheckMessage }
        if UpdateService.shared.isAvailable { return "Sparkle 自动更新已启用。" }
        return "当前为直接分发构建，可检查 GitHub Releases；Sparkle 自动更新仅在正式签名构建启用。"
    }
    func checkForUpdates() {
        guard !isCheckingRelease else { return }
        if UpdateService.shared.isAvailable {
            UpdateService.shared.checkForUpdates()
            status?.statusMessage = String(localized: "正在检查更新…")
            status?.isError = false
            return
        }
        isCheckingRelease = true
        releaseCheckMessage = "正在读取 GitHub Releases…"
        status?.statusMessage = String(localized: "正在检查 GitHub Releases…")
        status?.isError = false
        Task { @MainActor in
            let result = await UpdateService.shared.checkGitHubRelease()
            isCheckingRelease = false
            if let error = result.errorMessage {
                releaseCheckMessage = "GitHub Releases 检查失败：\(error)"
                status?.statusMessage = releaseCheckMessage
                status?.isError = true
            } else if result.isUpdateAvailable, let latest = result.latestVersion {
                releaseCheckMessage = "发现新版本 \(latest)，点击右侧按钮下载。"
                status?.statusMessage = releaseCheckMessage
                status?.isError = false
            } else {
                releaseCheckMessage = "当前已是最新版本（\(result.currentVersion)）。"
                status?.statusMessage = releaseCheckMessage
                status?.isError = false
            }
        }
    }
    func openReleasePage() {
        let opened = UpdateService.shared.openReleasePage()
        status?.statusMessage = opened ? String(localized: "已打开 GitHub Releases 下载页。") : String(localized: "无法打开 GitHub Releases。")
        status?.isError = !opened
    }
}
