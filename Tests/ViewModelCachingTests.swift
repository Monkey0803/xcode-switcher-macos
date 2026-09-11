import Foundation
import Testing
@testable import XcodeSwitcher

/// Covers the caching and persistence behaviour added for view-render cost.
/// The view model takes an injected store and skips system services so it can be
/// constructed in a test process.
@MainActor
@Suite("XcodeViewModel 缓存与持久化")
struct ViewModelCachingTests {
    private struct Fixture {
        let root: URL
        let store: AppConfigurationStore
        let model: XcodeViewModel
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        let model = XcodeViewModel(store: store, configuresSystemServices: false)
        return Fixture(root: root, store: store, model: model)
    }

    private func makeProject(in root: URL, version: String) throws -> ProjectProfile {
        let directory = root.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\(version)\n".write(to: directory.appendingPathComponent(".xcode-version"), atomically: true, encoding: .utf8)
        let projectURL = directory.appendingPathComponent("Demo.xcodeproj")
        try "// project placeholder".write(to: projectURL, atomically: true, encoding: .utf8)
        return ProjectProfile(name: "Demo", path: projectURL.path)
    }

    @Test("渲染路径不再每次读盘：结果被缓存，失效后才重新解析")
    func cachesProjectResolutionUntilInvalidated() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = try makeProject(in: fixture.root, version: "16.4")
        fixture.model.configuration.projects = [profile]

        // No Xcode is installed, so the first read reports the missing requirement.
        let first = try #require(fixture.model.projectIssue(for: profile))
        #expect(first.contains("16.4"))

        // A malformed local configuration changes what a fresh read would answer.
        try "{not-json".write(
            to: fixture.root.appendingPathComponent("Demo/.xcode-switcher.json"),
            atomically: true,
            encoding: .utf8
        )

        // The cached snapshot keeps answering, which is what removes the
        // per-render filesystem walk from the view body.
        #expect(fixture.model.projectIssue(for: profile) == first)

        fixture.model.invalidateProjectSnapshots()
        let refreshed = try #require(fixture.model.projectIssue(for: profile))
        // The message is localized, so assert the language-independent part: it names
        // the offending configuration file.
        #expect(refreshed.contains(".xcode-switcher.json"))
        #expect(refreshed != first)
    }

    @Test("项目失效判定同样走缓存")
    func cachesProjectPresence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = try makeProject(in: fixture.root, version: "16.4")
        fixture.model.configuration.projects = [profile]

        #expect(fixture.model.invalidProjects.isEmpty)

        try FileManager.default.removeItem(at: profile.url)
        // Still cached, so the row does not flip while the user is looking at it.
        #expect(fixture.model.invalidProjects.isEmpty)

        fixture.model.invalidateProjectSnapshots()
        #expect(fixture.model.invalidProjects.map(\.id) == [profile.id])
    }

    @Test("防抖编辑在 flush 时立即落盘")
    func flushAppliesDebouncedProjectUpdate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = try makeProject(in: fixture.root, version: "16.4")
        fixture.model.configuration.projects = [profile]
        fixture.model.persist()

        fixture.model.scheduleProjectUpdate(profile, name: "Renamed", xcodeID: nil)
        // Inside the debounce window nothing has been written yet.
        #expect(fixture.store.load().projects.first?.name == "Demo")

        fixture.model.flushPendingProjectUpdate()
        #expect(fixture.store.load().projects.first?.name == "Renamed")
        // A second flush is a no-op rather than another write.
        fixture.model.flushPendingProjectUpdate()
        #expect(fixture.store.load().projects.first?.name == "Renamed")
    }

    @Test("防抖窗口结束后自动落盘")
    func debounceAppliesAfterDelay() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = try makeProject(in: fixture.root, version: "16.4")
        fixture.model.configuration.projects = [profile]
        fixture.model.persist()

        fixture.model.scheduleProjectUpdate(profile, name: "Renamed", xcodeID: nil)
        #expect(fixture.store.load().projects.first?.name == "Demo")

        try await Task.sleep(for: .milliseconds(900))
        #expect(fixture.store.load().projects.first?.name == "Renamed")
    }

    @Test("保存失败不再静默")
    func reportsSaveFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A regular file where a directory is required makes the write fail.
        let blocker = root.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let store = AppConfigurationStore(fileURL: blocker.appendingPathComponent("configuration.json"))
        let model = XcodeViewModel(store: store, configuresSystemServices: false)

        #expect(model.configurationSaveError == nil)
        model.persist()
        let message = try #require(model.configurationSaveError)
        #expect(!message.isEmpty)
        #expect(model.isError)
    }

    @Test("历史备份有上限且不重复归档未变化的内容")
    func boundsHistoricalBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeSwitcherVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))

        for index in 0..<3 {
            var configuration = AppConfiguration()
            configuration.menuBarOnly = index.isMultiple(of: 2)
            configuration.activationHistory = ["xcode-\(index)"]
            try store.save(configuration)
        }
        let afterDistinctSaves = try FileManager.default.contentsOfDirectory(
            at: store.backupDirectoryURL,
            includingPropertiesForKeys: nil
        ).count
        #expect(afterDistinctSaves == 2)

        var stable = AppConfiguration()
        stable.activationHistory = ["same"]
        // First save archives the previous content, second archives `stable`;
        // from then on the archive must not grow no matter how often it is saved.
        try store.save(stable)
        try store.save(stable)
        let settled = try FileManager.default.contentsOfDirectory(
            at: store.backupDirectoryURL,
            includingPropertiesForKeys: nil
        ).count
        for _ in 0..<5 {
            try store.save(stable)
        }
        let afterRepeatedSaves = try FileManager.default.contentsOfDirectory(
            at: store.backupDirectoryURL,
            includingPropertiesForKeys: nil
        ).count
        #expect(afterRepeatedSaves == settled)
    }
}
