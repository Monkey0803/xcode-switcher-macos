import Foundation
import XCTest
@testable import XcodeSwitcher

final class ConfigurationStoreTests: XCTestCase {
    func testMigratesLegacyConfigurationAndCreatesBackupBeforeOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("configuration.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"favoriteIDs\":[\"legacy\"]}".utf8).write(to: fileURL)

        let store = AppConfigurationStore(fileURL: fileURL)
        var configuration = store.load()
        XCTAssertEqual(configuration.schemaVersion, AppConfiguration.currentSchemaVersion)
        XCTAssertEqual(configuration.favoriteIDs, ["legacy"])

        configuration.menuBarOnly = true
        store.save(configuration)
        XCTAssertTrue(store.hasBackup)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: store.backupDirectoryURL, includingPropertiesForKeys: nil).count, 1)
        let backup = try store.import(from: store.backupURL)
        XCTAssertEqual(backup.favoriteIDs, ["legacy"])
        XCTAssertFalse(backup.menuBarOnly)
    }

    func testRestoresBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("configuration.json")
        let store = AppConfigurationStore(fileURL: fileURL)
        var first = AppConfiguration()
        first.menuBarOnly = true
        store.save(first)
        var second = first
        second.menuBarOnly = false
        store.save(second)

        let restored = try store.restoreBackup()
        XCTAssertTrue(restored.menuBarOnly)
        XCTAssertTrue(store.load().menuBarOnly)
    }

    func testCreatesDistinctHistoricalBackupsForRapidSaves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        var configuration = AppConfiguration()
        store.save(configuration)
        configuration.menuBarOnly = true
        store.save(configuration)
        configuration.menuBarOnly = false
        store.save(configuration)

        let backups = try FileManager.default.contentsOfDirectory(at: store.backupDirectoryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(Set(backups.map(\.lastPathComponent)).count, 2)
    }

    func testPreservesUnreadableConfigurationForRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("configuration.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)

        let store = AppConfigurationStore(fileURL: fileURL)
        XCTAssertEqual(store.load().projects, [])
        XCTAssertTrue(store.hasBackup)
        XCTAssertEqual(try String(contentsOf: store.backupURL, encoding: .utf8), "not-json")
    }
}
