import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

@MainActor
final class XcodeUpdateNotificationTests: XCTestCase {
    private static let releaseIndex = Data("""
    [
      {
        "name": "Xcode",
        "version": { "number": "16.1", "build": "16B40", "release": { "release": true } }
      }
    ]
    """.utf8)

    func testEnabledNotificationsReportOnceAndPersistDeliveredBuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeUpdateNotifications-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseIndex = Self.releaseIndex
        let catalogStore = XcodeReleaseCatalogStore(
            fetch: { releaseIndex },
            cacheURL: root.appendingPathComponent("releases.json"),
            maxAge: 0
        )
        let configurationStore = AppConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        let model = XcodeViewModel(
            store: configurationStore,
            releaseCatalogStore: catalogStore,
            configuresSystemServices: false
        )
        let installation = XcodeInstallation(
            appURL: root.appendingPathComponent("Xcode 16.0.app"),
            version: "16.0",
            build: "16A242"
        )
        model.installs.replaceInstallationsForUITesting(
            [installation],
            activeDeveloperPath: installation.developerURL.path
        )

        let candidateReady = expectation(description: "newer Xcode release is reported")
        var reported: [XcodeUpdateNotificationCandidate] = []
        model.onXcodeUpdateNotificationsReady = { candidates in
            reported = candidates
            candidateReady.fulfill()
        }

        model.toggleXcodeUpdateNotifications(true)
        model.releases.loadReleaseCatalog(force: true)
        await fulfillment(of: [candidateReady], timeout: 2)

        XCTAssertEqual(reported.map(\.release.version), ["16.1"])
        XCTAssertEqual(reported.map(\.notificationKey), ["\(installation.id)|16B40"])

        model.markXcodeUpdateNotificationsDelivered(reported)
        XCTAssertEqual(configurationStore.load().notifiedXcodeUpdateKeys, Set([reported[0].notificationKey]))

        let duplicate = expectation(description: "delivered build is not reported again")
        duplicate.isInverted = true
        model.onXcodeUpdateNotificationsReady = { _ in duplicate.fulfill() }
        model.releases.reportXcodeUpdateCandidates()
        await fulfillment(of: [duplicate], timeout: 0.2)
    }
}
