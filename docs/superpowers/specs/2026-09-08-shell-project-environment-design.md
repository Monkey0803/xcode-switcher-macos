# Shell Project Environment Design

## Goal

Allow zsh users to enter a project directory and automatically receive the Xcode-specific `DEVELOPER_DIR` required by that project, without changing the system-wide `xcode-select` selection.

## Scope

- Add `xcodeswitcher env [path]` to resolve a project from the current directory or an explicit path and emit shell-safe environment commands.
- Add `xcodeswitcher shell-init zsh` to emit an opt-in zsh hook that updates the current shell when its working directory changes.
- Reuse the existing project resolver, including explicit bindings, `.xcode-version`, and `.tool-versions` precedence.
- Restore the shell's original `DEVELOPER_DIR` when no project requirement applies or the requirement cannot be resolved.
- Document zsh installation and usage in the README.
- Add unit tests for the command output and the shell initialization contract.

## Out Of Scope

- Changing the global `xcode-select` developer directory.
- Editing `.zshrc` or any user shell configuration automatically.
- bash, fish, PowerShell, direnv, Finder Services, or Quick Actions.
- Installing missing Xcode versions.

## CLI Contract

### `xcodeswitcher env [path]`

- With no path, resolve the current working directory.
- Accept a directory, `.xcodeproj`, or `.xcworkspace` path.
- For a directory, inspect it and its ancestors for project packages. Use the only candidate when exactly one exists; when both a workspace and project exist at the same level, prefer the workspace. If multiple candidates of the preferred type exist, return a diagnostic requiring an explicit project path rather than selecting arbitrarily.
- When a matching installed Xcode is found, print exactly one shell-safe export command:

```zsh
export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'
```

- When no explicit binding or version-file requirement applies, print:

```zsh
unset DEVELOPER_DIR
```

- When the project path is invalid, its explicit binding is missing, or its required version is not installed, print the existing resolution error to standard error and return status 2.
- `--json` emits the resolved installation fields rather than shell source. `--dry-run` is not meaningful for this read-only command and is accepted without changing output.

### `xcodeswitcher shell-init zsh`

- Output zsh source code only; it must not modify files or run `xcode-select`.
- Preserve the value of `DEVELOPER_DIR` present when the hook is initialized in a private shell variable.
- On initialization, `chpwd`, and `precmd`, capture the output of `xcodeswitcher env "$PWD"`.
- If `env` succeeds with an export command, evaluate that command. If it emits `unset DEVELOPER_DIR` or fails, restore the preserved original `DEVELOPER_DIR`; failures display their concise diagnostic once for the current directory.
- Reject unsupported shell names with usage text and status 2.

## Architecture

The CLI continues to own command parsing and process exit status. A small pure formatter maps `ProjectXcodeResolution` plus the discovered installation to shell or JSON output, allowing command tests to validate all resolution outcomes without launching a shell. The zsh initializer is a static CLI output template that calls the existing executable each time the directory changes; it does not duplicate Xcode discovery or matching rules.

## Error Handling

- The `env` command never selects the active or first discovered Xcode as a fallback. Only explicit project intent may affect `DEVELOPER_DIR`.
- Directory discovery never chooses arbitrarily among multiple project packages of the same preferred type.
- Error output must be safe to display in a terminal and must not be evaluated as shell source.
- The hook treats command failure as an environment restoration event, preventing one project's failed resolution from leaking into another directory.

## Verification

1. Unit tests prove valid explicit bindings and version files emit the expected quoted export command.
2. Unit tests prove missing requirements emit an error and nonzero status.
3. Unit tests prove paths without project intent emit `unset DEVELOPER_DIR`.
4. Unit tests prove `shell-init zsh` contains initialization, `chpwd`, `precmd`, restoration, and no `xcode-select` invocation.
5. Run strict Swift tests and `./run_smoke_test.sh`.
6. In zsh, source `eval "$(xcodeswitcher shell-init zsh)"`, move between fixture directories requiring different Xcode versions, and verify `DEVELOPER_DIR` changes without changing `xcode-select --print-path`.
