@preconcurrency import XCTest
import AppKit

@MainActor
final class XcodeSwitcherUITests: XCTestCase {
    // XCTest's lifecycle callbacks are nonisolated while `XCUIApplication` is
    // main-actor isolated. Keep the reference explicitly unsafe only at that
    // framework boundary: every test method stays on the main actor, and all
    // application interaction is confined to it.
    private nonisolated(unsafe) var app: XCUIApplication!
    private nonisolated static var targetsInstalledApp: Bool {
        FileManager.default.fileExists(atPath: "/tmp/xcode-switcher-ui-test-installed-app")
    }

    private static func launchApp(targetsInstalledApp: Bool) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: targetsInstalledApp
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
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let installedApp = Self.targetsInstalledApp
        app = MainActor.assumeIsolated {
            Self.launchApp(targetsInstalledApp: installedApp)
        }
    }

    override func tearDownWithError() throws {
        guard let launchedApp = app else { return }
        MainActor.assumeIsolated {
            launchedApp.terminate()
        }
    }

    func testLanguageSelectorShowsRestartAction() throws {
        // This is the same Command-, route that the user takes from the app's
        // Settings command, rather than constructing the settings view in-process.
        // It is valid whether the user launches the app as a regular window or
        // later chooses the menu-bar-only mode.
        app.typeKey(",", modifierFlags: .command)

        let languagePicker = app.popUpButtons["app-language-picker"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 10))
        XCTAssertTrue(
            raiseAndWait(for: languagePicker, in: app.windows["XcodeSwitcherSettingsWindow"]),
            "语言选择器应当可点：设置窗口必须位于主窗口之上"
        )

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

        let openProject = app.buttons["open-project-button-7C7B93FD-DC7A-47BB-9C91-F0E591DDD2AA"]
        XCTAssertTrue(openProject.waitForExistence(timeout: 5))
        XCTAssertTrue(
            raiseAndWait(for: openProject, in: app.windows["XcodeSwitcherSettingsWindow"]),
            "应用并打开按钮应当可点：设置窗口必须位于主窗口之上"
        )
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

    func testProjectCompatibilityOverviewShowsScanAndRecommendedOpenActions() throws {
        app.typeKey(",", modifierFlags: .command)

        let projectsTab = app.radioButtons["项目"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 10))
        projectsTab.click()

        XCTAssertTrue(app.staticTexts["项目兼容性"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["refresh-project-compatibility-button"].exists)
        let scan = app.buttons["scan-project-search-paths-button"]
        XCTAssertTrue(scan.exists)
        scan.click()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "open-project-button-")
        ).firstMatch.waitForExistence(timeout: 5))
    }

    func testInstalledAppPersistsDiskWarningThresholdAfterRestart() throws {
        guard Self.targetsInstalledApp else {
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
        guard Self.targetsInstalledApp else {
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
        guard Self.targetsInstalledApp else {
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

        // 15s rather than 5: this is the one assertion in the suite that waits on a
        // view rebuilt from an asynchronous report, and the runner is slower than a
        // developer machine. The diagnostics exist because the first CI run of this
        // suite failed here and the log could not say whether the report was missing,
        // late, or rendered in another language.
        if !app.staticTexts["测试诊断完成"].waitForExistence(timeout: 15) {
            print("[ui-test] categories=\(app.radioButtons.allElementsBoundByIndex.map(\.label))")
            print("[ui-test] windows=\(app.windows.allElementsBoundByIndex.map { "\($0.identifier):\($0.frame)" })")
            print("[ui-test] texts=\(app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
            XCTFail("体检报告没有渲染出检查项")
        }
    }

    // MARK: - 主窗口主路径
    //
    // These exercise the paths a user takes every day and that nothing else in the
    // suite touched: what the list shows, narrowing it, folding it, refreshing it,
    // and moving between the detail categories. The fixture in `AppDelegate` is what
    // makes them deterministic — a host Xcode cannot leak in, and the release index
    // is served from memory rather than the network.

    /// A row puts its text in `value` while a button puts it in `label`, and both the
    /// count labels and the tooltips are read the same way here.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// Waits for a predicate over a *query* to hold.
    ///
    /// `XCUIElementQuery.firstMatch` resolves once and then keeps returning what it
    /// first found, so waiting on one for an element that has not appeared yet can
    /// never succeed — measured 2026-09-23 on the release list, where after a search
    /// the one row the query narrowed *to* was the one reported missing. A predicate
    /// expectation re-evaluates the live tree on every poll instead, and asserts
    /// disappearance with the same tool.
    @discardableResult
    private func waitFor(
        _ predicate: NSPredicate,
        evaluatedWith object: Any,
        timeout: TimeInterval = 5
    ) -> Bool {
        XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: object)],
            timeout: timeout
        ) == .completed
    }

    private func waitForText(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        waitFor(NSPredicate(format: "value == %@", expected), evaluatedWith: element, timeout: timeout)
    }

    /// A row's identifier is built from the installation's path, which differs on every
    /// run, so only its last component is asserted. The `BEGINSWITH` half matters: a
    /// detail-pane button is identified `open-developer-dir-terminal-<path>` and ends
    /// with the same component.
    @discardableResult
    private func installationRow(_ appName: String, exists: Bool = true, timeout: TimeInterval = 5) -> Bool {
        waitFor(
            NSPredicate(format: exists ? "count > 0" : "count == 0"),
            evaluatedWith: app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "installation-row-",
                appName
            )),
            timeout: timeout
        )
    }

    @discardableResult
    private func releaseRow(_ build: String, in window: XCUIElement, exists: Bool = true, timeout: TimeInterval = 5) -> Bool {
        waitFor(
            NSPredicate(format: exists ? "count > 0" : "count == 0"),
            evaluatedWith: window.descendants(matching: .any)
                .matching(identifier: "all-versions-row-\(build)"),
            timeout: timeout
        )
    }

    /// Opens the window the way the main window does, then waits for the index — the
    /// count label only appears once the catalogue has loaded.
    private func openAllVersionsWindow() -> XCUIElement {
        XCTAssertTrue(app.buttons["all-versions-button"].waitForExistence(timeout: 10))
        app.buttons["all-versions-button"].click()
        let window = app.windows["XcodeSwitcherAllVersionsWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForText(
            window.staticTexts["all-versions-count-label"],
            "共 4 / 4 个版本",
            timeout: 15
        ))
        return window
    }

    func testMainWindowListsFixtureInstallationsAndMarksTheActiveOne() throws {
        let count = app.staticTexts["installation-count-label"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: count), "3 个版本")

        XCTAssertTrue(installationRow("Xcode 15.4.app"))
        XCTAssertTrue(installationRow("Xcode 16.0.app"))
        XCTAssertTrue(installationRow("Xcode 17.5.app"))

        // Exactly one row carries the active marker, and the fixture makes that 15.4.
        XCTAssertTrue(waitFor(
            NSPredicate(format: "count == 1"),
            evaluatedWith: app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "installation-row-",
                "当前激活"
            ))
        ))

        // Both window actions are unavailable in this state: the selection is already
        // the system default, and no switch has been recorded to roll back to.
        XCTAssertFalse(app.buttons["activate-selected-xcode-button"].isEnabled)
        XCTAssertFalse(app.buttons["rollback-xcode-button"].isEnabled)
    }

    func testSearchFieldNarrowsTheInstallationList() throws {
        let search = app.textFields["xcode-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("16.0")

        XCTAssertTrue(installationRow("Xcode 16.0.app"))
        XCTAssertTrue(installationRow("Xcode 15.4.app", exists: false))
        XCTAssertTrue(installationRow("Xcode 17.5.app", exists: false))
        // The count is how many Xcodes this Mac has, not how many the query kept.
        XCTAssertEqual(text(of: app.staticTexts["installation-count-label"]), "3 个版本")
    }

    func testListPaneToggleHidesAndRestoresTheInstallationList() throws {
        let toggle = app.buttons["list-pane-toggle-button"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["xcode-search-field"].exists)

        toggle.click()
        XCTAssertTrue(installationRow("Xcode 15.4.app", exists: false))
        // The detail pane takes the width the list gave up.
        XCTAssertTrue(app.staticTexts["系统级切换"].waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(installationRow("Xcode 15.4.app"))
        XCTAssertTrue(app.textFields["xcode-search-field"].waitForExistence(timeout: 5))
    }

    func testRefreshButtonKeepsTheFixtureList() throws {
        let refresh = app.buttons["refresh-xcodes-button"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.isEnabled)

        refresh.click()

        // The UI fixture ignores refresh triggers, so the host's real Xcode
        // installations must not replace the versions under test.
        XCTAssertTrue(installationRow("Xcode 15.4.app"))
        XCTAssertEqual(text(of: app.staticTexts["installation-count-label"]), "3 个版本")
    }

    func testDetailCategoryPickerSwitchesSections() throws {
        XCTAssertTrue(app.staticTexts["系统级切换"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["不改系统设置（不需要管理员授权）"].exists)

        app.radioButtons["版本与兼容"].click()
        XCTAssertTrue(app.staticTexts["版本详细信息"].waitForExistence(timeout: 5))

        app.radioButtons["环境"].click()
        XCTAssertTrue(app.staticTexts["环境诊断"].waitForExistence(timeout: 5))

        app.radioButtons["概览"].click()
        XCTAssertTrue(app.staticTexts["系统级切换"].waitForExistence(timeout: 5))
    }

    // MARK: - 「所有 Xcode 版本」窗口

    func testAllVersionsWindowListsTheIndexAndSearchesIt() throws {
        let window = openAllVersionsWindow()
        XCTAssertTrue(releaseRow("15F31d", in: window))
        XCTAssertTrue(releaseRow("27Z999", in: window))

        let search = window.textFields["all-versions-search-field"]
        search.click()
        search.typeText("16")

        // Only 16.0/16A242d matches, and the count keeps the whole index as its denominator.
        XCTAssertTrue(releaseRow("16A242d", in: window))
        XCTAssertTrue(releaseRow("15F31d", in: window, exists: false))
        XCTAssertTrue(releaseRow("17A100", in: window, exists: false))
        XCTAssertTrue(waitForText(window.staticTexts["all-versions-count-label"], "共 1 / 4 个版本"))

        // A query that matches nothing says so rather than leaving an empty list.
        search.typeKey("a", modifierFlags: .command)
        search.typeText("9.9.9")
        XCTAssertTrue(window.staticTexts["all-versions-empty-label"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForText(window.staticTexts["all-versions-count-label"], "共 0 / 4 个版本"))
    }

    func testAllVersionsFiltersByChannelAndInstallationState() throws {
        let window = openAllVersionsWindow()
        XCTAssertTrue(releaseRow("17A100", in: window))

        window.popUpButtons["all-versions-channel-picker"].click()
        app.menuItems["仅正式版"].click()
        XCTAssertTrue(releaseRow("17A100", in: window, exists: false))
        XCTAssertTrue(releaseRow("15F31d", in: window))

        window.popUpButtons["all-versions-installation-picker"].click()
        app.menuItems["已安装"].click()
        XCTAssertTrue(releaseRow("15F31d", in: window))
        XCTAssertTrue(releaseRow("16A242d", in: window))
        XCTAssertTrue(releaseRow("27Z999", in: window, exists: false))
    }

    func testAllVersionsCanHideReleasesThisMacCannotRun() throws {
        let window = openAllVersionsWindow()
        XCTAssertTrue(releaseRow("27Z999", in: window))

        // The fixture entry requires macOS 99.0, so this is the same answer on any host.
        window.checkBoxes["all-versions-hides-incompatible-toggle"].click()

        XCTAssertTrue(releaseRow("27Z999", in: window, exists: false))
        XCTAssertTrue(releaseRow("15F31d", in: window))
    }



    /// Brings an auxiliary window (Settings, All versions) to the front and waits for a
    /// control inside it to become hittable.
    ///
    /// They are separate `NSWindow`s, and a window that ends up underneath the main one
    /// makes every control in the overlap area unreachable: XCUITest reports
    /// 「Not hittable」 for an element that plainly exists. On the CI runner both windows
    /// are centred on the same screen, which is exactly the overlap case — this is how
    /// three of these tests failed on CI while passing on a developer machine.
    /// Clicking the title bar raises a window without activating one of its controls.
    @discardableResult
    private func raiseAndWait(
        for element: XCUIElement,
        in window: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard window.exists else { return false }
        app.activate()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).click()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        // The next CI run has to distinguish "covered" from "off-screen" from "gone";
        // a bare assertion failure says none of that.
        print("[ui-test] element=\(element.frame) hittable=\(element.exists ? String(element.isHittable) : "missing") window=\(window.frame) screen=\(NSScreen.main?.frame ?? .zero)")
        return false
    }

    // MARK: - 系统边界的可见失败
    //
    // 三条路径都跨出了应用：管理员授权、全局快捷键的系统级注册、以及 simctl。
    // 前两条在测试里无法真正完成，所以夹具把它们换成会失败的桩——要验证的是
    // 失败有没有落到用户能看到的那一行，而不是失败本身可不可能。

    /// 授权被取消（夹具桩抛错）必须显示在状态栏，而不是静默地什么都不发生。
    func testAuthorizationFailureIsVisibleInTheStatusLine() throws {
        selectInstallation("Xcode 16.0.app")

        let activate = app.buttons["activate-selected-xcode-button"]
        XCTAssertTrue(activate.waitForExistence(timeout: 5))
        XCTAssertTrue(activate.isEnabled, "选中非当前版本后，激活按钮必须可用")
        activate.click()

        XCTAssertTrue(
            app.staticTexts["切换失败：UI test authorization cancelled."].waitForExistence(timeout: 5)
        )
    }

    /// ⇧⌘V 是应用自己的菜单命令，与窗口上的按钮是两条独立入口。
    func testApplicationShortcutOpensAllVersions() throws {
        app.activate()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["all-versions-search-field"].waitForExistence(timeout: 10))
    }

    /// simctl 失败同样要看得见；行内的设备来自夹具，所以断言与开发机上装了
    /// 哪些 Simulator 无关。
    func testSimulatorFailureIsVisibleAfterRealDeviceAction() throws {
        selectInstallation("Xcode 16.0.app")
        let simulatorCategory = app.radioButtons["模拟器"]
        XCTAssertTrue(simulatorCategory.waitForExistence(timeout: 5))
        simulatorCategory.click()

        let boot = app.buttons["simulator-boot-button-ui-test-device"]
        XCTAssertTrue(boot.waitForExistence(timeout: 5))
        boot.click()

        XCTAssertTrue(
            app.staticTexts["Simulator 操作失败：UI test simctl failure"].waitForExistence(timeout: 5)
        )
    }

    // MARK: - 移除已安装的 Xcode

    /// Selects an installation by clicking its row, so the detail pane switches to it.
    private func selectInstallation(_ appName: String) {
        let row = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "installation-row-",
            appName
        ))
        XCTAssertTrue(waitFor(NSPredicate(format: "count > 0"), evaluatedWith: row))
        row.element(boundBy: 0).click()
    }

    private var removalButton: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "remove-xcode-button-"
        )).firstMatch
    }

    /// The active installation is the one case the fixture can drive without risking
    /// a real bundle: 15.4 is what `xcode-select` points at, so the policy must refuse
    /// it and the panel must say why rather than failing after the click.
    func testRemovalPanelRefusesTheActiveXcodeAndSaysWhy() throws {
        app.radioButtons["磁盘清理"].click()

        let button = removalButton
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertFalse(button.isEnabled)

        // The measurement runs on appearance — the number is the point of the panel.
        let size = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "xcode-size-label-"
        ))
        XCTAssertTrue(waitFor(NSPredicate(format: "count > 0"), evaluatedWith: size))

        let refusal = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@",
            "系统默认"
        ))
        XCTAssertTrue(waitFor(NSPredicate(format: "count > 0"), evaluatedWith: refusal))
    }

    /// 17.5 is neither the system default nor pinned by a project, so the action is
    /// offered. The test opens the confirmation and cancels it: removing a fixture
    /// bundle would only prove that the trash works.
    func testRemovalPanelOffersAnUnboundXcodeAndCancelsTheConfirmation() throws {
        selectInstallation("Xcode 17.5.app")
        app.radioButtons["磁盘清理"].click()

        let button = removalButton
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
        button.click()

        let confirmation = app.sheets.buttons["取消"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["确认移除这个 Xcode？"].exists)
        confirmation.click()

        // Nothing was removed and the panel is still usable.
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }

    /// A bundle a project pins is refused too, and `--force` is deliberately not part
    /// of the app's surface: rebinding is one click away in the Projects pane.
    func testRemovalPanelRefusesAnXcodeThatAProjectPins() throws {
        selectInstallation("Xcode 16.0.app")
        app.radioButtons["磁盘清理"].click()

        let button = removalButton
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertFalse(button.isEnabled)

        let refusal = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@",
            "绑定到它"
        ))
        XCTAssertTrue(waitFor(NSPredicate(format: "count > 0"), evaluatedWith: refusal))
    }

    func testAllVersionsDetailsPaneCanBeFolded() throws {
        let window = openAllVersionsWindow()
        XCTAssertTrue(window.staticTexts["选择一个版本查看详情。"].waitForExistence(timeout: 5))

        window.buttons["release-details-toggle-button"].click()
        XCTAssertTrue(waitFor(
            NSPredicate(format: "count == 0"),
            evaluatedWith: window.staticTexts.matching(
                NSPredicate(format: "value == %@", "选择一个版本查看详情。")
            )
        ))

        window.buttons["release-details-toggle-button"].click()
        XCTAssertTrue(window.staticTexts["选择一个版本查看详情。"].waitForExistence(timeout: 5))
    }

}
