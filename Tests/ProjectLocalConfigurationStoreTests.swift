import XCTest
@testable import XcodeSwitcher

final class ProjectLocalConfigurationStoreTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectLocalConfigurationStore-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var configurationURL: URL { root.appendingPathComponent(".xcode-switcher.json") }

    func testSaveBindsXcodeAndKeepsWorkspace() throws {
        try ProjectLocalConfigurationStore.save(xcode: "26.3", for: project)
        try ProjectLocalConfigurationStore.save(xcode: "27.0", for: project)

        let configuration = ProjectLocalConfigurationStore.load(for: project)
        XCTAssertEqual(configuration?.xcode, "27.0")
    }

    func testSavePreservesAnExistingWorkspaceKey() throws {
        let existing = ProjectLocalConfiguration(xcode: nil, workspace: "Demo.xcworkspace")
        let data = try JSONEncoder().encode(existing)
        try data.write(to: configurationURL)

        try ProjectLocalConfigurationStore.save(xcode: "26.3", for: project)

        let configuration = ProjectLocalConfigurationStore.load(for: project)
        XCTAssertEqual(configuration?.xcode, "26.3")
        XCTAssertEqual(configuration?.workspace, "Demo.xcworkspace")
    }

    func testClearRemovesTheBindingButKeepsTheWorkspaceFile() throws {
        try ProjectLocalConfigurationStore.save(xcode: "26.3", for: project)
        try ProjectLocalConfiguration(xcode: "26.3", workspace: "Demo.xcworkspace")
            .encoded().write(to: configurationURL)

        XCTAssertTrue(try ProjectLocalConfigurationStore.clear(for: project))

        let configuration = ProjectLocalConfigurationStore.load(for: project)
        XCTAssertNil(configuration?.xcode)
        XCTAssertEqual(configuration?.workspace, "Demo.xcworkspace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurationURL.path))
    }

    func testClearDeletesTheFileWhenNothingIsLeft() throws {
        try ProjectLocalConfigurationStore.save(xcode: "26.3", for: project)

        XCTAssertTrue(try ProjectLocalConfigurationStore.clear(for: project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
    }

    func testClearReportsWhenThereIsNoBinding() throws {
        XCTAssertFalse(try ProjectLocalConfigurationStore.clear(for: project))
    }
}

private extension ProjectLocalConfiguration {
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
