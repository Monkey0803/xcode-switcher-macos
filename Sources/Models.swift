import AppKit
import Foundation

struct GlobalShortcut: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifierFlags: UInt

    static let `default` = GlobalShortcut(
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

    init(keyCode: UInt16, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init?(event: NSEvent) {
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = eventModifiers.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifierFlags: modifiers.rawValue)
    }

    var displayName: String {
        let modifiers = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "键(keyCode)")
    }
}

struct XcodeInstallation: Identifiable, Hashable, Sendable {
    let appURL: URL
    let version: String
    let build: String

    var id: String { appURL.path }
    var name: String { appURL.deletingPathExtension().lastPathComponent }
    var developerURL: URL { appURL.appendingPathComponent("Contents/Developer", isDirectory: true) }
    var displayVersion: String { build.isEmpty ? version : "\(version) (\(build))" }
}

struct ProjectProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var xcodeID: String?

    init(id: UUID = UUID(), name: String, path: String, xcodeID: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.xcodeID = xcodeID
    }

    var url: URL { URL(fileURLWithPath: path) }
}

struct ProjectXcodeRequirement: Equatable, Sendable {
    let source: String
    let rawValue: String
    let normalizedVersion: String
}

struct ProjectXcodeMatch: Equatable, Sendable {
    let requirement: ProjectXcodeRequirement
    let installationID: String?

    var isInstalled: Bool { installationID != nil }
}

struct AppConfiguration: Codable {
    var customSearchPaths: [String] = []
    var favoriteIDs: Set<String> = []
    var xcodeAliases: [String: String] = [:]
    var projects: [ProjectProfile] = []
    var globalShortcutEnabled = true
    var globalShortcut = GlobalShortcut.default
    var launchAtLoginEnabled = false
    var menuBarOnly = false
    var automaticallyChecksForUpdates = true

    private enum CodingKeys: String, CodingKey {
        case customSearchPaths, favoriteIDs, xcodeAliases, projects, globalShortcutEnabled, globalShortcut
        case launchAtLoginEnabled, menuBarOnly, automaticallyChecksForUpdates
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customSearchPaths = try container.decodeIfPresent([String].self, forKey: .customSearchPaths) ?? []
        favoriteIDs = try container.decodeIfPresent(Set<String>.self, forKey: .favoriteIDs) ?? []
        xcodeAliases = try container.decodeIfPresent([String: String].self, forKey: .xcodeAliases) ?? [:]
        projects = try container.decodeIfPresent([ProjectProfile].self, forKey: .projects) ?? []
        globalShortcutEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? true
        globalShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut) ?? .default
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
        menuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? false
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
    }
}

struct XcodeDetails: Sendable {
    var swiftVersion = "未知"
    var sdkVersion = "未知"
    var isCommandLineTools = false
}

struct SimulatorRuntime: Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let isAvailable: Bool
}

struct XcodeDiagnostic: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let isWarning: Bool

    init(title: String, value: String, isWarning: Bool) {
        self.id = title
        self.title = title
        self.value = value
        self.isWarning = isWarning
    }
}

enum EnvironmentCheckSeverity: Int, Codable, Comparable, Sendable {
    case healthy
    case informational
    case warning
    case error

    static func < (lhs: EnvironmentCheckSeverity, rhs: EnvironmentCheckSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct EnvironmentCheck: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: EnvironmentCheckSeverity
    let remediation: String?
}

struct EnvironmentReport: Codable, Equatable, Sendable {
    let installationID: String
    let installationName: String
    let version: String
    let generatedAt: Date
    let checks: [EnvironmentCheck]

    var highestSeverity: EnvironmentCheckSeverity {
        checks.map(\.severity).max() ?? .informational
    }

    var issueCount: Int {
        checks.filter { $0.severity >= .warning }.count
    }
}

struct SigningCertificate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let fingerprint: String
    let isValid: Bool
}

struct ProvisioningProfile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let uuid: String
    let path: String
    let teamID: String
    let appIdentifier: String
    let expirationDate: Date?
    let isExpired: Bool

    var displayExpiration: String {
        guard let expirationDate else { return "未知" }
        return expirationDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct SigningSetting: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let value: String
    let isWarning: Bool
}

struct SigningTargetReport: Identifiable, Hashable, Sendable {
    let id: String
    let targetName: String
    let configurationName: String
    let settings: [SigningSetting]
}

struct ProjectSigningReport: Sendable {
    let projectPath: String
    let scheme: String?
    let configuration: String?
    let availableSchemes: [String]
    let availableConfigurations: [String]
    let targets: [SigningTargetReport]
    let errorMessage: String?
}
