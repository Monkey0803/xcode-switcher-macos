import Foundation

/// Why an installed Xcode may not be moved to the Trash.
///
/// Every case is a refusal rather than a warning because the operation is not
/// recoverable in the way cleanup is: Xcode rebuilds a cache, but nothing brings back
/// a bundle you deleted while it was the system default, in use, or the version a
/// project is pinned to.
public enum XcodeRemovalRefusal: Equatable, Sendable {
    /// The path is not one of the installations this app discovered and validated.
    case notADiscoveredInstallation
    /// The path is a symbolic link (or has a symlinked ancestor). Trashing it would
    /// move the link and free nothing, leaving the bundle it points at in place.
    case symbolicLinkComponent
    /// `xcode-select` currently points at this bundle.
    case activeDeveloperDirectory
    /// A project in this app's configuration pins this version.
    case boundProjects([String])
    /// Its process is running.
    case running

    /// The only refusal `--force` relaxes. The others say the removal is unsafe or
    /// would not do what it claims; this one says it is merely inconvenient right now.
    public var isOverridableByForce: Bool { self == .running }

    public var message: String {
        switch self {
        case .notADiscoveredInstallation:
            return String(localized: "这个路径不在本机已发现的 Xcode 列表里。请重新扫描后再试。")
        case .symbolicLinkComponent:
            return String(localized: "这个路径是符号链接。移除它只会把链接移走，不会释放空间，指向的 Xcode 会留在原处。请在 Finder 中处理它指向的那个版本。")
        case .activeDeveloperDirectory:
            return String(localized: "它是当前系统默认的 Xcode（xcode-select 指向它）。请先切换到其他版本，或改用「不改系统设置」的方式打开项目。")
        case .boundProjects(let names):
            return String(localized: "这些项目绑定到它：\(names.joined(separator: "、"))。请在「项目」页把它们改绑到其他版本，或改用 .xcode-version 自动匹配。")
        case .running:
            return String(localized: "它正在运行。请先退出这个 Xcode。")
        }
    }
}

/// Raised when the policy refuses a removal. Kept distinct from a filesystem error so
/// the UI and the CLI can name the rule that refused it instead of reporting a
/// permission failure that did not happen.
public struct XcodeRemovalRefusedError: LocalizedError, Equatable {
    public let refusal: XcodeRemovalRefusal

    public init(refusal: XcodeRemovalRefusal) {
        self.refusal = refusal
    }

    public var errorDescription: String? { refusal.message }
}

/// What a removal actually did.
public enum XcodeRemovalOutcome: Equatable, Sendable {
    /// Moved here, which is what the Trash reported — it can differ from the bundle's
    /// own path when the Trash already holds a file of that name.
    case trashed(URL)
    /// Nothing to remove: the bundle is already gone. Not a failure. A stale list row
    /// is the usual reason something looked removable, and calling that an error is
    /// what made 「清理失败」 unanswerable for Simulator runtimes.
    case alreadyGone
}

/// Everything the decision depends on, passed in rather than reached for, so the
/// whole matrix is coverable by tests.
public struct XcodeRemovalContext: Sendable {
    public let knownInstallations: [XcodeInstallation]
    public let activeDeveloperPath: String?
    public let isRunning: Bool
    public let boundProjectNames: [String]
    /// Relaxes ``XcodeRemovalRefusal/running`` only.
    public let force: Bool

    public init(
        knownInstallations: [XcodeInstallation],
        activeDeveloperPath: String?,
        isRunning: Bool,
        boundProjectNames: [String],
        force: Bool = false
    ) {
        self.knownInstallations = knownInstallations
        self.activeDeveloperPath = activeDeveloperPath
        self.isRunning = isRunning
        self.boundProjectNames = boundProjectNames
        self.force = force
    }
}

public enum XcodeRemovalDecision: Equatable, Sendable {
    case allowed
    case refused(XcodeRemovalRefusal)
}

/// Decides whether an installed Xcode may be removed, and removes it.
///
/// The decision is a separate, pure step so both the app (which disables the button
/// and shows the reason before anything is clicked) and the CLI (which has to answer
/// without any UI) reach the same verdict from the same rules.
public enum XcodeRemoval {
    public static func decide(
        _ installation: XcodeInstallation,
        in context: XcodeRemovalContext
    ) -> XcodeRemovalDecision {
        // Not in the discovered set: nothing below is trustworthy — the path may be a
        // stale list entry, or something that was never validated as an Xcode at all.
        guard context.knownInstallations.contains(where: { $0.id == installation.id }) else {
            return .refused(.notADiscoveredInstallation)
        }
        // The system default first: it is the refusal with the clearest remedy, and it
        // is true regardless of how the path is spelled.
        if installation.developerURL.path == context.activeDeveloperPath {
            return .refused(.activeDeveloperDirectory)
        }
        // Discovery resolves symlinks, so a stored path that is not its own resolution
        // was never resolved — trashing it would move the link and free nothing.
        // Checking the resolution rather than each component also keeps `/var/...`
        // temporary paths working, where the *ancestor* is legitimately a link.
        if installation.appURL.resolvingSymlinksInPath().path != installation.appURL.path {
            return .refused(.symbolicLinkComponent)
        }
        if !context.boundProjectNames.isEmpty {
            return .refused(.boundProjects(context.boundProjectNames))
        }
        if context.isRunning, !context.force {
            return .refused(.running)
        }
        return .allowed
    }

    /// Moves the bundle to the Trash so it stays recoverable — the one property that
    /// makes this acceptable to offer at all next to a cache cleaner.
    @discardableResult
    public static func remove(
        _ installation: XcodeInstallation,
        in context: XcodeRemovalContext
    ) throws -> XcodeRemovalOutcome {
        if case let .refused(refusal) = decide(installation, in: context) {
            throw XcodeRemovalRefusedError(refusal: refusal)
        }
        guard FileManager.default.fileExists(atPath: installation.appURL.path) else {
            return .alreadyGone
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: installation.appURL, resultingItemURL: &trashed)
        return .trashed((trashed as URL?) ?? installation.appURL)
    }
}
