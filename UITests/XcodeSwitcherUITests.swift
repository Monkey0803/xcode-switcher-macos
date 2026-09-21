import XCTest

final class XcodeSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh-Hans",
        ]
        app.launchEnvironment["XCODE_SWITCHER_UI_TESTING"] = "1"
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
}
