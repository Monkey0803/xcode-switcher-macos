import Foundation
import XCTest
@testable import XcodeSwitcher

final class XcodeReleaseInfoTests: XCTestCase {
    /// Trimmed from the real `xcodereleases.com/data.json`, keeping one entry of
    /// each channel and the fields the app displays.
    private static let dataset = """
    [
      {
        "name": "Xcode",
        "version": { "number": "26.3", "build": "17C529", "release": { "release": true } },
        "date": { "year": 2026, "month": 2, "day": 26 },
        "requires": "15.6",
        "sdks": {
          "iOS": [ { "number": "26.2", "build": "23C57" } ],
          "macOS": [ { "number": "26.2", "build": "25C58" } ]
        },
        "compilers": {
          "clang": [ { "number": "17.0.0", "build": "1700.6.4.2" } ],
          "swift": [ { "number": "6.2.4", "build": "6.2.4.1.4" } ]
        },
        "links": {
          "notes": { "url": "https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes" },
          "download": {
            "url": "https://download.developer.apple.com/Developer_Tools/Xcode_26.3/Xcode_26.3_Universal.xip",
            "architectures": [ "arm64", "x86_64" ]
          }
        }
      },
      {
        "name": "Xcode (Apple Silicon)",
        "version": { "number": "26.3", "build": "17C529", "release": { "release": true } },
        "date": { "year": 2026, "month": 2, "day": 26 },
        "requires": "15.6"
      },
      {
        "name": "Xcode",
        "version": { "number": "26.3", "build": "17C528", "release": { "rc": 2 } },
        "date": { "year": 2026, "month": 2, "day": 20 },
        "requires": "15.6"
      },
      {
        "name": "Xcode",
        "version": { "number": "27.2", "build": "27B5019j", "release": { "beta": 1 } },
        "date": { "year": 2026, "month": 9, "day": 16 },
        "requires": "26.6"
      },
      {
        "name": "Xcode",
        "version": { "number": "12.1", "build": "12A7403", "release": { "gm": true } },
        "date": { "year": 2020, "month": 11, "day": 10 },
        "requires": "10.15.4"
      },
      {
        "name": "Xcode",
        "version": { "number": "12.1", "build": "12A7397e", "release": { "gmSeed": 2 } },
        "date": { "year": 2020, "month": 11, "day": 5 },
        "requires": "10.15.4"
      },
      {
        "name": "Xcode",
        "version": { "number": "5.1", "build": "5B71f", "release": { "dp": 2 } },
        "date": { "year": 2013, "month": 6, "day": 12 },
        "requires": "10.8",
        "sdks": { "iOS": [ { "build": "15E5201e" } ] }
      },
      {
        "name": "Xcode",
        "version": { "number": "26.6", "build": "17F113", "release": { "release": true } },
        "date": { "year": 2026, "month": 8, "day": 1 },
        "requires": "15.6"
      },
      {
        "name": "Xcode (Apple Silicon)",
        "version": { "number": "26.6", "build": "17F113", "release": { "release": true } },
        "date": { "year": 2026, "month": 8, "day": 1 },
        "requires": "15.6"
      },
      {
        "name": "Xcode",
        "version": { "number": "26.6", "build": "17F113", "release": { "rc": 2 } },
        "date": { "year": 2026, "month": 7, "day": 20 },
        "requires": "15.6"
      },
      {
        "name": "Xcode",
        "version": { "number": "9.0", "build": "9A1000", "release": { "release": true } },
        "date": { "year": 2017, "month": 9, "day": 19 },
        "requires": "10.12.6"
      },
      {
        "name": "Xcode Tools",
        "version": { "number": "2.2.1", "build": "8G1165", "release": { "release": true } },
        "date": { "year": 2006, "month": 1, "day": 13 },
        "requires": "10.4"
      },
      {
        "name": "Xcode (Universal)",
        "version": { "number": "12.0", "build": "12A8161k", "release": { "release": true } },
        "date": { "year": 2020, "month": 7, "day": 7 },
        "requires": "10.15.4"
      }
    ]
    """.data(using: .utf8)!

    private func catalog() throws -> [XcodeReleaseInfo] {
        try XcodeReleaseCatalog.parse(Self.dataset)
    }

    // MARK: - Parsing

    func testParsesEntriesAndDropsOnesWithoutABuild() throws {
        let releases = try catalog()
        XCTAssertEqual(releases.count, 13)
        XCTAssertFalse(releases.contains { $0.build.isEmpty })
    }

    func testParsesTheFieldsThePanelShows() throws {
        let release = try XCTUnwrap(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: try catalog()))

        XCTAssertEqual(release.name, "Xcode")
        XCTAssertEqual(release.version, "26.3")
        XCTAssertEqual(release.channel, .release)
        XCTAssertEqual(release.minimumMacOS, "15.6")
        XCTAssertEqual(release.releaseDate, DateComponents(year: 2026, month: 2, day: 26))
        XCTAssertEqual(release.sdks.map(\.platform), ["iOS", "macOS"])
        XCTAssertEqual(release.sdks.first?.label, "iOS 26.2 (23C57)")
        XCTAssertEqual(release.swift?.label, "6.2.4 (6.2.4.1.4)")
        XCTAssertEqual(release.clang?.version, "17.0.0")
        XCTAssertEqual(release.downloadArchitectures, ["arm64", "x86_64"])
        XCTAssertEqual(release.notesURL?.host, "developer.apple.com")
    }

    func testReleaseChannelsAreDistinguished() throws {
        let releases = try catalog()
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C528", in: releases)?.channel, .releaseCandidate(2))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "27B5019j", in: releases)?.channel, .beta(1))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: releases)?.channel, .release)
    }

    func testMatchingPrefersThePlainXcodeEntry() throws {
        // The index carries both names for one build; the plain one is the app's.
        let release = try XCTUnwrap(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: try catalog()))
        XCTAssertEqual(release.name, "Xcode")
    }

    func testMatchingIsCaseInsensitiveAndTolerantOfWhitespace() throws {
        let releases = try catalog()
        XCTAssertNotNil(XcodeReleaseCatalog.release(matchingBuild: "17c529", in: releases))
        XCTAssertNotNil(XcodeReleaseCatalog.release(matchingBuild: " 17C529 ", in: releases))
        XCTAssertNil(XcodeReleaseCatalog.release(matchingBuild: "", in: releases))
        XCTAssertNil(XcodeReleaseCatalog.release(matchingBuild: "0X0000", in: releases))
    }

    /// The trap this whole lookup exists to avoid.
    ///
    /// Xcode 26.3's `Info.plist` says `DTXcodeBuild = 17C528`, which the index
    /// records as **RC 2**; the shipped build is `17C529`. So a lookup keyed on
    /// `DTXcodeBuild` would confidently label a released Xcode a release candidate —
    /// which is why `XcodeBundleMetadata` reads `version.plist` instead.
    func testDtxcodeBuildWouldResolveToTheWrongChannel() throws {
        let releases = try catalog()
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C528", in: releases)?.channel, .releaseCandidate(2))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: releases)?.channel, .release)
    }

    func testReleaseDateIsFormattedInUTC() throws {
        let release = try XCTUnwrap(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: try catalog()))
        // Formatting in the machine's timezone west of Greenwich would print Feb 25.
        XCTAssertEqual(release.releaseDateText(locale: Locale(identifier: "en_US_POSIX")), "Feb 26, 2026")
    }

    func testMalformedDataIsRejectedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try XcodeReleaseCatalog.parse(Data("not json".utf8)))
    }

    // MARK: - Caching and offline behaviour

    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func makeStore(
        cacheURL: URL,
        maxAge: TimeInterval = 24 * 60 * 60,
        fetch: @escaping XcodeReleaseCatalogStore.Fetch
    ) -> XcodeReleaseCatalogStore {
        XcodeReleaseCatalogStore(fetch: fetch, cacheURL: cacheURL, maxAge: maxAge)
    }

    private func temporaryCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcode-switcher-release-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("xcodereleases.json")
    }

    func testFetchIsUsedWhenThereIsNoCache() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let store = makeStore(cacheURL: cacheURL, fetch: { Self.dataset })

        let result = await store.load()

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.releases.count, 13)
        XCTAssertNil(snapshot.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "抓取后应写入缓存")
    }

    func testFreshCacheIsServedWithoutFetching() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let counter = FetchCounter()
        let store = makeStore(cacheURL: cacheURL, fetch: {
            counter.increment()
            return Self.dataset
        })

        _ = await store.load()                      // populates the cache
        let second = await store.load()             // must not fetch again

        let snapshot = try XCTUnwrap(try? second.get())
        XCTAssertEqual(counter.value, 1, "24 小时内的缓存不应再次联网")
        XCTAssertNil(snapshot.failure)
        XCTAssertNotNil(snapshot.cachedAt)
    }

    func testStaleCacheIsServedWhenTheRefreshFails() async throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let populated = makeStore(cacheURL: cacheURL, maxAge: 0, fetch: { Self.dataset })
        _ = await populated.load()

        // maxAge 0 makes any cache stale, so this must attempt a refresh.
        let offline = makeStore(cacheURL: cacheURL, maxAge: 0, fetch: {
            throw URLError(.notConnectedToInternet)
        })
        let result = await offline.load()

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.releases.count, 13, "离线时应回退到过期缓存，而不是什么都不显示")
        // 原因要一路带上来，界面才能说出「为什么」而不是只说「失败了」。
        XCTAssertEqual(snapshot.failure, URLError(.notConnectedToInternet).localizedDescription)
    }

    func testNoCacheAndFailedFetchReportsUnavailable() async {
        let cacheURL = temporaryCacheURL()
        let store = makeStore(cacheURL: cacheURL, fetch: { throw URLError(.notConnectedToInternet) })

        let result = await store.load()

        guard case .failure = result else {
            return XCTFail("既无缓存又抓取失败时应当报不可用")
        }
    }

    func testCorruptCacheIsNotServed() async {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: cacheURL)

        let store = makeStore(cacheURL: cacheURL, fetch: { throw URLError(.notConnectedToInternet) })

        guard case .failure = await store.load() else {
            return XCTFail("损坏的缓存不能被当成有效数据")
        }
    }

    // MARK: - Local bundle details

    func testLocalDetailsPreferTheVersionPlistBuild() throws {
        // A synthetic bundle: Info.plist carries the numbers that are *not* the
        // public build, version.plist carries the one that is.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcode-switcher-bundle-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info: [String: Any] = [
            "CFBundleShortVersionString": "26.3",
            "CFBundleVersion": "24587",
            "DTXcodeBuild": "17C528",
            "LSMinimumSystemVersion": "15.6",
            "DTPlatformVersion": "26.2",
            "DTSDKBuild": "25C16",
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0"
        ]
        let version: [String: Any] = ["ProductBuildVersion": "17C529"]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        try (version as NSDictionary).write(to: contents.appendingPathComponent("version.plist"))

        let details = XcodeInstallDetails.read(appURL: root, fallbackBuild: "fallback")

        XCTAssertEqual(details.version, "26.3")
        XCTAssertEqual(details.build, "17C529", "必须用 version.plist，而不是 DTXcodeBuild/CFBundleVersion")
        XCTAssertEqual(details.minimumMacOS, "15.6")
        XCTAssertEqual(details.platformVersion, "26.2")
        XCTAssertEqual(details.sdkBuild, "25C16")
        XCTAssertEqual(details.compiler, "com.apple.compilers.llvm.clang.1_0")
    }

    /// The index uses six channel keys, and every entry carries exactly one. Reading
    /// only `release`/`rc`/`beta` would report a GM seed or a developer preview as a
    /// shipped release.
    func testAllSixChannelKeysAreDistinguished() throws {
        let releases = try catalog()
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C529", in: releases)?.channel, .release)
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "12A7403", in: releases)?.channel, .goldenMaster(seed: nil))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "12A7397e", in: releases)?.channel, .goldenMaster(seed: 2))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17C528", in: releases)?.channel, .releaseCandidate(2))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "27B5019j", in: releases)?.channel, .beta(1))
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "5B71f", in: releases)?.channel, .developerPreview(2))
    }

    /// 365 SDK components in the real index have a build but no version, which used
    /// to make the whole decode throw — taking the entire feature down with it.
    func testAnSDKWithoutAVersionDoesNotBreakDecoding() throws {
        let release = try XCTUnwrap(XcodeReleaseCatalog.release(matchingBuild: "5B71f", in: try catalog()))
        XCTAssertEqual(release.sdks.count, 1)
        XCTAssertEqual(release.sdks.first?.version, "")
        XCTAssertEqual(release.sdks.first?.build, "15E5201e")
        XCTAssertEqual(release.sdks.first?.label, "iOS 15E5201e", "只有构建号时也要能显示")
    }


    // MARK: - 去重与择优

    /// The real index contains 60 repeated builds, and 32 of them disagree about the
    /// channel: build 17F113 is listed as both a release and an RC 2. Choosing by
    /// "first match" would list a shipped Xcode as a release candidate.
    func testMostReleasedChoosesByChannelNotByPosition() throws {
        let releases = try catalog().filter { $0.build == "17F113" }
        XCTAssertEqual(releases.count, 3, "fixture 有意包含同 build 的三种条目")

        let best = try XCTUnwrap(XcodeReleaseCatalog.mostReleased(in: releases))
        XCTAssertEqual(best.channel, .release)
        XCTAssertEqual(best.name, "Xcode")
    }

    /// And the plain-name preference must not beat the channel: with the release
    /// entry named `Xcode (Universal)`, it still wins over a plain-named RC.
    func testChannelOutranksTheDistributionName() throws {
        let rc = XcodeReleaseInfo(
            name: "Xcode", version: "26.6", build: "17F113", channel: .releaseCandidate(2),
            releaseDate: nil, minimumMacOS: nil, sdks: [], swift: nil, clang: nil,
            notesURL: nil, downloadURL: nil, downloadArchitectures: []
        )
        let shipped = XcodeReleaseInfo(
            name: "Xcode (Universal)", version: "26.6", build: "17F113", channel: .release,
            releaseDate: nil, minimumMacOS: nil, sdks: [], swift: nil, clang: nil,
            notesURL: nil, downloadURL: nil, downloadArchitectures: []
        )
        XCTAssertEqual(XcodeReleaseCatalog.mostReleased(in: [rc, shipped])?.channel, .release)
        XCTAssertEqual(XcodeReleaseCatalog.mostReleased(in: [shipped, rc])?.channel, .release)
    }

    func testUniqueReleasesCollapsesRepeatedBuilds() throws {
        let unique = XcodeReleaseCatalog.uniqueReleases(from: try catalog())
        XCTAssertEqual(unique.count, 10, "13 条应折叠为 10 个唯一构建号")
        XCTAssertEqual(Set(unique.map(\.build)).count, unique.count)

        let collapsed = try XCTUnwrap(unique.first { $0.build == "17F113" })
        XCTAssertEqual(collapsed.channel, .release)
    }

    func testMatchingABuildNowPrefersTheShippedEntry() throws {
        // 17F113 的 release 与 rc2 在同一条 fixture 里，顺序被刻意打乱
        let releases = try catalog()
        XCTAssertEqual(XcodeReleaseCatalog.release(matchingBuild: "17F113", in: releases)?.channel, .release)
    }

    // MARK: - 版本号比较

    func testVersionComparisonIsNumericNotTextual() {
        // 字符串比较会把 9.0 排在 26.3 前面
        XCTAssertEqual(XcodeReleaseCatalog.compareVersions("26.3", "9.0"), .orderedDescending)
        XCTAssertEqual(XcodeReleaseCatalog.compareVersions("9.0", "26.3"), .orderedAscending)
        XCTAssertEqual(XcodeReleaseCatalog.compareVersions("9.3.1", "9.3"), .orderedDescending)
        XCTAssertEqual(XcodeReleaseCatalog.compareVersions("9.3", "9.3.0"), .orderedSame)
        XCTAssertEqual(XcodeReleaseCatalog.compareVersions("26.3", "26.3"), .orderedSame)
    }

    // MARK: - 筛选与排序

    private func query(_ configure: (inout XcodeReleaseQuery) -> Void) throws -> [XcodeReleaseInfo] {
        var query = XcodeReleaseQuery()
        configure(&query)
        return query.apply(to: XcodeReleaseCatalog.uniqueReleases(from: try catalog()), installedBuilds: [])
    }

    func testDefaultOrderPutsTheNewestReleaseFirst() throws {
        let versions = try query { _ in }.map(\.version)
        XCTAssertEqual(versions.first, "27.2", "27.2 是 fixture 里最新的版本")
        XCTAssertEqual(versions.last, "2.2.1", "最旧的在最后")
    }

    func testAscendingVersionOrderReversesIt() throws {
        let versions = try query { $0.direction = .ascending }.map(\.version)
        XCTAssertEqual(versions.first, "2.2.1")
        XCTAssertEqual(versions.last, "27.2")
    }

    func testChannelScopeSeparatesShippingFromPrerelease() throws {
        let shipping = try query { $0.channelScope = .shipping }.map(\.channel)
        XCTAssertFalse(shipping.isEmpty)
        XCTAssertTrue(shipping.allSatisfy { $0 == .release || $0 == .goldenMaster(seed: nil) || $0.precedence <= 1 })

        let prerelease = try query { $0.channelScope = .prerelease }
        XCTAssertTrue(prerelease.allSatisfy { $0.channel.precedence > 1 })
        XCTAssertEqual(shipping.count + prerelease.count, 10, "两种渠道应覆盖全部且不重叠")
    }

    func testInstallationScopeUsesTheBuildString() throws {
        var query = XcodeReleaseQuery()
        query.installationScope = .installed
        let releases = XcodeReleaseCatalog.uniqueReleases(from: try catalog())
        let installed = query.apply(to: releases, installedBuilds: ["17c529"])
        XCTAssertEqual(installed.map(\.build), ["17C529"])

        query.installationScope = .notInstalled
        XCTAssertFalse(query.apply(to: releases, installedBuilds: ["17c529"]).contains { $0.build == "17C529" })
    }

    func testSearchMatchesVersionAndBuild() throws {
        XCTAssertEqual(try query { $0.search = "26.3" }.map(\.version).sorted(), ["26.3", "26.3"])
        XCTAssertEqual(try query { $0.search = "17f113" }.map(\.build), ["17F113"])
        XCTAssertTrue(try query { $0.search = "没有这个" }.isEmpty)
    }

    func testToolsPackagesCanBeHidden() throws {
        XCTAssertTrue(try query { _ in }.contains { $0.name == "Xcode Tools" })
        XCTAssertFalse(try query { $0.includesTools = false }.contains { $0.name == "Xcode Tools" })
        XCTAssertEqual(try query { $0.includesTools = false }.count, 9)
    }

    func testSortingByReleaseDateOrdersUndatedEntriesLast() throws {
        let releases = try query { $0.sort = .releaseDate }
        XCTAssertEqual(releases.first?.build, "27B5019j", "2026-09-16 是最新发布日期")
    }

    func testLocalDetailsFallBackWhenVersionPlistIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcode-switcher-bundle-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try (["CFBundleShortVersionString": "26.3"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let details = XcodeInstallDetails.read(appURL: root, fallbackBuild: "26.3 (fallback)")

        XCTAssertEqual(details.build, "26.3 (fallback)")
        XCTAssertNil(details.minimumMacOS)
    }

    // MARK: - 本机兼容性

    func testReleaseNeedingANewerMacOSIsBlocked() {
        let release = makeRelease(minimumMacOS: "26.6")
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)

        let compatibility = release.hostCompatibility(operatingSystem: host, isAppleSilicon: true)

        XCTAssertEqual(compatibility, .needsNewerOS(required: "26.6"))
        XCTAssertTrue(compatibility.isBlocking, "系统版本不够时属于「本机无法运行」")
    }

    func testEqualAndOlderRequirementsRun() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)

        XCTAssertEqual(
            makeRelease(minimumMacOS: "15.6").hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs,
            "正好等于要求应可运行"
        )
        XCTAssertEqual(
            makeRelease(minimumMacOS: "10.15.4").hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs,
            "两位数老版本号的比较不能被字典序骗到"
        )
    }

    func testPatchLevelIsCompared() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
        XCTAssertEqual(
            makeRelease(minimumMacOS: "15.6").hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs
        )
        let older = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        XCTAssertEqual(
            makeRelease(minimumMacOS: "15.6.1").hostCompatibility(operatingSystem: older, isAppleSilicon: true),
            .needsNewerOS(required: "15.6.1"),
            "补丁版本也要参与比较"
        )
    }

    func testUnknownRequirementIsNotTreatedAsABlock() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        XCTAssertEqual(
            makeRelease(minimumMacOS: nil).hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs,
            "索引没说最低版本时不作判断"
        )
        XCTAssertEqual(
            makeRelease(minimumMacOS: "未知").hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs,
            "解析不了的要求不能当成「装不了」"
        )
    }

    func testX86OnlyDownloadNeedsRosettaRatherThanBeingBlocked() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        let release = makeRelease(architectures: ["x86_64"])

        let compatibility = release.hostCompatibility(operatingSystem: host, isAppleSilicon: true)

        XCTAssertEqual(compatibility, .needsRosetta)
        XCTAssertFalse(compatibility.isBlocking, "Rosetta 是提醒而不是拦阻")
    }

    func testMissingArchitectureListIsNoConstraint() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        XCTAssertEqual(
            makeRelease(architectures: []).hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs
        )
        XCTAssertEqual(
            makeRelease(architectures: ["arm64"]).hostCompatibility(operatingSystem: host, isAppleSilicon: true),
            .runs
        )
    }

    func testHidingIncompatibleReleasesUsesTheBlockingSet() {
        let blocked = makeRelease(version: "27.0", build: "27A1", minimumMacOS: "26.6")
        let rosetta = makeRelease(version: "26.0", build: "26A1", architectures: ["x86_64"])
        let fine = makeRelease(version: "26.3", build: "17C529")

        var query = XcodeReleaseQuery()
        query.hidesIncompatible = true
        let kept = query.apply(
            to: [blocked, rosetta, fine],
            installedBuilds: [],
            incompatibleBuilds: [blocked.build]
        )

        XCTAssertFalse(kept.contains { $0.build == blocked.build }, "本机完全跑不了的应被藏掉")
        XCTAssertTrue(kept.contains { $0.build == rosetta.build }, "需 Rosetta 的仍保留：它是提醒而非拦阻")
        XCTAssertTrue(kept.contains { $0.build == fine.build }, "兼容的本就应在列表里")
    }

    private func makeRelease(
        version: String = "26.6",
        build: String = "17F113",
        channel: XcodeReleaseInfo.Channel = .release,
        minimumMacOS: String? = nil,
        architectures: [String] = ["arm64"]
    ) -> XcodeReleaseInfo {
        XcodeReleaseInfo(
            name: "Xcode", version: version, build: build, channel: channel,
            releaseDate: nil, minimumMacOS: minimumMacOS, sdks: [], swift: nil, clang: nil,
            notesURL: nil, downloadURL: nil, downloadArchitectures: architectures
        )
    }

    // MARK: - 下载页链接

    func testDownloadsPageQueryMatchesApplesTitles() {
        XCTAssertEqual(makeRelease(version: "27.1", channel: .beta(1)).downloadsPageQuery, "Xcode 27.1 beta 1")
        XCTAssertEqual(makeRelease(version: "26.3", channel: .release).downloadsPageQuery, "Xcode 26.3")
        XCTAssertEqual(makeRelease(version: "26.0", channel: .releaseCandidate(2)).downloadsPageQuery, "Xcode 26.0 RC 2")
        XCTAssertEqual(makeRelease(version: "26.0", channel: .goldenMaster(seed: 1)).downloadsPageQuery, "Xcode 26.0 GM seed 1")
        XCTAssertEqual(makeRelease(version: "26.0", channel: .goldenMaster(seed: nil)).downloadsPageQuery, "Xcode 26.0 GM")
    }

    func testDownloadsPageQueryDoesNotUseTheDisplayLabel() {
        let release = makeRelease(version: "26.3", channel: .release)
        XCTAssertFalse(
            release.downloadsPageQuery.contains(release.channel.label),
            "查询词要用 Apple 的英文标题，不能用界面标签（正式版）——那样在 Apple 站上搜不到"
        )
    }

    func testDownloadsPageURLCarriesTheQuery() throws {
        let url = try XCTUnwrap(makeRelease(version: "27.1", channel: .beta(1)).downloadsPageURL)

        XCTAssertEqual(url.host, "developer.apple.com")
        // `URL.path` 会去掉结尾斜杠，真正被打开的是 absoluteString，所以两处都盯着。
        XCTAssertEqual(url.path, "/download/all")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://developer.apple.com/download/all/"))
        XCTAssertEqual(url.query, "q=Xcode%2027.1%20beta%201")
    }

    func testDownloadsPageIsNotTheRawAssetURL() {
        // 直链在 developer.apple.com 的下载主机上，需要开发者会话 cookie；未登录时
        // Apple 不报错而是 302 到 /unauthorized/，所以人点的那条要换成下载页。
        let release = makeRelease(version: "27.1", channel: .beta(1))
        let page = release.downloadsPageURL?.absoluteString ?? ""
        XCTAssertFalse(page.contains("download.developer.apple.com"))
        XCTAssertTrue(page.hasPrefix("https://developer.apple.com/download/all/"))
    }
}
