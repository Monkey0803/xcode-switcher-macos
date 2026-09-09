import Foundation

struct CLIOptions: Equatable, Sendable {
    let json: Bool
    let dryRun: Bool
    let command: String?
    let values: [String]

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var json = false
        var dryRun = false
        var remaining: [String] = []
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--dry-run": dryRun = true
            default: remaining.append(argument)
            }
        }
        return CLIOptions(
            json: json,
            dryRun: dryRun,
            command: remaining.first,
            values: Array(remaining.dropFirst())
        )
    }
}

struct CLIInstallationOutput: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let app: String
    let developer: String
    let active: Bool
    let alias: String?

    init(installation: XcodeInstallation, active: Bool, alias: String? = nil) {
        name = installation.name
        version = installation.version
        build = installation.build
        app = installation.appURL.path
        developer = installation.developerURL.path
        self.active = active
        self.alias = alias
    }
}

struct CLIOperationOutput: Codable, Equatable, Sendable {
    let action: String
    let installation: CLIInstallationOutput
    let project: String?
    let dryRun: Bool
}

struct CLIResolveOutput: Codable, Equatable, Sendable {
    let installation: CLIInstallationOutput
    let project: String
    let requirementSource: String?
}

struct CLIEnvironmentOutput: Codable, Equatable, Sendable {
    let project: String?
    let developer: String?
    let restoreOriginal: Bool
}

struct CLIErrorOutput: Codable, Equatable, Sendable {
    let code: String
    let message: String
}
