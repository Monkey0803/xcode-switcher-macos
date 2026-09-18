import Combine
import Foundation

/// Runtime download progress changes on every line of `xcodebuild` output, so it
/// lives in its own observable object instead of republishing the whole view
/// model and invalidating every view that reads it.
@MainActor
final class RuntimeDownloadState: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress = ""

    func begin(_ message: String) {
        isDownloading = true
        progress = message
    }

    func update(_ message: String) {
        progress = message
    }

    func finish(_ message: String) {
        isDownloading = false
        progress = message
    }
}
