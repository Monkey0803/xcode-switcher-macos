import AppKit
import ServiceManagement
import Sparkle

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
}
