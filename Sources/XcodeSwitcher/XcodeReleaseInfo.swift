import Foundation
import XcodeSwitcherKit

/// One Xcode release as the community index at `xcodereleases.com` publishes it.
///
/// The index is keyed by Apple's **public build string**, which is the only field
/// that reliably identifies a release. An installed bundle reports other
/// build-shaped numbers that are not it — see `XcodeBundleMetadata` — so every
/// lookup goes through `version.plist` / `xcodebuild -version`.
struct XcodeReleaseInfo: Equatable, Sendable {
    /// Which channel the entry belongs to.
    ///
    /// The index uses six distinct keys across its 453 entries — `beta` (215),
    /// `release` (136), `rc` (49), `gmSeed` (22), `gm` (19), `dp` (12) — and every
    /// entry carries exactly one. Modelling only the first three would report a GM
    /// seed or a developer preview as a shipped release.
    enum Channel: Equatable, Sendable {
        case release
        case goldenMaster(seed: Int?)
        case releaseCandidate(Int)
        case beta(Int)
        case developerPreview(Int)

        /// Precedence used to choose one entry when a build appears more than once.
        ///
        /// 32 of the 60 repeated builds in the real index disagree about the channel —
        /// `27A266a` is both `release` and `rc1`, `17F113` both `release` and `rc2` —
        /// so the choice has to be a rule. Taking "the first match" is how a shipped
        /// Xcode gets listed as a release candidate.
        var precedence: Int {
            switch self {
            case .release: return 0
            case .goldenMaster: return 1
            case .releaseCandidate: return 2
            case .beta: return 3
            case .developerPreview: return 4
            }
        }

        var label: String {
            switch self {
            case .release: return String(localized: "正式版")
            case .goldenMaster(let seed):
                guard let seed else { return String(localized: "GM") }
                return String(localized: "GM Seed \(seed)")
            case .releaseCandidate(let number): return String(localized: "RC \(number)")
            case .beta(let number): return String(localized: "Beta \(number)")
            case .developerPreview(let number): return String(localized: "DP \(number)")
            }
        }
    }

    struct Component: Equatable, Sendable {
        let version: String
        let build: String?

        var label: String {
            guard let build, !build.isEmpty else { return version }
            guard !version.isEmpty else { return build }
            return "\(version) (\(build))"
        }
    }

    struct SDK: Equatable, Sendable {
        let platform: String
        let version: String
        let build: String?

        /// An SDK component is not guaranteed to carry a version: 365 of them in the
        /// real index have only a build, so the label has to cope with either.
        var label: String {
            let hasVersion = !version.isEmpty
            let buildText = build.flatMap { $0.isEmpty ? nil : $0 }
            switch (hasVersion, buildText) {
            case (true, let build?): return "\(platform) \(version) (\(build))"
            case (true, nil): return "\(platform) \(version)"
            case (false, let build?): return "\(platform) \(build)"
            case (false, nil): return platform
            }
        }
    }

    let name: String
    let version: String
    let build: String
    let channel: Channel
    /// The index publishes a calendar date, not an instant, so it is kept as
    /// components and only turned into a string at display time.
    let releaseDate: DateComponents?
    /// The minimum macOS the release itself requires, e.g. "15.6".
    let minimumMacOS: String?
    let sdks: [SDK]
    let swift: Component?
    let clang: Component?
    let notesURL: URL?
    let downloadURL: URL?
    let downloadArchitectures: [String]

    /// The release date rendered in UTC.
    ///
    /// Deliberately not the machine's timezone: `{2026, 2, 26}` is a date, and
    /// formatting it west of Greenwich would print the 25th.
    func releaseDateText(locale: Locale = .current) -> String? {
        guard let releaseDate,
              let date = Self.utcCalendar.date(from: releaseDate) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func releaseDateText(language: String) -> String? {
        releaseDateText(locale: Locale(identifier: language))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

/// Parsing and lookup for the release index. Pure, so it is covered without a
/// network round trip.
/// What stops a release from running on the Mac this app is on, if anything.
///
/// The index states a minimum macOS per release ("15.6", "10.15.4") and, since Xcode
/// 26, the architectures the download ships for. Both are worth *comparing* rather than
/// only printing: on a macOS 15 machine "需要 macOS 26.6" means the release cannot be
/// installed here at all, while an x86_64-only build does run on Apple Silicon — under
/// Rosetta 2, which the environment doctor already checks for.
enum XcodeReleaseHostCompatibility: Equatable, Sendable {
    case runs
    /// The release needs a newer macOS than the one this Mac is running.
    case needsNewerOS(required: String)
    /// No arm64 download, so Rosetta 2 is needed. It still runs here.
    case needsRosetta

    /// True when the release cannot run here at all. Rosetta is a caveat, not a block.
    var isBlocking: Bool {
        if case .needsNewerOS = self { return true }
        return false
    }
}

extension XcodeReleaseInfo {
    /// Whether this release can run on a given macOS version and architecture.
    ///
    /// An absent or unparseable `minimumMacOS`, and an empty `downloadArchitectures`,
    /// all mean the index does not say — treated as no constraint rather than as a
    /// guess in either direction.
    func hostCompatibility(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isAppleSilicon: Bool = XcodeReleaseInfo.isAppleSilicon
    ) -> XcodeReleaseHostCompatibility {
        if let minimum = minimumMacOS,
           let required = Self.versionComponents(minimum),
           Self.compare(operatingSystem, required) == .orderedAscending {
            return .needsNewerOS(required: minimum)
        }
        if isAppleSilicon,
           !downloadArchitectures.isEmpty,
           !downloadArchitectures.contains("arm64") {
            return .needsRosetta
        }
        return .runs
    }

    /// The query Apple's downloads page expects in `?q=`.
    ///
    /// Apple titles these entries "Xcode 27.1 beta 1" and "Xcode 26.3", so the channel word
    /// only appears for pre-releases — and it is deliberately **not** the localized
    /// `Channel.label`, which is display text (「正式版」) that would find nothing there.
    var downloadsPageQuery: String {
        switch channel {
        case .release:
            return "Xcode \(version)"
        case .goldenMaster(let seed):
            return seed.map { "Xcode \(version) GM seed \($0)" } ?? "Xcode \(version) GM"
        case .releaseCandidate(let number):
            return "Xcode \(version) RC \(number)"
        case .beta(let number):
            return "Xcode \(version) beta \(number)"
        case .developerPreview(let number):
            return "Xcode \(version) DP \(number)"
        }
    }

    /// The download page that works for a person: it signs them in and asks for the license,
    /// then offers the file.
    ///
    /// `downloadURL` is the raw asset on `download.developer.apple.com`, which needs a
    /// developer session cookie this app cannot supply; without one Apple does not return an
    /// error but redirects to `/unauthorized/`. Verified 2026-09-21 against the real URL —
    /// `HTTP/2 302, location: https://developer.apple.com/unauthorized/`.
    var downloadsPageURL: URL? {
        var components = URLComponents(string: "https://developer.apple.com/download/all/")
        components?.queryItems = [URLQueryItem(name: "q", value: downloadsPageQuery)]
        return components?.url
    }

    /// The running macOS written the way the index writes it ("15.6"), so a requirement
    /// and this Mac can be read side by side without reformatting either.
    static var runningOSDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// This app ships for Apple Silicon only, so the answer is fixed at compile time.
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// "10.15.4" → (10, 15, 4). A component that is not a number makes the whole
    /// requirement unknown, which is safer than comparing a half-parsed version.
    private static func versionComponents(_ text: String) -> OperatingSystemVersion? {
        let raw = text.split(separator: ".")
        let parts = raw.compactMap { Int($0) }
        guard parts.count == raw.count, let major = parts.first else { return nil }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
    }

    private static func compare(
        _ lhs: OperatingSystemVersion,
        _ rhs: OperatingSystemVersion
    ) -> ComparisonResult {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion ? .orderedAscending : .orderedDescending
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion ? .orderedAscending : .orderedDescending
        }
        if lhs.patchVersion != rhs.patchVersion {
            return lhs.patchVersion < rhs.patchVersion ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

enum XcodeReleaseCatalog {
    /// Decodes the whole index. Entries without a build string are dropped: they
    /// cannot be matched to an installed Xcode, which is the only thing this is for.
    static func parse(_ data: Data) throws -> [XcodeReleaseInfo] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.compactMap { entry in
            let build = entry.version.build.trimmingCharacters(in: .whitespaces)
            guard !build.isEmpty else { return nil }
            return XcodeReleaseInfo(
                name: entry.name,
                version: entry.version.number,
                build: build,
                channel: entry.version.release.channel,
                releaseDate: entry.date?.components,
                minimumMacOS: entry.requires,
                sdks: Self.sdks(from: entry.sdks),
                swift: entry.compilers?.swift?.first.flatMap(Self.component),
                clang: entry.compilers?.clang?.first.flatMap(Self.component),
                notesURL: entry.links?.notes?.url.flatMap(URL.init(string:)),
                downloadURL: entry.links?.download?.url.flatMap(URL.init(string:)),
                downloadArchitectures: entry.links?.download?.architectures ?? []
            )
        }
    }

    /// The entry for a build string.
    ///
    /// A build can appear several times — as `Xcode` and as `Xcode (Apple Silicon)`,
    /// and even under different channels — so the winner is chosen by
    /// `mostReleased(in:)` rather than by whichever happens to come first. The
    /// earlier version of this function compared only the distribution name, which
    /// made the result depend on the order of the data file.
    static func release(matchingBuild build: String, in catalog: [XcodeReleaseInfo]) -> XcodeReleaseInfo? {
        let target = build.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        return mostReleased(in: catalog.filter { $0.build.lowercased() == target })
    }

    /// The entry that best represents one build: the most released channel first,
    /// then the plain distribution name over its variants.
    static func mostReleased(in releases: [XcodeReleaseInfo]) -> XcodeReleaseInfo? {
        releases.min { preference($0) < preference($1) }
    }

    /// One row per build, which is what a "every Xcode version" list needs: 453
    /// index entries collapse to 387 distinct builds.
    static func uniqueReleases(from catalog: [XcodeReleaseInfo]) -> [XcodeReleaseInfo] {
        Dictionary(grouping: catalog, by: { $0.build.lowercased() })
            .values
            .compactMap { mostReleased(in: $0) }
    }

    private static func preference(_ release: XcodeReleaseInfo) -> (Int, Int) {
        (release.channel.precedence, nameRank(release.name))
    }

    /// The plain `Xcode` entry is the one whose metadata the app shows; the Apple
    /// Silicon and Universal entries describe the same build.
    private static func nameRank(_ name: String) -> Int {
        switch name {
        case "Xcode": return 0
        case "Xcode (Universal)": return 1
        case "Xcode (Apple Silicon)": return 2
        default: return 3
        }
    }

    /// Orders dotted version numbers numerically.
    ///
    /// Text comparison puts `9.0` above `26.3`, which is exactly wrong in a list of
    /// releases, so the components are compared as integers and missing ones count
    /// as zero (`9.3.1` vs `9.3`).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(of: lhs)
        let right = components(of: rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// A toolchain entry, or nil when it carries neither a version nor a build.
    private static func component(_ raw: Entry.Component) -> XcodeReleaseInfo.Component? {
        let version = raw.number ?? ""
        let build = raw.build ?? ""
        guard !version.isEmpty || !build.isEmpty else { return nil }
        return XcodeReleaseInfo.Component(version: version, build: raw.build)
    }

    /// A stable platform order, so the list does not reshuffle between launches.
    private static let platformOrder = ["iOS", "macOS", "tvOS", "watchOS", "visionOS"]

    private static func sdks(from dictionary: [String: [Entry.Component]]?) -> [XcodeReleaseInfo.SDK] {
        guard let dictionary else { return [] }
        return dictionary
            .compactMap { platform, components -> XcodeReleaseInfo.SDK? in
                // 365 SDK components in the real index carry a build but no version,
                // so the first usable one is chosen rather than the first one.
                guard let usable = components.first(where: {
                    !($0.number ?? "").isEmpty || !($0.build ?? "").isEmpty
                }) else { return nil }
                return XcodeReleaseInfo.SDK(platform: platform, version: usable.number ?? "", build: usable.build)
            }
            .sorted { lhs, rhs in
                let left = platformOrder.firstIndex(of: lhs.platform) ?? platformOrder.count
                let right = platformOrder.firstIndex(of: rhs.platform) ?? platformOrder.count
                if left != right { return left < right }
                return lhs.platform < rhs.platform
            }
    }

    // MARK: - Decoding

    private struct Entry: Decodable {
        struct Version: Decodable {
            struct Release: Decodable {
                let release: Bool?
                let gm: Bool?
                let gmSeed: Int?
                let rc: Int?
                let beta: Int?
                let dp: Int?

                /// Every entry in the index carries exactly one of these keys, so the
                /// order only decides what to do if that ever stops being true.
                var channel: XcodeReleaseInfo.Channel {
                    if release == true { return .release }
                    if gm == true { return .goldenMaster(seed: nil) }
                    if let gmSeed { return .goldenMaster(seed: gmSeed) }
                    if let rc { return .releaseCandidate(rc) }
                    if let beta { return .beta(beta) }
                    if let dp { return .developerPreview(dp) }
                    return .release
                }
            }

            let number: String
            let build: String
            let release: Release

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                number = try container.decode(String.self, forKey: .number)
                build = try container.decode(String.self, forKey: .build)
                // Absent for a shipped release, and the key is sometimes the bare
                // boolean rather than the usual keyed object.
                release = (try? container.decode(Release.self, forKey: .release))
                    ?? Release(release: true, gm: nil, gmSeed: nil, rc: nil, beta: nil, dp: nil)
            }

            private enum CodingKeys: String, CodingKey { case number, build, release }
        }

        struct Component: Decodable {
            /// Optional because 365 SDK entries in the real index have no version.
            let number: String?
            let build: String?
        }

        struct DateParts: Decodable {
            let year: Int
            let month: Int
            let day: Int

            var components: DateComponents {
                DateComponents(year: year, month: month, day: day)
            }
        }

        struct Compilers: Decodable {
            let clang: [Component]?
            let swift: [Component]?
        }

        struct Link: Decodable {
            let url: String?
        }

        struct Download: Decodable {
            let url: String?
            let architectures: [String]?
        }

        struct Links: Decodable {
            let notes: Link?
            let download: Download?
        }

        let name: String
        let version: Version
        let date: DateParts?
        let requires: String?
        let sdks: [String: [Component]]?
        let compilers: Compilers?
        let links: Links?
    }
}

/// A loaded index plus how current it is.
struct XcodeReleaseCatalogSnapshot: Sendable {
    let releases: [XcodeReleaseInfo]
    /// When the on-disk copy was written, when the result came from it.
    let cachedAt: Date?
    /// Why a refresh failed, when one was attempted, failed, and a stale copy was
    /// served instead. The UI says so rather than presenting old data as current —
    /// and shows this, so a dropped connection can be told apart from a rejected
    /// response without guessing.
    let failure: String?
}

/// Loads and caches the release index.
///
/// `fetch`, `cacheURL` and `maxAge` are constructor parameters so the caching and
/// offline behaviour are covered by tests without touching the network. The app
/// uses `.live`.
struct XcodeReleaseCatalogStore: Sendable {
    typealias Fetch = @Sendable () async throws -> Data

    enum LoadError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }

    let fetch: Fetch
    let cacheURL: URL
    /// How long a cached copy is served before a refresh is attempted.
    let maxAge: TimeInterval

    static let datasetURL = URL(string: "https://xcodereleases.com/data.json")!

    static var live: XcodeReleaseCatalogStore {
        XcodeReleaseCatalogStore(
            fetch: { try await download() },
            cacheURL: defaultCacheURL,
            maxAge: 24 * 60 * 60
        )
    }

    static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("XcodeSwitcher", isDirectory: true)
            .appendingPathComponent("xcodereleases.json")
    }

    static func download() async throws -> Data {
        var request = URLRequest(url: datasetURL)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LoadError.unavailable(String(localized: "发布信息服务器返回了错误响应。"))
        }
        return data
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "XcodeSwitcher/\(version)"
    }

    /// A fresh cache is served as-is. Anything else fetches; if the fetch fails but
    /// a cache exists, the stale copy is served and flagged, because a list that may
    /// be a day out of date beats showing nothing.
    func load(
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async -> Result<XcodeReleaseCatalogSnapshot, LoadError> {
        let cached = readCache()
        if !forceRefresh, let cached, now.timeIntervalSince(cached.cachedAt) < maxAge {
            return .success(
                XcodeReleaseCatalogSnapshot(releases: cached.releases, cachedAt: cached.cachedAt, failure: nil)
            )
        }

        do {
            let data = try await fetch()
            let releases = try XcodeReleaseCatalog.parse(data)
            writeCache(data)
            return .success(
                XcodeReleaseCatalogSnapshot(releases: releases, cachedAt: nil, failure: nil)
            )
        } catch {
            if let cached {
                return .success(
                    XcodeReleaseCatalogSnapshot(releases: cached.releases, cachedAt: cached.cachedAt, failure: error.localizedDescription)
                )
            }
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    private func readCache() -> (releases: [XcodeReleaseInfo], cachedAt: Date)? {
        let manager = FileManager.default
        guard let data = try? Data(contentsOf: cacheURL),
              let attributes = try? manager.attributesOfItem(atPath: cacheURL.path),
              let cachedAt = attributes[.modificationDate] as? Date,
              let releases = try? XcodeReleaseCatalog.parse(data),
              !releases.isEmpty else { return nil }
        return (releases, cachedAt)
    }

    private func writeCache(_ data: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// What an installed bundle says about itself with no network at all.
struct XcodeInstallDetails: Equatable, Sendable {
    let version: String
    let build: String
    /// `LSMinimumSystemVersion` — the release's own macOS requirement, which the
    /// bundle states locally and the index states remotely.
    let minimumMacOS: String?
    let platformVersion: String?
    let sdkBuild: String?
    let compiler: String?

    static func read(appURL: URL, fallbackBuild: String) -> XcodeInstallDetails {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let info = (NSDictionary(contentsOf: infoURL) as? [String: Any]) ?? [:]
        return XcodeInstallDetails(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: XcodeBundleMetadata.publicBuild(appURL: appURL) ?? fallbackBuild,
            minimumMacOS: info["LSMinimumSystemVersion"] as? String,
            platformVersion: info["DTPlatformVersion"] as? String,
            sdkBuild: info["DTSDKBuild"] as? String,
            compiler: info["DTCompiler"] as? String
        )
    }
}

/// How the "every Xcode version" list is narrowed and ordered.
///
/// Pure: the window holds one as state and calls `apply(to:installedBuilds:)`, so
/// filtering and ordering are covered by tests instead of by looking at the list.
struct XcodeReleaseQuery: Equatable, Sendable {
    /// Which channels to keep. A golden master counts as shipping — it is the build
    /// that becomes the release.
    enum ChannelScope: String, CaseIterable, Identifiable, Sendable {
        case all
        case shipping
        case prerelease

        var id: Self { self }

        var title: String {
            switch self {
            case .all: return String(localized: "全部渠道")
            case .shipping: return String(localized: "仅正式版")
            case .prerelease: return String(localized: "仅预发布")
            }
        }

        func includes(_ channel: XcodeReleaseInfo.Channel) -> Bool {
            let isShipping: Bool
            switch channel {
            case .release, .goldenMaster: isShipping = true
            case .releaseCandidate, .beta, .developerPreview: isShipping = false
            }
            switch self {
            case .all: return true
            case .shipping: return isShipping
            case .prerelease: return !isShipping
            }
        }
    }

    enum InstallationScope: String, CaseIterable, Identifiable, Sendable {
        case all
        case installed
        case notInstalled

        var id: Self { self }

        var title: String {
            switch self {
            case .all: return String(localized: "全部")
            case .installed: return String(localized: "已安装")
            case .notInstalled: return String(localized: "未安装")
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case version
        case releaseDate

        var id: Self { self }

        var title: String {
            switch self {
            case .version: return String(localized: "按版本")
            case .releaseDate: return String(localized: "按发布日期")
            }
        }
    }

    enum SortDirection: String, CaseIterable, Identifiable, Sendable {
        case descending
        case ascending

        var id: Self { self }

        var title: String {
            switch self {
            case .descending: return String(localized: "从新到旧")
            case .ascending: return String(localized: "从旧到新")
            }
        }
    }

    /// Free text, matched against both the version and the build, because those are
    /// the two things someone arrives with.
    var search = ""
    var channelScope: ChannelScope = .all
    var installationScope: InstallationScope = .all
    var sort: Sort = .version
    var direction: SortDirection = .descending
    /// The index carries eight 2005-era `Xcode Tools` packages next to Xcode itself.
    /// They stay in by default, since they are genuinely Xcode releases, and can be
    /// hidden.
    var includesTools = true
    /// Releases this Mac cannot run stay in by default — carrying a badge — because the
    /// index is also a catalogue of what exists. They can be hidden, since a version
    /// that cannot be installed here is noise while browsing.
    var hidesIncompatible = false

    func apply(
        to releases: [XcodeReleaseInfo],
        installedBuilds: Set<String>,
        incompatibleBuilds: Set<String> = []
    ) -> [XcodeReleaseInfo] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = releases.filter { release in
            if !includesTools, release.name == "Xcode Tools" { return false }
            if hidesIncompatible, incompatibleBuilds.contains(release.build) { return false }
            guard channelScope.includes(release.channel) else { return false }

            let installed = installedBuilds.contains(release.build.lowercased())
            switch installationScope {
            case .all: break
            case .installed: guard installed else { return false }
            case .notInstalled: guard !installed else { return false }
            }

            guard !needle.isEmpty else { return true }
            return release.version.lowercased().contains(needle)
                || release.build.lowercased().contains(needle)
        }

        return filtered.sorted { lhs, rhs in
            let ascending: Bool
            switch sort {
            case .version:
                let result = XcodeReleaseCatalog.compareVersions(lhs.version, rhs.version)
                // A version number can be shared by several builds, so the build
                // breaks the tie and the order stays stable.
                ascending = result == .orderedSame ? lhs.build < rhs.build : result == .orderedAscending
            case .releaseDate:
                // Undated entries sort as oldest rather than dropping out.
                ascending = (dateKey(lhs) ?? 0) < (dateKey(rhs) ?? 0)
            }
            return direction == .descending ? !ascending : ascending
        }
    }

    /// A locale-independent integer for a release date, so ordering never depends on
    /// how a date happens to be formatted.
    private func dateKey(_ release: XcodeReleaseInfo) -> Int? {
        guard let date = release.releaseDate,
              let year = date.year, let month = date.month, let day = date.day else { return nil }
        return year * 10_000 + month * 100 + day
    }
}
