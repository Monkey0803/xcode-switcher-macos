import XCTest
@testable import XcodeSwitcher

final class SigningServiceTests: XCTestCase {
    func testContainerMetadataKeepsAllSchemesAndConfigurations() {
        let json = #"{"project":{"configurations":["Release","Debug","Staging"],"schemes":["Widget","App"]}}"#

        let metadata = SigningService.containerMetadata(from: json, isWorkspace: false)

        XCTAssertEqual(metadata.schemes, ["App", "Widget"])
        XCTAssertEqual(metadata.configurations, ["Debug", "Release", "Staging"])
    }

    func testTargetReportsDoNotMergeDifferentTargets() {
        let json = #"""
        [
          {"target":"App","buildSettings":{"CONFIGURATION":"Debug","PRODUCT_BUNDLE_IDENTIFIER":"com.example.app","PRODUCT_NAME":"App","DEVELOPMENT_TEAM":"TEAM1","CODE_SIGN_STYLE":"Automatic","SDKROOT":"iphoneos"}},
          {"target":"Widget","buildSettings":{"CONFIGURATION":"Debug","PRODUCT_BUNDLE_IDENTIFIER":"com.example.widget","PRODUCT_NAME":"Widget","DEVELOPMENT_TEAM":"","CODE_SIGN_STYLE":"Automatic","SDKROOT":"iphoneos"}}
        ]
        """#

        let reports = SigningService.targetReports(from: json, fallbackConfiguration: nil)

        XCTAssertEqual(reports.map(\.targetName), ["App", "Widget"])
        XCTAssertEqual(reports[0].settings.first { $0.key == "PRODUCT_BUNDLE_IDENTIFIER" }?.value, "com.example.app")
        XCTAssertEqual(reports[1].settings.first { $0.key == "PRODUCT_BUNDLE_IDENTIFIER" }?.value, "com.example.widget")
        XCTAssertEqual(reports[1].settings.first { $0.key == "DEVELOPMENT_TEAM" }?.isWarning, true)
    }
}
