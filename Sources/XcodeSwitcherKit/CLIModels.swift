import Foundation

/// Every `xcodeswitcher` subcommand, in the order the help text lists them.
///
/// This is the single source for the shell completion scripts. It exists because
/// those three scripts each used to carry their own copy of the list: when `clean`
/// was added to the dispatcher and the help text, all three completions silently
/// kept omitting it.
public enum CLISubcommands {
    public static let all = [
        "list", "version", "sizes", "clean", "alias", "unalias", "current", "resolve",
        "env", "shell-init", "doctor", "use", "pin", "unpin", "open", "workspace",
        "unworkspace", "completions",
    ]
}

public struct CLIOptions: Equatable, Sendable {
    public let json: Bool
    public let dryRun: Bool
    /// Set by `--force`: switch even though a running Xcode would be disturbed, and
    /// for `clean` the flag that turns a preview into an actual removal.
    public let force: Bool
    /// Set by `--all`: for `clean`, also include the entries Xcode cannot rebuild on
    /// its own (archives, device support, package caches), which go to the Trash.
    public let all: Bool
    public let command: String?
    public let values: [String]

    public static func parse(_ arguments: [String]) throws -> CLIOptions {
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

public struct CLIDiskUsageOutput: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let label: String
        public let path: String
        public let bytes: Int64
        public let size: String

        public init(label: String, path: String, bytes: Int64, size: String) {
            self.label = label
            self.path = path
            self.bytes = bytes
            self.size = size
        }
    }

    let installations: [Entry]
    let runtimes: [Entry]
    let totalBytes: Int64
    let total: String

    public init(
        installations: [Entry],
        runtimes: [Entry],
        totalBytes: Int64,
        total: String
    ) {
        self.installations = installations
        self.runtimes = runtimes
        self.totalBytes = totalBytes
        self.total = total
    }
}

public struct CLIInstallationOutput: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let app: String
    let developer: String
    let active: Bool
    let alias: String?

    public init(installation: XcodeInstallation, active: Bool, alias: String? = nil) {
        name = installation.name
        version = installation.version
        build = installation.build
        app = installation.appURL.path
        developer = installation.developerURL.path
        self.active = active
        self.alias = alias
    }
}

public struct CLIOperationOutput: Codable, Equatable, Sendable {
    let action: String
    let installation: CLIInstallationOutput
    let project: String?
    let dryRun: Bool

    public init(
        action: String,
        installation: CLIInstallationOutput,
        project: String?,
        dryRun: Bool
    ) {
        self.action = action
        self.installation = installation
        self.project = project
        self.dryRun = dryRun
    }
}

public struct CLIResolveOutput: Codable, Equatable, Sendable {
    let installation: CLIInstallationOutput
    let project: String
    let requirementSource: String?

    public init(
        installation: CLIInstallationOutput,
        project: String,
        requirementSource: String?
    ) {
        self.installation = installation
        self.project = project
        self.requirementSource = requirementSource
    }
}

public struct CLIEnvironmentOutput: Codable, Equatable, Sendable {
    let project: String?
    let developer: String?
    let restoreOriginal: Bool

    public init(project: String?, developer: String?, restoreOriginal: Bool) {
        self.project = project
        self.developer = developer
        self.restoreOriginal = restoreOriginal
    }
}

public struct CLIErrorOutput: Codable, Equatable, Sendable {
    let code: String
    let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct CLICleanupOutput: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let label: String
        public let path: String
        public let bytes: Int64
        public let size: String
        /// `safe` entries are caches Xcode rebuilds; `caution` entries are moved to
        /// the Trash instead, because Xcode cannot regenerate them.
        public let safety: String

        public init(label: String, path: String, bytes: Int64, size: String, safety: String) {
            self.label = label
            self.path = path
            self.bytes = bytes
            self.size = size
            self.safety = safety
        }
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

    public init(
        entries: [Entry],
        removed: [String],
        skipped: [String],
        failures: [String],
        totalBytes: Int64,
        total: String,
        performed: Bool
    ) {
        self.entries = entries
        self.removed = removed
        self.skipped = skipped
        self.failures = failures
        self.totalBytes = totalBytes
        self.total = total
        self.performed = performed
    }
}
