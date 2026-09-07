import Foundation
import XCTest
@testable import XcodeSwitcher

final class SimulatorParsingTests: XCTestCase {
    func testParsesAndSortsSimulatorDevices() throws {
        let data = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"udid":"B","name":"iPhone 15","state":"Booted","isAvailable":true},{"udid":"A","name":"iPhone 14","state":"Shutdown","isAvailable":true}]}}"#.utf8)
        let devices = XcodeTooling.parseSimulatorDevices(data: data)
        XCTAssertEqual(devices.map(\.name), ["iPhone 14", "iPhone 15"])
        XCTAssertTrue(devices.last?.isBooted == true)
        XCTAssertEqual(devices.first?.runtimeID, "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    }
}
