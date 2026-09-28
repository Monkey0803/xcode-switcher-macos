import Foundation

/// Which installation a command-line selector names.
///
/// A pure function for the same reason `XcodeRemoval.decide` is one: this is the part worth
/// testing, and every command that accepts a selector (`use`, `sizes`, `doctor`, `pin`,
/// `alias`, `uninstall`, …) has to answer it identically.
///
/// The interesting case is the refusal. Two Xcodes of the same version — a beta and a release,
/// which is the common arrangement — make a version selector ambiguous, and `first(where:)`
/// silently took whichever came first: on 2026-09-28 `xcodeswitcher uninstall 27.0` resolved to
/// `/Applications/Xcode-beta.app` while the user had picked `/Applications/Xcode.app` in the
/// menu bar. Guessing between two installations is not a preference this tool gets to have, so
/// an ambiguous selector is refused and the candidates are named instead.
public enum XcodeSelector {
    public enum Resolution: Equatable, Sendable {
        case resolved(String)
        case notFound
        case ambiguous([String])
    }

    /// `selector` may be an installation's app path (its id), its developer path, its app name,
    /// an alias, or a version.
    ///
    /// App path and developer path win outright: they are unique by construction. Name, alias
    /// and version may answer for more than one installation, and are refused when they do.
    public static func resolve(
        _ selector: String,
        among installations: [XcodeInstallation],
        aliases: [String: String] = [:]
    ) -> Resolution {
        let expanded = (selector as NSString).expandingTildeInPath

        if let exact = installations.first(where: { $0.id == expanded || $0.developerURL.path == expanded }) {
            return .resolved(exact.id)
        }

        let named = installations.filter {
            $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame
                || aliases[$0.id]?.localizedCaseInsensitiveCompare(selector) == .orderedSame
        }
        if let resolved = only(named) { return resolved }

        if let required = ProjectXcodeMatcher.normalizeVersion(selector) {
            let matching = installations.filter { ProjectXcodeMatcher.version($0.version, matches: required) }
            if let resolved = only(matching) { return resolved }
        }

        return .notFound
    }

    private static func only(_ matches: [XcodeInstallation]) -> Resolution? {
        switch matches.count {
        case 0:
            return nil
        case 1:
            return .resolved(matches[0].id)
        default:
            return .ambiguous(matches.map(\.id))
        }
    }
}
