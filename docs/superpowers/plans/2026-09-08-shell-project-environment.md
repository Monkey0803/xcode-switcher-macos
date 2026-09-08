# Shell Project Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let zsh automatically set a project-required `DEVELOPER_DIR` through `xcodeswitcher`, without changing global `xcode-select`.

**Architecture:** Add a small, testable resolver in `Sources/` that locates a single project package from a directory and converts only explicit project intent into shell output. `SourcesCLI/main.swift` exposes that logic through `env` and `shell-init zsh`; the zsh hook invokes the CLI after each directory change and restores the pre-hook environment on empty or failed resolution.

**Tech Stack:** Swift 5.9, Foundation, XCTest, zsh, macOS 13+.

## Global Constraints

- Do not invoke or modify `xcode-select` from `env` or `shell-init zsh`.
- Do not write `.zshrc` or other user configuration files.
- Reuse binding, `.xcode-version`, and `.tool-versions` precedence from `ProjectXcodeMatcher`.
- Never select active or first discovered Xcode as a shell-environment fallback.
- A directory with both a workspace and a project prefers the workspace; multiple candidate workspaces or projects require an explicit path.
- Preserve the public behavior of `list`, `current`, `resolve`, `doctor`, `use`, and `open`.

---

### Task 1: Locate a project package from a working directory

**Files:**
- Create: `Sources/ProjectEnvironment.swift`
- Modify: `Tests/ProjectMatchingTests.swift`

**Interfaces:**
- Produces: `ProjectDirectoryResolution`
- Produces: `ProjectDirectoryLocator.resolve(startingAt:fileManager:) -> ProjectDirectoryResolution`
- Consumes: a directory, `.xcodeproj`, or `.xcworkspace` `URL`

- [ ] **Step 1: Write failing directory-resolution tests**

Add test cases for a fixture directory with these expected results:

```swift
XCTAssertEqual(
    ProjectDirectoryLocator.resolve(startingAt: fixture.root),
    .project(fixture.workspaceURL)
)
```

Cover one project, workspace preferred over project at the same directory, an ancestor project discovered from a nested directory, no project, and two workspaces producing:

```swift
.ambiguous(directory: fixture.root.path)
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
```

Expected: compilation failure because `ProjectDirectoryLocator` and `ProjectDirectoryResolution` do not exist.

- [ ] **Step 3: Add the minimal directory locator**

Create `Sources/ProjectEnvironment.swift` with:

```swift
enum ProjectDirectoryResolution: Equatable, Sendable {
    case project(URL)
    case none
    case ambiguous(directory: String)
}
```

Implement `ProjectDirectoryLocator.resolve(startingAt:fileManager:)` to:

- Return `.project(startingAt)` for an existing `.xcodeproj` or `.xcworkspace` URL.
- Start from an existing directory, inspect immediate package children at each ancestor, and continue to the home directory or filesystem root.
- Prefer a single `.xcworkspace`; if none exists, use a single `.xcodeproj`.
- Return `.ambiguous` for multiple candidates of the preferred type.
- Return `.none` if no project package is found.

- [ ] **Step 4: Run the focused test and confirm it passes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
```

Expected: all directory-resolution and existing project-matching tests pass.

- [ ] **Step 5: Commit the locator**

```bash
git add Sources/ProjectEnvironment.swift Tests/ProjectMatchingTests.swift
git commit -m "feat(pc): 解析目录中的 Xcode 项目" -m $'- 支持从当前目录及父目录定位单一项目包\n- 优先 workspace 并拒绝不明确的多项目目录\n- 覆盖目录定位与现有匹配规则测试'
```

### Task 2: Format safe project environment output

**Files:**
- Modify: `Sources/ProjectEnvironment.swift`
- Modify: `Tests/ProjectMatchingTests.swift`

**Interfaces:**
- Produces: `ProjectEnvironmentOutput`
- Produces: `ProjectEnvironmentResolution`
- Produces: `ProjectEnvironmentResolver.resolve(for:installations:aliases:activeInstallationID:) -> ProjectEnvironmentResolution`
- Consumes: `ProjectProfile`, `ProjectXcodeMatcher.resolve`, and discovered installations

- [ ] **Step 1: Write failing output tests**

Add tests for:

```swift
XCTAssertEqual(output?.shellSource, "export DEVELOPER_DIR='/Applications/Xcode 16.app/Contents/Developer'")
XCTAssertEqual(noRequirementOutput?.shellSource, "unset DEVELOPER_DIR")
```

Cover explicit binding, `.xcode-version`, `.tool-versions`, a no-requirement project, a missing required Xcode, and an apostrophe in an Xcode path. The apostrophe case must use POSIX single-quote escaping (`'` becomes `'"'"'`) and never emit raw unquoted path text.

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
```

Expected: failure because `ProjectEnvironmentOutput` and `ProjectEnvironmentResolver` do not exist.

- [ ] **Step 3: Implement the formatter without fallback selection**

Add these types to `Sources/ProjectEnvironment.swift`:

```swift
enum ProjectEnvironmentOutput: Equatable, Sendable {
    case exportDeveloperDirectory(String)
    case restoreOriginal

    var shellSource: String {
        switch self {
        case let .exportDeveloperDirectory(path):
            return "export DEVELOPER_DIR='\(path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        case .restoreOriginal:
            return "unset DEVELOPER_DIR"
        }
    }
}

enum ProjectEnvironmentResolution: Equatable, Sendable {
    case output(ProjectEnvironmentOutput)
    case issue(String)
}
```

`ProjectEnvironmentResolver.resolve(...)` must:

- Return `.exportDeveloperDirectory` only for `.explicitBinding` and `.automaticRequirement` resolutions whose installation is available.
- Return `.restoreOriginal` for `.currentInstallationFallback` and `.firstInstallationFallback`.
- Return the existing resolution error for missing projects, missing bindings, and missing required Xcode.

- [ ] **Step 4: Run the focused test and confirm it passes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
```

Expected: all project matching and shell-output tests pass.

- [ ] **Step 5: Commit the formatter**

```bash
git add Sources/ProjectEnvironment.swift Tests/ProjectMatchingTests.swift
git commit -m "feat(pc): 输出项目 Shell 环境" -m $'- 仅根据明确项目要求生成 DEVELOPER_DIR\n- 无要求或解析失败时恢复调用 Shell 原始环境\n- 覆盖路径转义和缺失版本场景'
```

### Task 3: Expose the read-only CLI commands

**Files:**
- Modify: `SourcesCLI/main.swift`
- Modify: `Sources/CLIModels.swift`
- Modify: `build_app.sh`
- Modify: `Tests/CLIOptionsTests.swift`

**Interfaces:**
- Consumes: `ProjectDirectoryLocator` and `ProjectEnvironmentResolver`
- Produces: `xcodeswitcher env [path]`
- Produces: `xcodeswitcher shell-init zsh`

- [ ] **Step 1: Write failing command-option tests**

Add parser-level tests that preserve global flags and command values:

```swift
let env = try CLIOptions.parse(["--json", "env", "/tmp/App.xcodeproj"])
XCTAssertEqual(env.command, "env")
XCTAssertEqual(env.values, ["/tmp/App.xcodeproj"])

let shellInit = try CLIOptions.parse(["shell-init", "zsh"])
XCTAssertEqual(shellInit.command, "shell-init")
XCTAssertEqual(shellInit.values, ["zsh"])
```

- [ ] **Step 2: Run the focused test and confirm it fails only if parser assumptions changed**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIOptionsTests
```

Expected: existing generic parser already accepts the command shapes; use this passing test as proof that no parser rewrite is required.

- [ ] **Step 3: Add `env` and `shell-init zsh` handling**

In `SourcesCLI/main.swift`:

- Add `env` to the command switch. Resolve `values.first` or `FileManager.default.currentDirectoryPath` through `ProjectDirectoryLocator`.
- For `.project`, load a saved profile only when its standardized path equals the located project; otherwise create an unbound `ProjectProfile` for that URL.
- For `.none`, print `unset DEVELOPER_DIR` for human output and a JSON restore result for `--json`.
- For `.ambiguous`, throw `CLIError.failed("目录包含多个 Xcode 项目，请显式指定项目路径。")`.
- For a successful resolver result, print `shellSource`; for `--json`, print a new `CLIEnvironmentOutput` containing `project`, `developer`, and `restoreOriginal`.
- Add `shell-init`. Accept exactly `zsh`, print `ZshProjectEnvironmentHook.source`, and throw `CLIError.usage("用法：xcodeswitcher shell-init zsh")` otherwise.
- Add both commands to `help` and clarify that `env` and `shell-init` never change `xcode-select`.

Update `build_app.sh` to compile `Sources/ProjectEnvironment.swift` before `SourcesCLI/main.swift` in the standalone CLI command.

- [ ] **Step 4: Run strict tests and build the CLI**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" help
```

Expected: tests pass, the application builds, and help lists `env` and `shell-init zsh`.

- [ ] **Step 5: Commit the CLI integration**

```bash
git add SourcesCLI/main.swift Sources/CLIModels.swift build_app.sh Tests/CLIOptionsTests.swift
git commit -m "feat(pc): 添加项目 Shell 环境命令" -m $'- 增加 env 命令输出当前项目所需的 DEVELOPER_DIR\n- 增加 shell-init zsh 命令并保持全局 Xcode 不变\n- 将项目环境解析逻辑编译进独立 CLI'
```

### Task 4: Add the zsh hook template and documentation

**Files:**
- Modify: `Sources/ProjectEnvironment.swift`
- Modify: `Tests/ProjectMatchingTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces: `ZshProjectEnvironmentHook.source: String`
- Consumes: `xcodeswitcher env "$PWD"`

- [ ] **Step 1: Write a failing hook-template test**

Assert the generated source contains:

```swift
XCTAssertTrue(source.contains("chpwd_functions"))
XCTAssertTrue(source.contains("precmd_functions"))
XCTAssertTrue(source.contains("xcodeswitcher env \"$PWD\""))
XCTAssertFalse(source.contains("xcode-select"))
```

Also assert it preserves an original `DEVELOPER_DIR` variable and restores it after `unset DEVELOPER_DIR` or command failure.

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
```

Expected: failure because `ZshProjectEnvironmentHook` does not exist.

- [ ] **Step 3: Implement an idempotent zsh template**

Create `ZshProjectEnvironmentHook.source` with zsh code that:

- Captures the initial `DEVELOPER_DIR` once in `__xcodeswitcher_original_developer_dir` and tracks whether it was initially set.
- Defines `__xcodeswitcher_restore_developer_dir` to restore the original value or unset it when none existed.
- Defines `__xcodeswitcher_update_developer_dir` to capture CLI stdout/stderr separately; evaluate stdout only when it begins with `export DEVELOPER_DIR=`.
- Calls the restore helper on `unset DEVELOPER_DIR`, failure, or empty output.
- Adds the update function once to both `chpwd_functions` and `precmd_functions`, then invokes it immediately.

- [ ] **Step 4: Add README installation and usage documentation**

Add a `Shell 项目环境` subsection after the CLI examples:

```zsh
eval "$(xcodeswitcher shell-init zsh)"
```

Document that the command belongs in `.zshrc` only by user choice, settings apply to the current shell, `xcode-select` is unchanged, workspace wins over project, and ambiguous directories require `xcodeswitcher env /path/to/App.xcworkspace`.

- [ ] **Step 5: Run focused tests and manual zsh verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProjectMatchingTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh
zsh -fc 'eval "$("$1" shell-init zsh)"; print -r -- "$DEVELOPER_DIR"' zsh "$(pwd)/build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher"
```

Create temporary fixture directories with a valid project package and `.xcode-version` values for two installed Xcode versions. In a zsh child process, `cd` between them and a directory with no project; confirm `DEVELOPER_DIR` updates and restores while `xcode-select --print-path` remains unchanged.

- [ ] **Step 6: Commit hook and documentation**

```bash
git add Sources/ProjectEnvironment.swift Tests/ProjectMatchingTests.swift README.md
git commit -m "feat(pc): 支持 zsh 项目环境 Hook" -m $'- 为目录切换生成可选的 zsh 环境 Hook\n- 失败和无项目目录时恢复原始 DEVELOPER_DIR\n- 补充安装、优先级与冲突处理说明'
```

### Task 5: Complete verification

**Files:**
- Verify: `Sources/ProjectEnvironment.swift`
- Verify: `SourcesCLI/main.swift`
- Verify: `Sources/CLIModels.swift`
- Verify: `build_app.sh`
- Verify: `README.md`
- Verify: `Tests/ProjectMatchingTests.swift`
- Verify: `Tests/CLIOptionsTests.swift`

**Interfaces:**
- Verifies: `xcodeswitcher env`, `xcodeswitcher shell-init zsh`, existing CLI commands, and packaged application build.

- [ ] **Step 1: Run the complete smoke test**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./run_smoke_test.sh
```

Expected: `Smoke test passed: unit tests, Apple Silicon app/CLI, Sparkle link, plist, signature, scripts, and packaged launch.`

- [ ] **Step 2: Check CLI read-only behavior**

Run:

```bash
before=$(xcode-select --print-path)
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" env /path/to/project
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" shell-init zsh
after=$(xcode-select --print-path)
```

Expected: `env` emits shell source, `shell-init zsh` emits zsh source, and both commands leave the global developer path unchanged.

- [ ] **Step 3: Review the final diff**

Run:

```bash
git diff --check
```

Expected: no whitespace errors, build/release artifacts, fixture directories, or user shell configuration files.
