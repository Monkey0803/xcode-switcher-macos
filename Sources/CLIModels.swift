import Foundation

struct CLIOptions: Equatable, Sendable {
    let json: Bool
    let dryRun: Bool
    /// Set by `--force`: switch even though a running Xcode would be disturbed, and
    /// for `clean` the flag that turns a preview into an actual removal.
    let force: Bool
    /// Set by `--all`: for `clean`, also include the entries Xcode cannot rebuild on
    /// its own (archives, device support, package caches), which go to the Trash.
    let all: Bool
    let command: String?
    let values: [String]

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var json = false
        var dryRun = false
        var force = false
        var all = false
        var remaining: [String] = []
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--dry-run": dryRun = true
            case "--force": force = true
            case "--all": all = true
            default: remaining.append(argument)
            }
        }
        return CLIOptions(
            json: json,
            dryRun: dryRun,
            force: force,
            all: all,
            command: remaining.first,
            values: Array(remaining.dropFirst())
        )
    }
}

struct CLIDiskUsageOutput: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let label: String
        let path: String
        let bytes: Int64
        let size: String
    }

    let installations: [Entry]
    let runtimes: [Entry]
    let totalBytes: Int64
    let total: String
}

struct CLIInstallationOutput: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let app: String
    let developer: String
    let active: Bool
    let alias: String?

    init(installation: XcodeInstallation, active: Bool, alias: String? = nil) {
        name = installation.name
        version = installation.version
        build = installation.build
        app = installation.appURL.path
        developer = installation.developerURL.path
        self.active = active
        self.alias = alias
    }
}

struct CLIOperationOutput: Codable, Equatable, Sendable {
    let action: String
    let installation: CLIInstallationOutput
    let project: String?
    let dryRun: Bool
}

struct CLIResolveOutput: Codable, Equatable, Sendable {
    let installation: CLIInstallationOutput
    let project: String
    let requirementSource: String?
}

struct CLIEnvironmentOutput: Codable, Equatable, Sendable {
    let project: String?
    let developer: String?
    let restoreOriginal: Bool
}

struct CLIErrorOutput: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct CLICleanupOutput: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let label: String
        let path: String
        let bytes: Int64
        let size: String
        /// `safe` entries are caches Xcode rebuilds; `caution` entries are moved to
        /// the Trash instead, because Xcode cannot regenerate them.
        let safety: String
    }

    /// Every candidate, whether or not it was removed: the listing is the preview.
    let entries: [Entry]
    /// Only populated when something was actually removed.
    let removed: [String]
    /// Candidates left alone: the non-regenerable ones unless `--all` was given.
    let skipped: [String]
    /// Per-entry failures. A partial cleanup is reported here rather than thrown, so
    /// the caller still learns how much succeeded.
    let failures: [String]
    let totalBytes: Int64
    let total: String
    /// True only when entries were really removed, so a consumer can tell a preview
    /// from a cleanup without inspecting the flags.
    let performed: Bool
}
