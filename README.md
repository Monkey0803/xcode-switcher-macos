# Xcode Switcher for macOS

一个原生 macOS 应用，用于发现、诊断和切换本机安装的 Xcode，并为不同项目固定对应的开发环境。

当前稳定版本：`1.0.0`（最低支持 macOS 13.0）。

## 功能

- 菜单栏常驻，支持自定义全局快捷键唤起主窗口并直接聚焦搜索框，默认快捷键为 `⌃⌥⌘X`。
- 通过 Spotlight、标准应用目录和自定义目录发现多个 Xcode，支持搜索、收藏和版本别名。
- 使用进程内复用的系统管理员授权执行 `xcode-select --switch`，同一次运行期间首次切换后可连续切换，切换后自动验证当前 Developer 路径。
- 查看 Xcode 路径、iPhoneOS SDK、Swift 和当前 `xcode-select` 环境诊断。
- 查看 Simulator Runtime，并可启动 iOS Runtime 下载或打开所选 Xcode 的 Settings。
- 添加 `.xcodeproj` / `.xcworkspace`，为项目绑定 Xcode，一键切换并打开项目。
- 自动读取项目或上级目录中的 `.xcode-version`、`.tool-versions`，匹配对应 Xcode；绑定版本或项目路径失效时会阻止误开并给出提示。
- 一键打开指定 Xcode，或打开注入对应 `DEVELOPER_DIR` 的 Terminal。
- 配置导入导出，保存搜索目录、收藏、别名、项目绑定、快捷键组合和快捷键开关。
- 签名管理页读取 Keychain 代码签名证书、Provisioning Profile，并支持按 Scheme、Configuration、Target 查看项目签名配置。
- 证书支持导出公钥 `.cer` 并在 Finder 中显示；Profile 支持直接打开其 Finder 路径。
- Runtime 下载显示命令进度，支持主动取消，并为外部命令设置超时保护。
- 针对每个 Xcode 执行环境体检，检查安装路径、Command Line Tools、首次启动任务、License、iPhoneOS SDK、Simulator、Rosetta 与磁盘空间；报告支持复制和导出。
- 菜单栏“项目”子菜单可直接按项目配置匹配 Xcode 并打开，失效项目会禁用并提示原因。
- 内置 `xcodeswitcher` CLI，可列出/解析/诊断/切换 Xcode，并按项目配置打开工程。
- 支持登录时启动、仅在菜单栏运行，以及基于 Sparkle 2 的安全自动更新。
- App 与 CLI 均构建为 Apple Silicon + Intel Universal Binary，并提供本地直接分发 ZIP/DMG，以及可选的 Developer ID 签名、公证、DMG 与 appcast 发布脚本。

## 构建与运行

```bash
cd /Users/huxiaohui/Documents/scripts/xcode-switcher-macos
./build_app.sh
open "build/Xcode Switcher.app"
```

构建脚本会解析固定版本的 Sparkle 依赖，编译 `Sources/` 下的全部 Swift 文件，并按 Sparkle 官方要求的嵌套顺序执行 ad-hoc 签名。开发签名仅为本地运行启用 Library Validation 调试例外；正式 Developer ID 构建不会携带该例外。构建产物是 `build/Xcode Switcher.app`，可以拖到“应用程序”文件夹后双击使用。未提供正式更新地址和公钥的开发构建会明确禁用“检查更新”。

## CLI

CLI 位于 App 包内：

```bash
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" help
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" list
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" current
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" resolve /path/Demo.xcworkspace
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" doctor 16.4
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" use 16.4
"build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" open /path/Demo.xcodeproj
```

安装到 `/Applications` 后，可将它链接到用户命令目录：

```bash
mkdir -p "$HOME/.local/bin"
ln -s "/Applications/Xcode Switcher.app/Contents/MacOS/xcodeswitcher" "$HOME/.local/bin/xcodeswitcher"
```

`use` 和 `open` 会在确实需要切换 Command Line Tools 时请求管理员授权；`resolve` 与 `doctor` 不改变系统配置。

## 正式发布（非 App Store）

本项目不要求发布到 Mac App Store。若只用于本机或团队内部，可直接生成未公证的 ZIP/DMG：

```bash
./build_local_release.sh
```

产物位于 `release/local/`。这类包不依赖 App Store，但首次运行可能需要用户在“系统设置 → 隐私与安全性”中确认，或右键选择“打开”。Sparkle 自动更新只适用于配置了 HTTPS feed、公钥并完成正式签名的构建。

可选：如果希望公开下载时不出现 Gatekeeper 提示，并启用 Sparkle 自动更新，可在 Keychain 中安装 Developer ID Application 证书，使用 `notarytool store-credentials` 保存公证凭据，并使用 Sparkle 的 `generate_keys` 生成 EdDSA 密钥。然后配置：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)"
export NOTARYTOOL_PROFILE="xcode-switcher-notary"
export SU_FEED_URL="https://example.com/xcode-switcher/appcast.xml"
export SPARKLE_PUBLIC_KEY="<Sparkle EdDSA public key>"
export SPARKLE_DOWNLOAD_URL_PREFIX="https://example.com/xcode-switcher/releases/"
# 可选：不使用 Keychain 中的 ed25519 私钥时，指定私钥文件路径
export SPARKLE_PRIVATE_KEY_FILE="/secure/path/sparkle-private-key"
./build_release.sh --preflight
./build_release.sh
```

`--preflight` 会一次性检查证书类型、Keychain 签名身份、HTTPS feed、Ed25519 公钥长度、Sparkle 工具和 Notary Keychain Profile。发布脚本会构建 Universal App/CLI、使用 hardened runtime 逐层签名、提交 Apple 公证并 stapling，最后生成：

- `release/updates/Xcode-Switcher-<version>-<build>.zip`
- `release/Xcode-Switcher-<version>-<build>.dmg`
- `release/appcast.xml`

私钥只保存在发布机器的 Keychain 中，不写入仓库。将 ZIP 和 appcast 上传至 `SUFeedURL` 对应的 HTTPS 站点即可供 Sparkle 检查更新。

### GitHub Actions 正式发布

推送 `v1.0.0` 标签后，`.github/workflows/release.yml` 会在 macOS runner 上生成 ad-hoc 签名的 ZIP/DMG、SHA256 校验文件并创建 GitHub Release。该流程不需要 App Store、Developer ID 或 Actions Secrets；首次运行可能需要用户在 macOS 的安全设置中手动确认。

当前直接分发版本不启用 Sparkle 自动更新，因此不要求配置 `SU_FEED_URL`。如果之后希望消除 Gatekeeper 提示并启用自动更新，再按上面的正式签名流程配置 Developer ID、公证凭据和 Sparkle 密钥。

### 1.0.0 发布前验收

1. 在真实的 Apple Silicon 和 Intel 机器上验证首次启动、辅助功能授权、管理员授权和多个 Xcode 版本切换。
2. 在干净用户环境安装直接分发 DMG，确认 Gatekeeper 手动放行、CLI 链接和项目打开流程。
3. 运行 `./run_smoke_test.sh`，确认测试、Universal 架构、嵌套签名和实际启动通过。
4. 确认 `CFBundleIdentifier`、应用名称和图标的发布归属，再推送 `v1.0.0` 标签。

## 测试

```bash
./run_smoke_test.sh
```

Smoke Test 会运行核心单元测试，覆盖项目版本匹配、失效绑定保护、进程超时/取消/输出流、多 Target 签名解析、环境报告和旧配置兼容；随后检查 App/CLI Universal 架构、Sparkle 动态链接、最低系统版本、Info.plist、嵌套签名、发布脚本语法及实际启动。

## 权限与安全

点击“激活所选 Xcode”后，应用会显示 macOS 原生管理员授权窗口。密码只交给系统授权服务处理，应用不会保存密码，也不会读取旧脚本中的默认密码。

Xcode 发现方式包括 Spotlight 和 `/Applications`、`~/Applications` 的直接扫描；列表按版本稳定排序，并标记当前 `xcode-select` 激活的版本。

项目绑定、收藏、别名和自定义搜索目录会保存到：

`~/Library/Application Support/XcodeSwitcher/configuration.json`

首次使用全局快捷键需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许本应用监听键盘事件。进入“设置 → 通用”，点击快捷键组合区域并按下带修饰键的组合即可录制；按下 `Esc` 可取消录制。

每个 Xcode 条目右侧都有 Finder 按钮，可直接在 Finder 中定位对应的 `.app`。应用图标由项目内的 `Resources/AppIcon.svg` 自动转换为 `AppIcon.icns` 并写入构建产物。
