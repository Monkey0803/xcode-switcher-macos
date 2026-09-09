import Foundation

enum ProjectDirectoryResolution: Equatable, Sendable {
    case project(URL)
    case none
    case ambiguous(directory: String)
}

enum ProjectDirectoryLocator {
    static func resolve(
        startingAt url: URL,
        fileManager: FileManager = .default
    ) -> ProjectDirectoryResolution {
        let standardized = url.standardizedFileURL
        if ["xcodeproj", "xcworkspace"].contains(standardized.pathExtension),
           fileManager.fileExists(atPath: standardized.path) {
            return .project(standardized)
        }

        var directory = standardized
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return .none }
        if !isDirectory.boolValue { directory = directory.deletingLastPathComponent() }

        while true {
            let packages = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let workspaces = packages.filter { $0.pathExtension == "xcworkspace" }
            let projects = packages.filter { $0.pathExtension == "xcodeproj" }
            if let preferredWorkspace = ProjectLocalConfigurationStore.load(in: directory)?.workspace,
               let workspace = workspaces.first(where: {
                   $0.lastPathComponent == preferredWorkspace || $0.path == directory.appendingPathComponent(preferredWorkspace).path
               }) {
                return .project(workspace.standardizedFileURL)
            }
            if workspaces.count == 1 { return .project(workspaces[0].standardizedFileURL) }
            if workspaces.count > 1 { return .ambiguous(directory: directory.path) }
            if projects.count == 1 { return .project(projects[0].standardizedFileURL) }
            if projects.count > 1 { return .ambiguous(directory: directory.path) }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory || directory.path == "/" { return .none }
            directory = parent
        }
    }
}

enum ProjectEnvironmentOutput: Equatable, Sendable {
    case exportDeveloperDirectory(String)
    case restoreOriginal

    var shellSource: String {
        switch self {
        case let .exportDeveloperDirectory(path):
            let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "export DEVELOPER_DIR='\(escaped)'"
        case .restoreOriginal:
            return "unset DEVELOPER_DIR"
        }
    }
}

enum ProjectEnvironmentResolution: Equatable, Sendable {
    case output(ProjectEnvironmentOutput)
    case issue(String)
}

enum ProjectEnvironmentResolver {
    static func resolve(
        for profile: ProjectProfile,
        installations: [XcodeInstallation],
        aliases: [String: String] = [:],
        activeInstallationID: String?,
        localConfiguration: ProjectLocalConfiguration? = nil,
        fileManager: FileManager = .default
    ) -> ProjectEnvironmentResolution {
        let resolution = ProjectXcodeMatcher.resolve(
            profile: profile,
            installations: installations,
            aliases: aliases,
            activeInstallationID: activeInstallationID,
            localConfiguration: localConfiguration,
            fileManager: fileManager
        )
        if let issue = resolution.issueDescription { return .issue(issue) }
        guard let installationID = resolution.installationID,
              let installation = installations.first(where: { $0.id == installationID }) else {
            return .issue("无法解析项目使用的 Xcode。")
        }
        guard case let .resolved(_, source) = resolution else {
            return .issue("无法解析项目使用的 Xcode。")
        }
        switch source {
        case .explicitBinding, .localConfiguration, .automaticRequirement:
            return .output(.exportDeveloperDirectory(installation.developerURL.path))
        case .currentInstallationFallback, .firstInstallationFallback:
            return .output(.restoreOriginal)
        }
    }
}

enum ZshProjectEnvironmentHook {
    static let source = #"""
if [[ -z "${__xcodeswitcher_original_developer_dir_captured:-}" ]]; then
  __xcodeswitcher_original_developer_dir_captured=1
  if [[ -v DEVELOPER_DIR ]]; then
    __xcodeswitcher_original_developer_dir_set=1
    __xcodeswitcher_original_developer_dir="$DEVELOPER_DIR"
  else
    __xcodeswitcher_original_developer_dir_set=0
    __xcodeswitcher_original_developer_dir=""
  fi
fi

__xcodeswitcher_restore_developer_dir() {
  if (( ${__xcodeswitcher_original_developer_dir_set:-0} )); then
    export DEVELOPER_DIR="$__xcodeswitcher_original_developer_dir"
  else
    unset DEVELOPER_DIR
  fi
}

__xcodeswitcher_update_developer_dir() {
  local output error_file source
  error_file="${TMPDIR:-/tmp}/xcodeswitcher-env-error.$$"
  output="$(xcodeswitcher env "$PWD" 2>"$error_file")"
  local hook_status=$?
  if (( hook_status != 0 )); then
    if [[ -s "$error_file" && "${__xcodeswitcher_last_error_directory:-}" != "$PWD" ]]; then
      cat "$error_file" >&2
      __xcodeswitcher_last_error_directory="$PWD"
    fi
    rm -f "$error_file"
    __xcodeswitcher_restore_developer_dir
    return
  fi
  rm -f "$error_file"
  if [[ "$output" == export\ DEVELOPER_DIR=* ]]; then
    source="$output"
    eval "$source"
  else
    __xcodeswitcher_restore_developer_dir
  fi
}

typeset -ga chpwd_functions precmd_functions
if (( ${chpwd_functions[(I)__xcodeswitcher_update_developer_dir]:-0} == 0 )); then
  chpwd_functions+=(__xcodeswitcher_update_developer_dir)
fi
if (( ${precmd_functions[(I)__xcodeswitcher_update_developer_dir]:-0} == 0 )); then
  precmd_functions+=(__xcodeswitcher_update_developer_dir)
fi
__xcodeswitcher_update_developer_dir
"""#
}
