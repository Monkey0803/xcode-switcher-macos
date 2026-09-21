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

    /// Verified against the real `simctl`: deleting an identifier that no longer
    /// resolves exits 2 and prints these two lines on stderr. They have to survive
    /// as the *reason* for the failure — dropping them is what left the UI saying
    /// only 「清理失败：iOS 27.0 (24A5380i)」.
    func testDeletionReasonKeepsSimctlsMessageOnOneLine() {
        let result = ProcessResult(
            status: 2,
            stdout: "",
            stderr: "No runtime disk images or bundles found matching 'CF787131'. Try 'runtime list'.\nNo matching images found to delete\n"
        )

        XCTAssertEqual(
            XcodeTooling.deletionReason(result),
            "No runtime disk images or bundles found matching 'CF787131'. Try 'runtime list'. No matching images found to delete",
            "状态栏只有一行，simctl 的两行要折成一行而不是被截掉"
        )
    }

    func testDeletionReasonFallsBackWhenSimctlSaysNothing() {
        let result = ProcessResult(status: 1, stdout: "", stderr: "")

        // The fallback is `failureDescription` itself, so compare against that rather
        // than a translated literal: spelling the key with the exit code baked in
        // (`…（退出码 1）。`) does not match the real key (`…（退出码 %lld）。`), and the
        // lookup silently falls back to the source text.
        XCTAssertEqual(XcodeTooling.deletionReason(result), result.failureDescription)
        XCTAssertFalse(result.failureDescription.isEmpty)
    }

    /// The platform decides two things: which `-downloadPlatform` value is passed, and
    /// whether an installed runtime counts as "this platform already has one". visionOS
    /// is the case worth pinning down — its runtime identifiers use Apple's `xrOS`
    /// spelling, while the download name is `visionOS`.
    func testPlatformsRecogniseOnlyTheirOwnRuntimes() {
        XCTAssertEqual(SimulatorPlatform.allCases.map(\.rawValue), ["iOS", "watchOS", "tvOS", "visionOS"])

        XCTAssertTrue(SimulatorPlatform.iOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3"))
        XCTAssertTrue(SimulatorPlatform.watchOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-3"))
        XCTAssertTrue(SimulatorPlatform.tvOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-3"))
        XCTAssertTrue(SimulatorPlatform.visionOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-26-0"))
        XCTAssertTrue(SimulatorPlatform.visionOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.visionOS-26-0"))

        // `watchOS`/`tvOS` must not be read as iOS: neither spelling contains "ios".
        XCTAssertFalse(SimulatorPlatform.iOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-3"))
        XCTAssertFalse(SimulatorPlatform.iOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-3"))
        XCTAssertFalse(SimulatorPlatform.watchOS.owns(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3"))
    }
}
