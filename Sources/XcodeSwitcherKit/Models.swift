import AppKit
import Foundation

public struct GlobalShortcut: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifierFlags: UInt

    public static let `default` = GlobalShortcut(
        keyCode: 7,
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 54: "右⌘", 55: "左⌘", 56: "左⇧", 57: "右⇧", 58: "左⌥", 59: "左⌃",
        60: "右⌥", 61: "右⌃", 62: "右⌘", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "↩",
        78: "-", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    public init(keyCode: UInt16, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    public init?(event: NSEvent) {
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = eventModifiers.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifierFlags: modifiers.rawValue)
    }

    public var displayName: String {
        let modifiers = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "键(keyCode)")
    }
}

public struct XcodeInstallation: Identifiable, Hashable, Sendable {
    public let appURL: URL
    public let version: String
    public let build: String

    public var id: String { appURL.path }
    public var name: String { appURL.deletingPathExtension().lastPathComponent }
    public var developerURL: URL { appURL.appendingPathComponent("Contents/Developer", isDirectory: true) }
    public var displayVersion: String { build.isEmpty ? version : "\(version) (\(build))" }
}

public struct ProjectProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var xcodeID: String?

    public init(id: UUID = UUID(), name: String, path: String, xcodeID: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.xcodeID = xcodeID
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public struct ProjectXcodeRequirement: Equatable, Sendable {
    public let source: String
    let rawValue: String
    public let normalizedVersion: String

    public init(source: String, rawValue: String, normalizedVersion: String) {
        self.source = source
        self.rawValue = rawValue
        self.normalizedVersion = normalizedVersion
    }
}

public struct ProjectXcodeMatch: Equatable, Sendable {
    public let requirement: ProjectXcodeRequirement
    let installationID: String?

    public var isInstalled: Bool { installationID != nil }

    public init(requirement: ProjectXcodeRequirement, installationID: String?) {
        self.requirement = requirement
        self.installationID = installationID
    }
}

public struct AppConfiguration: Codable {
    static let currentSchemaVersion = 2

    /// The on-disk schema. Missing values from pre-1.2.0 files are migrated
    /// to the current schema by `AppConfigurationStore`.
    var schemaVersion = AppConfiguration.currentSchemaVersion
    public var customSearchPaths: [String] = []
    public var favoriteIDs: Set<String> = []
    public var xcodeAliases: [String: String] = [:]
    public var projects: [ProjectProfile] = []
    public var globalShortcutEnabled = true
    public var globalShortcut = GlobalShortcut.default
    public var launchAtLoginEnabled = false
    public var menuBarOnly = false
    public var automaticallyChecksForUpdates = true
    public var activationHistory: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, customSearchPaths, favoriteIDs, xcodeAliases, projects, globalShortcutEnabled, globalShortcut
        case launchAtLoginEnabled, menuBarOnly, automaticallyChecksForUpdates, activationHistory
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        customSearchPaths = try container.decodeIfPresent([String].self, forKey: .customSearchPaths) ?? []
        favoriteIDs = try container.decodeIfPresent(Set<String>.self, forKey: .favoriteIDs) ?? []
        xcodeAliases = try container.decodeIfPresent([String: String].self, forKey: .xcodeAliases) ?? [:]
        projects = try container.decodeIfPresent([ProjectProfile].self, forKey: .projects) ?? []
        globalShortcutEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? true
        globalShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut) ?? .default
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
        menuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? false
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
        activationHistory = try container.decodeIfPresent([String].self, forKey: .activationHistory) ?? []
    }

    mutating func migrate() {
        schemaVersion = Self.currentSchemaVersion
        var seen = Set<String>()
        activationHistory = activationHistory.filter { seen.insert($0).inserted }.prefix(10).map { $0 }
    }
}

public struct XcodeDetails: Sendable {
    /// Sentinel for "could not be determined". Deliberately **not** localized and
    /// never shown as-is: `XcodeViewModel.hasAvailableRuntime` compares against it,
    /// so translating the stored value would silently change which branch runs.
    /// Localize only at display time.
    public static let unknownValue = "未知"

    public var swiftVersion = XcodeDetails.unknownValue
    public var sdkVersion = XcodeDetails.unknownValue
    var isCommandLineTools = false
}

public struct SimulatorRuntime: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let isAvailable: Bool
    /// The device types this runtime can host, as `simctl` reports them. Empty when the
    /// runtime does not say, which the creation form reads as "no restriction" rather
    /// than as "nothing fits".
    public let supportedDeviceTypes: [String]
}

/// One simulator device type `simctl` can create, e.g. "iPhone 17 Pro".
public struct SimulatorDeviceType: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// "iPhone", "iPad", "Apple Watch" … — the family the model belongs to.
    public let productFamily: String
}

public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    let runtimeID: String
    public let isAvailable: Bool

    public var isBooted: Bool { state.caseInsensitiveCompare("Booted") == .orderedSame }
}

public struct XcodeDiagnostic: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let isWarning: Bool

    public init(title: String, value: String, isWarning: Bool) {
        self.id = title
        self.title = title
        self.value = value
        self.isWarning = isWarning
    }
}

public enum EnvironmentCheckSeverity: Int, Codable, Comparable, Sendable {
    case healthy
    case informational
    case warning
    case error

    public static func < (lhs: EnvironmentCheckSeverity, rhs: EnvironmentCheckSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct EnvironmentCheck: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let severity: EnvironmentCheckSeverity
    public let remediation: String?
}

public struct EnvironmentReport: Codable, Equatable, Sendable {
    let installationID: String
    let installationName: String
    let version: String
    public let generatedAt: Date
    public let checks: [EnvironmentCheck]

    public var highestSeverity: EnvironmentCheckSeverity {
        checks.map(\.severity).max() ?? .informational
    }

    public var issueCount: Int {
        checks.filter { $0.severity >= .warning }.count
    }
}

public struct SigningCertificate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fingerprint: String
    public let isValid: Bool

    public init(id: String, name: String, fingerprint: String, isValid: Bool) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.isValid = isValid
    }
}

public struct ProvisioningProfile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    let uuid: String
    public let path: String
    public let teamID: String
    public let appIdentifier: String
    public let expirationDate: Date?
    public let isExpired: Bool

    public var displayExpiration: String {
        guard let expirationDate else { return String(localized: "未知") }
        return expirationDate.formatted(date: .abbreviated, time: .omitted)
    }

    public init(
        id: String,
        name: String,
        uuid: String,
        path: String,
        teamID: String,
        appIdentifier: String,
        expirationDate: Date?,
        isExpired: Bool
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.path = path
        self.teamID = teamID
        self.appIdentifier = appIdentifier
        self.expirationDate = expirationDate
        self.isExpired = isExpired
    }
}

public struct SigningSetting: Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let isWarning: Bool

    public init(id: String, key: String, value: String, isWarning: Bool) {
        self.id = id
        self.key = key
        self.value = value
        self.isWarning = isWarning
    }
}

public struct SigningTargetReport: Identifiable, Hashable, Sendable {
    public let id: String
    public let targetName: String
    public let configurationName: String
    public let settings: [SigningSetting]

    public init(
        id: String,
        targetName: String,
        configurationName: String,
        settings: [SigningSetting]
    ) {
        self.id = id
        self.targetName = targetName
        self.configurationName = configurationName
        self.settings = settings
    }
}

public struct ProjectSigningReport: Sendable {
    let projectPath: String
    public let scheme: String?
    public let configuration: String?
    public let availableSchemes: [String]
    public let availableConfigurations: [String]
    public let targets: [SigningTargetReport]
    public let errorMessage: String?

    public init(
        projectPath: String,
        scheme: String?,
        configuration: String?,
        availableSchemes: [String],
        availableConfigurations: [String],
        targets: [SigningTargetReport],
        errorMessage: String?
    ) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.availableSchemes = availableSchemes
        self.availableConfigurations = availableConfigurations
        self.targets = targets
        self.errorMessage = errorMessage
    }
}
