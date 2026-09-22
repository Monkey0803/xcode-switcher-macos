import XCTest

@MainActor
final class XcodeSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!
    private var targetsInstalledApp: Bool {
        FileManager.default.fileExists(atPath: "/tmp/xcode-switcher-ui-test-installed-app")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: targetsInstalledApp
            ? "com.yostar.xcodeswitcher"
            : "com.yostar.xcodeswitcher.debug")
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh-Hans",
        ]
        if !targetsInstalledApp {
            app.launchEnvironment["XCODE_SWITCHER_UI_TESTING"] = "1"
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testLanguageSelectorShowsRestartAction() throws {
        // This is the same Command-, route that the user takes from the app's
        // Settings command, rather than constructing the settings view in-process.
        // It is valid whether the user launches the app as a regular window or
        // later chooses the menu-bar-only mode.
        app.typeKey(",", modifierFlags: .command)

        let languagePicker = app.popUpButtons["app-language-picker"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 10))

        languagePicker.click()
        let english = app.menuItems["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()

        XCTAssertTrue(app.buttons["restart-for-language-button"].waitForExistence(timeout: 5))
    }

    func testDiskSpaceWarningSettingsAreAvailable() throws {
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.switches["xcode-update-notifications-toggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["disk-space-warning-toggle"].waitForExistence(timeout: 10))
        let thresholdInput = app.textFields["disk-space-warning-threshold-input"]
        XCTAssertTrue(thresholdInput.exists)
        XCTAssertTrue(app.steppers["disk-space-warning-threshold"].exists)

        thresholdInput.click()
        app.typeKey("a", modifierFlags: .command)
        thresholdInput.typeText("75")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(thresholdInput.value as? String, "75")
    }

    func testCleanupRequiresConfirmationBeforeRemovingFixtureDirectory() throws {
        let cleanupCategory = app.radioButtons["磁盘清理"]
        XCTAssertTrue(cleanupCategory.waitForExistence(timeout: 10))
        cleanupCategory.click()

        let cleanupButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cleanup-entry-button-")
        ).firstMatch
        XCTAssertTrue(cleanupButton.waitForExistence(timeout: 5))
        cleanupButton.click()

        let destructiveAction = app.buttons["清理 测试 DerivedData"]
        XCTAssertTrue(destructiveAction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["确认清理目录？"].exists)
        app.sheets.buttons["取消"].click()
        XCTAssertFalse(destructiveAction.exists)
    }

    func testProjectOpenShowsVersionSwitchConfirmation() throws {
        app.typeKey(",", modifierFlags: .command)

        let projectsTab = app.radioButtons["项目"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 10))
        projectsTab.click()

        let openProject = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "open-project-button-")
        ).firstMatch
        XCTAssertTrue(openProject.waitForExistence(timeout: 5))
        openProject.click()

        XCTAssertTrue(app.staticTexts["项目推荐使用另一版本的 Xcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["切换系统默认并打开"].exists)
        app.sheets.buttons["取消"].click()
        XCTAssertFalse(app.buttons["切换系统默认并打开"].exists)
    }

    func testWorkspaceConflictOffersDirectXcodeChoices() throws {
        app.typeKey(",", modifierFlags: .command)

        let projectsTab = app.radioButtons["项目"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 10))
        projectsTab.click()

        let choice = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-xcode-choice-")
        ).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        XCTAssertTrue(choice.exists)
    }

    func testInstalledAppPersistsDiskWarningThresholdAfterRestart() throws {
        guard targetsInstalledApp else {
            throw XCTSkip("仅在 XCODE_SWITCHER_UI_TEST_INSTALLED_APP=1 时验收已安装应用。")
        }
        app.typeKey(",", modifierFlags: .command)

        let threshold = app.textFields["disk-space-warning-threshold-input"]
        XCTAssertTrue(threshold.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["xcode-update-notifications-toggle"].waitForExistence(timeout: 5))
        let originalValue = try XCTUnwrap(threshold.value as? String)
        let testValue = originalValue == "101" ? "102" : "101"
        defer {
            threshold.click()
            app.typeKey("a", modifierFlags: .command)
            threshold.typeText(originalValue)
            app.typeKey(.return, modifierFlags: [])
        }

        threshold.click()
        app.typeKey("a", modifierFlags: .command)
        threshold.typeText(testValue)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(threshold.value as? String, testValue)

        app.terminate()
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(threshold.waitForExistence(timeout: 10))
        XCTAssertEqual(threshold.value as? String, testValue)
    }

    func testInstalledAppEnablesXcodeUpdateNotifications() throws {
        guard targetsInstalledApp else {
            throw XCTSkip("仅在正式应用验收标记存在时启用更新通知。")
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let notifications = app.switches["xcode-update-notifications-toggle"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 10))
        guard notifications.value as? String != "1" else { return }

        let monitor = addUIInterruptionMonitor(withDescription: "允许 Xcode Switcher 通知") { alert in
            for title in ["允许", "Allow"] where alert.buttons[title].exists {
                alert.buttons[title].click()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }

        notifications.click()
        app.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(5))
    }

    func testInstalledAppDisplaysWorkspaceConflict() throws {
        guard targetsInstalledApp else {
            throw XCTSkip("仅在 XCODE_SWITCHER_UI_TEST_INSTALLED_APP=1 时验收已安装应用。")
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let projectsTab = app.radioButtons["项目"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 10))
        projectsTab.click()

        let choices = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-xcode-choice-")
        )
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(choices.count, 2)
    }

    func testEnvironmentDoctorRendersCompletedReport() throws {
        let environmentCategory = app.radioButtons["环境"]
        XCTAssertTrue(environmentCategory.waitForExistence(timeout: 10))
        environmentCategory.click()

        let doctor = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "environment-doctor-button-")
        ).firstMatch
        XCTAssertTrue(doctor.waitForExistence(timeout: 5))
        doctor.click()
        XCTAssertTrue(app.staticTexts["测试诊断完成"].waitForExistence(timeout: 5))
    }

}
