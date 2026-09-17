import Foundation

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
    /// The index carries both `Xcode` and `Xcode (Apple Silicon)` entries for the
    /// same build, so the plain name wins when both are present.
    static func release(matchingBuild build: String, in catalog: [XcodeReleaseInfo]) -> XcodeReleaseInfo? {
        let target = build.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        let matches = catalog.filter { $0.build.lowercased() == target }
        return matches.first { $0.name == "Xcode" } ?? matches.first
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
    /// True when a refresh was attempted, failed, and a stale copy was served
    /// instead — the UI says so rather than presenting old data as current.
    let refreshFailed: Bool
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
                XcodeReleaseCatalogSnapshot(releases: cached.releases, cachedAt: cached.cachedAt, refreshFailed: false)
            )
        }

        do {
            let data = try await fetch()
            let releases = try XcodeReleaseCatalog.parse(data)
            writeCache(data)
            return .success(
                XcodeReleaseCatalogSnapshot(releases: releases, cachedAt: nil, refreshFailed: false)
            )
        } catch {
            if let cached {
                return .success(
                    XcodeReleaseCatalogSnapshot(releases: cached.releases, cachedAt: cached.cachedAt, refreshFailed: true)
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
