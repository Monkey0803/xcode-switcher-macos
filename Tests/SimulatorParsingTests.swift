import Foundation
import XCTest
@testable import XcodeSwitcher
@testable import XcodeSwitcherKit

final class SimulatorParsingTests: XCTestCase {
    func testParsesAndSortsSimulatorDevices() throws {
        let data = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"udid":"B","name":"iPhone 15","state":"Booted","isAvailable":true},{"udid":"A","name":"iPhone 14","state":"Shutdown","isAvailable":true}]}}"#.utf8)
        let devices = XcodeTooling.parseSimulatorDevices(data: data)
        XCTAssertEqual(devices.map(\.name), ["iPhone 14", "iPhone 15"])
        XCTAssertTrue(devices.last?.isBooted == true)
        XCTAssertEqual(devices.first?.runtimeID, "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    }

    func testParsesAndSortsSimulatorDeviceTypes() throws {
        let data = Data(#"{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","name":"iPhone 17","productFamily":"iPhone"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro","name":"iPad Pro","productFamily":"iPad"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","name":"iPhone 17","productFamily":"iPhone"}]}"#.utf8)
        let types = XcodeTooling.parseSimulatorDeviceTypes(data: data)

        XCTAssertEqual(types.map(\.name), ["iPad Pro", "iPhone 17"], "应按名称排序，且重复标识符只留一条")
        XCTAssertEqual(types.last?.productFamily, "iPhone")
    }

    func testSimulatorDeviceTypesWithoutProductFamilyAreKept() throws {
        let data = Data(#"{"devicetypes":[{"identifier":"x","name":"Something"}]}"#.utf8)
        let types = XcodeTooling.parseSimulatorDeviceTypes(data: data)

        XCTAssertEqual(types.count, 1, "缺字段的条目仍应可用，只是没有族别")
        XCTAssertEqual(types.first?.productFamily, "")
    }

    func testParsesRuntimeSupportedDeviceTypes() throws {
        let data = Data(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-3","name":"iOS 26.3","version":"26.3","isAvailable":true,"supportedDeviceTypes":["com.apple.CoreSimulator.SimDeviceType.iPhone-17"]},{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-3","name":"watchOS 26.3","version":"26.3","isAvailable":true}]}"#.utf8)
        let runtimes = XcodeTooling.parseSimulatorRuntimes(data: data)

        let iOS = try XCTUnwrap(runtimes.first { $0.id.contains("iOS-26-3") })
        XCTAssertEqual(iOS.supportedDeviceTypes, ["com.apple.CoreSimulator.SimDeviceType.iPhone-17"])
        let watch = try XCTUnwrap(runtimes.first { $0.id.contains("watchOS") })
        XCTAssertTrue(watch.supportedDeviceTypes.isEmpty, "运行系统没说支持哪些设备类型时留空，而不是猜")
    }

    func testMalformedSimulatorJSONYieldsNothingRatherThanCrashing() throws {
        XCTAssertTrue(XcodeTooling.parseSimulatorDeviceTypes(data: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(XcodeTooling.parseSimulatorRuntimes(data: Data("{}".utf8)).isEmpty)
    }
}
