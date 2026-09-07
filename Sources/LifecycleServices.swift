import AppKit
import ServiceManagement
import Sparkle

struct ReleaseCheckResult: Sendable, Equatable {
    let currentVersion: String
    let latestVersion: String?
    let releaseURL: URL?
    let isUpdateAvailable: Bool
    let errorMessage: String?
}

@MainActor
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private var updaterController: SPUStandardUpdaterController?

    private(set) var configurationError: String?

    let releasePageURL = URL(string: "https://github.com/Monkey0803/xcode-switcher-macos/releases/latest")!

    var isAvailable: Bool {
        updaterController != nil
    }

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let feed, URL(string: feed)?.scheme == "https", let publicKey, !publicKey.isEmpty else {
            configurationError = "正式构建需要配置 HTTPS SUFeedURL 和 SUPublicEDKey。"
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func openReleasePage() -> Bool {
        NSWorkspace.shared.open(releasePageURL)
    }

    func checkGitHubRelease() async -> ReleaseCheckResult {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let endpoint = URL(string: "https://api.github.com/repos/Monkey0803/xcode-switcher-macos/releases/latest")!
        do {
            var request = URLRequest(url: endpoint)
            request.setValue("XcodeSwitcher/1.2", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            let latestVersion = Self.version(from: payload.tagName)
            return ReleaseCheckResult(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: URL(string: payload.htmlURL),
                isUpdateAvailable: Self.isNewer(latestVersion, than: currentVersion),
                errorMessage: nil
            )
        } catch {
            return ReleaseCheckResult(
                currentVersion: currentVersion,
                latestVersion: nil,
                releaseURL: nil,
                isUpdateAvailable: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    nonisolated static func isNewer(_ candidate: String?, than current: String) -> Bool {
        guard let candidate else { return false }
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func version(from tag: String) -> String? {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard value.split(separator: ".").allSatisfy({ Int($0) != nil }) else { return nil }
        return value
    }

    private struct GitHubReleasePayload: Decodable, Sendable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
