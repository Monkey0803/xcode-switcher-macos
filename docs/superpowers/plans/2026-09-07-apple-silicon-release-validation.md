# Apple Silicon Release Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the 1.2.0 distribution with its Apple Silicon-only support policy and verify the release candidate locally.

**Architecture:** The app and CLI continue to be compiled directly by `build_app.sh`, but only for `arm64`; their arm64 artifacts are installed into the bundle without creating a Universal Binary. Packaging and smoke-test assertions use the same single-architecture contract. README release statements become the sole operator-facing definition of the support matrix and manual acceptance work.

**Tech Stack:** Swift 5.9, Swift Package Manager, macOS shell tooling (`swiftc`, `lipo`, `codesign`, `plutil`), GitHub Actions.

## Global Constraints

- The release candidate version is `1.2.0`.
- The only supported hardware architecture is Apple Silicon (`arm64`).
- The minimum supported OS is macOS 13.0.
- Do not restore, test, or claim support for Intel or `x86_64`.
- Do not sign, notarize, tag, publish, or commit this work unless explicitly requested.

---

### Task 1: Produce Apple Silicon-only App and CLI bundles

**Files:**
- Modify: `build_app.sh:11-14,53-90`
- Modify: `build_local_release.sh:11-12`

**Interfaces:**
- Consumes: Swift sources in `Sources/` and `SourcesCLI/main.swift`.
- Produces: `build/Xcode Switcher.app/Contents/MacOS/XcodeSwitcherApp` and `build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher`, each containing `arm64` only.

- [ ] **Step 1: Write the failing architecture-policy check**

Run:

```bash
! grep -Eq 'arm64 x86_64|lipo -create|app_x86_64|cli_x86_64' build_app.sh
! grep -Eq 'arm64 x86_64' build_local_release.sh
```

Expected: The command fails because both scripts currently build or verify `x86_64`.

- [ ] **Step 2: Compile only the Apple Silicon executables**

Replace the architecture variables, loop, and `lipo` calls in `build_app.sh` with single `arm64` compile invocations and direct installation:

```bash
app_arm64="$script_dir/build/XcodeSwitcher-app-arm64"
cli_arm64="$script_dir/build/xcodeswitcher-cli-arm64"

/usr/bin/xcrun swiftc -O \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security \
  -F "$sparkle_parent" \
  -framework Sparkle \
  -Xlinker -needed_framework \
  -Xlinker Sparkle \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$script_dir"/Sources/*.swift \
  -o "$app_arm64"

/usr/bin/xcrun swiftc -O \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework Security \
  "$script_dir/Sources/Models.swift" \
  "$script_dir/Sources/ProjectMatching.swift" \
  "$script_dir/Sources/Services.swift" \
  "$script_dir/Sources/EnvironmentDoctor.swift" \
  "$script_dir/Sources/CLIModels.swift" \
  "$script_dir/SourcesCLI/main.swift" \
  -o "$cli_arm64"

cp "$app_arm64" "$macos_dir/XcodeSwitcherApp"
cp "$cli_arm64" "$macos_dir/xcodeswitcher"
```

- [ ] **Step 3: Make local packaging validate `arm64` only**

Replace the two `lipo` checks in `build_local_release.sh` with:

```bash
/usr/bin/lipo "$app_bundle/Contents/MacOS/XcodeSwitcherApp" -verify_arch arm64
/usr/bin/lipo "$app_bundle/Contents/MacOS/xcodeswitcher" -verify_arch arm64
```

- [ ] **Step 4: Run the architecture-policy check**

Run:

```bash
! grep -Eq 'arm64 x86_64|lipo -create|app_x86_64|cli_x86_64' build_app.sh
! grep -Eq 'arm64 x86_64' build_local_release.sh
```

Expected: Exit code 0.

### Task 2: Align Smoke Test and Release Documentation

**Files:**
- Modify: `run_smoke_test.sh:14-15,53`
- Modify: `README.md:26,86,100-105,113`

**Interfaces:**
- Consumes: the `arm64` executables created by `build_app.sh`.
- Produces: a smoke test that proves each executable contains `arm64`, and public release documentation with no Intel or Universal Binary support claim.

- [ ] **Step 1: Write the failing documentation-policy check**

Run:

```bash
! grep -Ein 'Universal Binary|Universal App/CLI|Apple Silicon \+ Intel|Apple Silicon 和 Intel' README.md
```

Expected: The command fails because the README currently describes Universal Binary and Intel support.

- [ ] **Step 2: Make Smoke Test assert the single architecture**

Replace the two architecture checks with:

```bash
/usr/bin/lipo "$executable" -verify_arch arm64
/usr/bin/lipo "$app_bundle/Contents/MacOS/xcodeswitcher" -verify_arch arm64
```

Replace the final output with:

```bash
printf 'Smoke test passed: unit tests, Apple Silicon app/CLI, Sparkle link, plist, signature, scripts, and packaged launch.\n'
```

- [ ] **Step 3: Correct README support and release statements**

Make these replacements:

```markdown
当前开发版本：`1.2.0`（仅支持 Apple Silicon，最低支持 macOS 13.0）。`v1.0.0` 为当前公开稳定版本。
```

```markdown
- App 与 CLI 均仅面向 Apple Silicon（`arm64`）构建，并提供本地直接分发 ZIP/DMG，以及可选的 Developer ID 签名、公证、DMG 与 appcast 发布脚本。
```

```markdown
`--preflight` 会一次性检查证书类型、Keychain 签名身份、HTTPS feed、Ed25519 公钥长度、Sparkle 工具和 Notary Keychain Profile。发布脚本会构建 Apple Silicon App/CLI、使用 hardened runtime 逐层签名、提交 Apple 公证并 stapling，最后生成：
```

Rename the section to `### 1.2.0 发布前验收`, and replace its first and third checklist items with:

```markdown
1. 在真实 Apple Silicon 机器上验证首次启动、辅助功能授权、管理员授权和多个 Xcode 版本切换。
3. 运行 `./run_smoke_test.sh`，确认测试、Apple Silicon 架构、嵌套签名和实际启动通过。
```

Replace the Smoke Test architecture description with:

```markdown
Smoke Test 会运行核心单元测试，覆盖项目版本匹配、失效绑定保护、进程超时/取消/输出流、多 Target 签名解析、环境报告和旧配置兼容；随后检查 App/CLI Apple Silicon 架构、Sparkle 动态链接、最低系统版本、Info.plist、嵌套签名、发布脚本语法及实际启动。
```

- [ ] **Step 4: Run the documentation-policy check**

Run:

```bash
! grep -Ein 'Universal Binary|Universal App/CLI|Apple Silicon \+ Intel|Apple Silicon 和 Intel' README.md
```

Expected: Exit code 0.

### Task 3: Execute Release Candidate Validation

**Files:**
- Verify: `build_app.sh`
- Verify: `build_local_release.sh`
- Verify: `run_smoke_test.sh`
- Verify: `README.md`

**Interfaces:**
- Consumes: completed Apple Silicon-only scripts and documentation.
- Produces: local evidence of strict tests, a signed arm64 bundle, and the remaining manual acceptance checklist.

- [ ] **Step 1: Run the CI-equivalent strict test suite**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: Exit code 0 with all tests passing and no warnings.

- [ ] **Step 2: Run the complete Smoke Test**

Run:

```bash
./run_smoke_test.sh
```

Expected: Exit code 0 with the final `Smoke test passed` line identifying Apple Silicon App/CLI.

- [ ] **Step 3: Check syntax and support-policy remnants**

Run:

```bash
git diff --check
! grep -REin 'x86_64|Universal Binary|Universal App/CLI|Apple Silicon \+ Intel|Apple Silicon 和 Intel' README.md build_app.sh build_local_release.sh run_smoke_test.sh
```

Expected: Exit code 0.

- [ ] **Step 4: Record manual Apple Silicon release acceptance**

On a real Apple Silicon Mac, install the direct-distribution DMG in a clean user account and verify: first launch and Gatekeeper approval; Accessibility permission and global shortcut; administrator-authorized `xcode-select` switching; CLI symbolic-link installation; project open flow; and GitHub Release check/download. These flows are interactive and cannot be proven by the local automated commands.

- [ ] **Step 5: Leave changes uncommitted**

Do not run `git commit`, create a tag, or publish a release. The user has not requested any of those operations.
