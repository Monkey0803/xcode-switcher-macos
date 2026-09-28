import Foundation

/// A project that pins an installation, together with where that decision lives.
///
/// The distinction is what makes the refusal actionable: an App binding is changed in the
/// 「项目」 page, while a repository's `.xcode-switcher.json` is changed in the repository.
/// A message that sends the user to the wrong one is worse than a vague one.
public struct XcodeRemovalBinding: Equatable, Sendable, Identifiable {
    public enum Origin: Equatable, Sendable {
        /// `AppConfiguration.projects[].xcodeID` — the App knows this project.
        case appProfile
        /// The project's own `.xcode-switcher.json`. A repository can carry one so that
        /// everyone who clones it inherits the pin, which is why this cannot be ignored
        /// just because the project was never added to the App.
        case localConfiguration(String)
    }

    public let projectName: String
    public let origin: Origin

    public init(projectName: String, origin: Origin) {
        self.projectName = projectName
        self.origin = origin
    }

    public var id: String {
        switch origin {
        case .appProfile:
            return "app:\(projectName)"
        case .localConfiguration(let path):
            return "local:\(path)"
        }
    }
}

/// Answers "which projects pin this installation" for the removal guard.
///
/// Two stores can hold that decision and both are honoured: the App's project list, and the
/// `.xcode-switcher.json` next to a project (or above it — the file covers everything below
/// the directory it sits in, which is how a repository pins all of its projects at once).
///
/// Until 2026-09-28 only the first was read. `README.md` documents the second as a supported
/// team arrangement (「项目也可以在仓库中保存 `.xcode-switcher.json`」), so a project could pin
/// a version and still have it moved to the Trash. Found while closing the same class of hole
/// for `xcodeswitcher pin`, which writes exactly that file.
public enum ProjectBindingLocator {
    public static func bindings(
        to installation: XcodeInstallation,
        among installations: [XcodeInstallation],
        profiles: [ProjectProfile],
        discoveredProjects: [URL] = [],
        aliases: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> [XcodeRemovalBinding] {
        var bindings: [XcodeRemovalBinding] = []
        var seenProjectPaths = Set<String>()

        for profile in profiles where profile.xcodeID == installation.id {
            guard seenProjectPaths.insert(profile.url.standardizedFileURL.path).inserted else { continue }
            bindings.append(XcodeRemovalBinding(projectName: profile.name, origin: .appProfile))
        }

        // One file can cover several projects, so the file — not the project — is what is
        // reported, named after the directory that holds it.
        var seenConfigurationPaths = Set<String>()
        var candidates = profiles.map(\.url)
        candidates.append(contentsOf: discoveredProjects)

        for projectURL in candidates {
            guard let configurationURL = ProjectLocalConfigurationStore.configurationURL(
                for: projectURL,
                fileManager: fileManager
            ) else { continue }
            let path = configurationURL.path
            guard seenConfigurationPaths.insert(path).inserted else { continue }
            guard let configuration = ProjectLocalConfigurationStore.load(
                for: projectURL,
                fileManager: fileManager
            ), let selector = configuration.xcode?.trimmingCharacters(in: .whitespacesAndNewlines),
                !selector.isEmpty else { continue }
            guard pins(selector, to: installation, among: installations, aliases: aliases) else { continue }

            bindings.append(
                XcodeRemovalBinding(
                    projectName: configurationURL.deletingLastPathComponent().lastPathComponent,
                    origin: .localConfiguration(path)
                )
            )
        }

        return bindings
    }

    /// Whether a local selector means this installation.
    ///
    /// An ambiguous selector — a repository that says `"27.0"` while a beta and a release of
    /// 27.0 are installed — counts as a binding for **every** candidate. Refusing to remove
    /// either one is the only answer that cannot be wrong: the file does not say which, and
    /// the same rule already governs the command line since 2.2.2.
    private static func pins(
        _ selector: String,
        to installation: XcodeInstallation,
        among installations: [XcodeInstallation],
        aliases: [String: String]
    ) -> Bool {
        switch XcodeSelector.resolve(selector, among: installations, aliases: aliases) {
        case let .resolved(id):
            return id == installation.id
        case let .ambiguous(ids):
            return ids.contains(installation.id)
        case .notFound:
            return false
        }
    }
}
