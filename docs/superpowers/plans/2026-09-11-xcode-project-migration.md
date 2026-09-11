# 迁移到 Xcode 工程

日期：2026-09-11
范围：把 app / CLI / 测试的构建从「手写 swiftc + build_app.sh」迁到 `XcodeSwitcher.xcodeproj`，并借此接入 String Catalog。

## 为什么迁移

原路径（`build_app.sh` 调用 `swiftc`、手动拼装 bundle）有两个硬限制：

1. **字符串提取无法进行**。String Catalog 的提取依赖编译器输出 `.stringsdata` 并由构建系统合并回 catalog，手写 swiftc 流程拿不到这一步，所以本地化一直卡在「只有 development region 正确、没有 catalog」。
2. 新增平台能力（Liquid Glass 等）需要按 SDK 版本做可用性分支，用 Xcode 工程维护构建设置比在 shell 脚本里堆 `if #available` 与环境变量更可控。

`swift test` 与 `build_app.sh` **保留可用**，迁移期间与之后都是退路；两条路径的产物结构一致。

## 工程如何生成

本机既没有 xcodegen/tuist，`swift package generate-xcodeproj` 也已被移除，因此工程是生成出来的：

- `Scripts/generate_xcode_project.py` 产出 `XcodeSwitcher.xcodeproj/project.pbxproj`。
- pbxproj 用 **XML plist** 格式而非传统 OpenStep 格式（Xcode 两种都读），这样可以生成、diff、评审。
- 对象 ID 由 sha1 派生，**生成是幂等的**：重复运行得到字节一致的工程文件，所以「生成器 vs 提交的工程」不会漂移。
- 源文件按目录发现（`Sources/*.swift`、`Tests/*.swift`），新增文件不会漏；`SourcesCLI` 是 CLI 的显式子集。

### Target 结构

| Target | 类型 | 源文件 |
| --- | --- | --- |
| `XcodeSwitcher` | app | `Sources/*.swift`，产物 `Xcode Switcher.app` |
| `xcodeswitcher-cli` | tool | `SourcesCLI/CLIEntryPoint.swift` + 与 app 共享的 6 个源文件，产物 `xcodeswitcher` |
| `XcodeSwitcherTests` | 单元测试 | `Tests/*.swift`，宿主为 app |

CLI 直接复用 app 的源文件（Xcode 允许一个文件属于多个 target），因此**不需要**拆出框架 target，也不需要给上百个声明补 `public`/`package`。app target 通过 Copy Files 阶段（`dstSubfolderSpec = 6`、`CodeSignOnCopy`）把 CLI 嵌到 `Contents/MacOS/xcodeswitcher`。

## 踩到的四个坑（都已修，留作记录）

1. **`requirement.kind` 必须是 `exactVersion`**。写成 `exact` 时 Xcode 不报语法错，而是**静默丢弃整个包引用**（`resolved source packages:` 为空），表现为 `Missing package product 'Sparkle'`。
2. **target 名不能含空格**。`SWIFT_INCLUDE_PATHS` 是按空格分隔的列表，`…/Xcode Switcher.build/Objects-normal/arm64` 会被切成两段，测试 target 因此找不到 app 模块。现在 target 名是 `XcodeSwitcher`，产品名仍是 `Xcode Switcher.app`。
3. **target 名不能只差大小写**。macOS 文件系统不区分大小写，app 的 `XcodeSwitcher.build` 与 CLI 的 `xcodeswitcher.build` 是**同一个 intermediates 目录**，两个 target 互相覆盖 `.o` 与 `.swiftmodule`，症状是前后矛盾、时好时坏的链接错误（重复符号 / SwiftUICore 不允许链接）。CLI target 现名为 `xcodeswitcher-cli`。
4. **`ENABLE_DEBUG_DYLIB`（Xcode 27 的 Debug 默认）会把 app 的 `.swiftmodule` 留在 intermediates**，`BUILT_PRODUCTS_DIR` 里没有。已关闭；同时也让 Debug bundle 回到单可执行文件，和脚本构建一致。

另外：app target 的 `.swiftmodule` 本来就不进 `BUILT_PRODUCTS_DIR`，所以测试 target 通过 `SWIFT_INCLUDE_PATHS` 显式指向 app 的 `Objects-normal/$(CURRENT_ARCH)`。

`SourcesCLI/main.swift` 更名为 `CLIEntryPoint.swift`：文件名叫 `main.swift` 时隐含顶层代码语义，与 `@main` 冲突，原脚本靠 `-parse-as-library` 绕过；改名是根治。

## String Catalog 工作流

- `Resources/Localizable.xcstrings`，`sourceLanguage = zh-Hans`，已加入 app target 的 Resources 阶段；`SWIFT_EMIT_LOC_STRINGS = YES`、`DEVELOPMENT_LANGUAGE = zh-Hans`、`LOCALIZATION_PREFERS_STRING_CATALOGS = YES` 均已在工程里设好。
- **`xcodebuild` 不会把提取结果写回源目录的 catalog**（那是 Xcode IDE 的步骤）。`Scripts/sync_string_catalog.sh` 用 `xcstringstool sync` 在命令行完成同样的合并，因此 CI 可复现。
- Swift 的提取器**不识别 `NSLocalizedString`**（试过：用它的 9 个菜单项标题没有进 catalog）。界面文案统一用 `String(localized:)`，SwiftUI 的 `Text("…")` 字面量则自动提取。
- 源语言且无翻译时，构建不产出 `.lproj`（键即值，无需覆盖）。已在临时副本上验证：加入 `en` 翻译后 `xcstringstool compile` 会产出 `zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`，且译文正确。

当前 catalog 收录 232 个键，覆盖 SwiftUI 视图字面量、状态栏消息、模型层标签与菜单项。

## 尚未迁移的部分

- `build_app.sh`、`build_release.sh`、`build_local_release.sh` 仍走脚本路径，CI 也还在用它们。切换 CI 到 `xcodebuild` 与退役脚本是下一步。
- 本地化只搭好了机制：还没有任何翻译。添加语言时在 catalog 里补 `localizations` 即可，也可按 WWDC 2026 session 213 的流程用 Xcode agent 批量翻译。
- 一次未能复现的偶发：`xcodebuild test` 曾出现一次 248 秒卡顿并报 `Testing failed:`（无细节）。随后 3 次运行均在 ~2.7 秒通过，且已排除「有另一实例在运行」这一假设。CI 接入后需要留意。

## Liquid Glass 适配（P2-15）

**关键事实：macOS 上没有 SwiftUI 的 `.glassEffect()`。** 本机 SDK 的
`SwiftUI.swiftmodule` 里 `glassEffect` / `GlassEffectContainer` 出现 0 次；macOS 侧 SwiftUI 只提供
glass **按钮样式**（`.glass`、`.glassProminent`，`@available(macOS 26.0)`）。Liquid Glass 在 macOS
上是 **AppKit 特性**：`NSGlassEffectView` 与 `NSGlassEffectContainerView`（macOS 26.0+），
其中 `effectIsInteractive` 是 macOS 27.0+。任何「macOS 上用 `.glassEffect()`」的写法都不成立。

已实施（全部按 `#available` 分支，最低部署目标仍是 13.0）：

- `ShortcutRecorderNSView`：macOS 26+ 用 `NSGlassEffectView` 作背景，录制时用 `tintColor` 表达状态，
  更早系统保留原有自绘圆角矩形。由于父视图的 `draw(_:)` 输出位于子视图**下方**，标签改为独立的
  `NSTextField`（`hitTest` 返回 nil，不吞点击）。
- 主要操作按钮（「设为系统默认 Xcode」「应用并打开」）在 macOS 26+ 使用 `.glassProminent`，
  更早系统仍是 `.borderedProminent`。
- 装饰性的设置页徽标**未**改成玻璃：Liquid Glass 指南建议把玻璃留给可交互元素与卡片，
  给纯装饰元素加玻璃属于反模式。
- `Info.plist` 未设置 `UIDesignRequiresCompatibility`，即已选用新外观。

### 两个被自己抓到的缺陷

1. **helper 自递归**：把 `.buttonStyle(.borderedProminent)` 批量替换成 helper 调用时，误伤了
   helper 自己的 `else` 分支，变成 `content.prominentActionStyle()`。编译器不报错，本机走 26+ 分支
   也永远不会触发——**只有 macOS 13–15 用户会栈溢出**。已改回具体样式并留注释。
2. **可访问性回归**：标签从自绘文字改为 `NSTextField` 后，控件不再是 AX 元素，VoiceOver 只会读到
   裸快捷键（`⌃⌥⌘B`）。修正为 `setAccessibilityElement(true)` + 标签 `setAccessibilityHidden(true)`，
   并在运行中的 app 上用 AX 树确认：`AXButton (1799,493 190x30) [录制全局快捷键]`。

验证：`Tests/LiquidGlassAdoptionTests.swift` 5 个用例（本机为 macOS 27，真实执行 26+ 分支），
外加 `swift test -warnings-as-errors`、`xcodebuild test`、`run_smoke_test.sh` 全部通过。

## 构建门槛与 CI

**构建需要 Xcode 26 或更新（macOS 26 SDK）。** `NSGlassEffectView` 是 macOS 26 API，而
`#available` 是运行时检查——编译器仍要能看见符号。所以「最低支持 macOS 13」说的是*运行*，
*构建*门槛已被 Liquid Glass 适配抬到 macOS 26 SDK；`macos-14`（macOS 14 SDK）runner 已无法编译本项目。

CI 改为两个 job（`.github/workflows/ci.yml`）：

| Job | Runner | 内容 |
| --- | --- | --- |
| `xcode` | `macos-26` | `xcodebuild … build test`；随后跑 `sync_string_catalog.sh` 并 `git diff --exit-code Resources/Localizable.xcstrings`，保证 catalog 与源码同步 |
| `scripts` | `macos-26` | `./run_smoke_test.sh`（swift test、build_app.sh、bundle/签名/架构检查、CLI、zsh E2E、打包启动） |

`release.yml` 的 runner 同样从 `macos-14` 改为 `macos-26`。

**保留脚本路径**：`build_app.sh` / `build_release.sh` / `build_local_release.sh` 未删除，CI 仍会完整验证它们。
是否退役是取舍（脚本路径不依赖 Xcode 工程，但也不产出 catalog 与 glass 之外的构建能力），留给维护者决定；
若要退役，`build_local_release.sh` 承担 Developer ID 签名与公证，需要一并迁移到 `xcodebuild archive`。

### 一个有意的取舍：交互式玻璃

`NSGlassEffectView.effectIsInteractive`（指针悬停响应）在 SDK 里标注为 `API_AVAILABLE(macos(27.0))`，
使用它会把**构建**门槛推到 macOS 27 SDK（当前为 beta），并迫使 CI 使用 preview runner。因此当前未启用，
构建门槛保持在 macOS 26 SDK。等 Xcode 27 正式发布后恢复只需一行：

```swift
if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
```

## 已知待观察

`xcodebuild test` 出现过一次 248 秒卡顿并报 `Testing failed:`（无细节）。随后多次运行均在 ~2.7 秒通过，
「有另一 app 实例在运行」这一假设已被实测证伪，原因未查明。CI 接入后若复现，优先怀疑测试宿主的启动/退出时序。

## 英文翻译（按 WWDC 2026 session 213 的流程）

### 流程搭建

session 213 的建议逐条落实：

| 建议 | 落实 |
| --- | --- |
| 把翻译指引放在 `AGENTS.md`，或从它引用 `TRANSLATION.md`，使额外上下文只在翻译任务中读取 | 新增 `TRANSLATION.md`（术语表、不可翻译清单、语气、占位符规则），`AGENTS.md` 指向它 |
| 把目标语言加入工程设置 | `knownRegions` 加入 `en` |
| 分批翻译、术语一致 | 218 条中文键分三批写入，全部对照术语表 |
| 检查复数类别 | 5 个计数键改用 catalog 的 plural variations，编译产出 `Localizable.stringsdict` |
| 运行时审查本地化 UI（截断/裁剪） | 以 `-AppleLanguages '(en)'` 启动，读 AX 树核对渲染结果与尺寸 |

### 结果

`Resources/Localizable.xcstrings`：237 个键，**225 条 `en` 条目**（220 条普通译文 + 5 个复数变体），其余 17 条是纯 ASCII 技术名（`Xcode`、`Scheme`、`Safari` 路径等）与仅含占位符的键，按术语表有意保留源值。构建产出 `en.lproj/Localizable.strings` 与 `Localizable.stringsdict`。

### 翻译暴露出的源字符串问题

`正在%@ Simulator %@…` 把动词（启动/关闭/抹掉）注入句子，英文无法用同一套祈使词（Boot/Shut Down/Erase）构成进行时。按 session 213「决定改实现、改设计还是改译文」的指引，**改了实现**：拆成三条完整句子。这是翻译工作带来的真实收益，不是译文将就。

### 运行时审查的结论

- 以英文启动后读 AX 树：`System-wide Switch`、`Without changing system settings (no administrator authorization)`、`Open Terminal with DEVELOPER_DIR`、`Environment Diagnostics` 等均按预期渲染。
- 两条长说明**完整渲染**，容器随语言增高（分组 93 → 106pt，说明由 2 行变 3 行），没有裁剪。
- 代码中只有 8 处 `lineLimit`：7 处是路径（数据，非译文），1 处是状态栏 `lineLimit(2)`。最长的英文状态消息约 580pt，远小于状态栏 2 行约 1760pt 的容量，因此**译文没有截断风险**。
- 唯一带 `truncationMode(.middle)` 的是 Shell 集成里的 CLI 路径，实测 495×2 行容量约 990pt，而路径约 615pt，未触发截断。

### 工具与 CI

- `Scripts/verify_string_catalog.sh`：校验占位符多重集（`%@` 与 `%1$@` 视为等价）、换行数量、译文非空、复数变体齐全、无遗留 `stale` 条目。已接入 CI 的 `xcode` job。
- `Scripts/sync_string_catalog.sh` 会在字符串消失时把条目标记为 `stale` 而不是删除；stale 条目由校验脚本报出并手工清理（已清理 1 条：旧的 Simulator 动作模板键）。
- `xcstringstool sync` 会为**含多个占位符**的键自动生成源语言条目并用位置参数（`%1$@`）——这是 Apple 的做法，便于译者重排参数；校验脚本已按此放宽源语言的比较。

## 发布链路迁移到 `xcodebuild archive`

`Scripts/archive_app.sh` 用 `xcodebuild archive`（Release）产出 `build/XcodeSwitcher.xcarchive`，并校验 bundle 契约：主可执行文件名、内嵌 CLI、Sparkle.framework、图标、arm64。`build_local_release.sh` 与 `build_release.sh` 都改为基于归档产物，不再用 `build_app.sh` 手工拼装。

正式分发流程：归档 → 把 `SUFeedURL` / `SUPublicEDKey` 注入归档内的 Info.plist（这两个值不在仓库里）→ `-exportArchive`（Developer ID，`ExportOptions` 由脚本按签名身份解析 Team ID 后生成）→ 公证 zip、staple、DMG、公证 DMG、`spctl` 评估、生成 appcast。`-exportArchive` 会重新签名，因此注入的键也在签名覆盖范围内。

**验证范围（重要）**：

- 已验证：`xcodebuild archive` 成功、归档 bundle 结构与 Debug 路径一致（含 `en.lproj` 与 `zh-Hans.lproj`）、`codesign --verify --deep --strict` 通过、`build_local_release.sh` 端到端产出 zip 与 DMG、`build_release.sh --preflight` 在无凭证时按预期失败并提示全部必需变量。
- **已验证（2026-09-11，在不具备证书的前提下尽可能做）**：
  - 脚本生成的 `ExportOptions` plist 合法，`method` / `destination` / `signingStyle` / `signingCertificate` / `teamID` 五个键**均被 Xcode 接受**。
  - macOS 上 `method` 的合法取值为 `app-store-connect`、`developer-id`、`debugging`、`mac-application`、`validation`（`ad-hoc` 是 iOS 的取值，在 macOS 上会被拒绝）。
  - 密钥注入步骤可用：按脚本方式向归档内 app 的 Info.plist 写入 `SUFeedURL` / `SUPublicEDKey` 后能被读回，且 `-exportArchive` 会重新签名，覆盖该改动。
  - `release_preflight.sh` 会在证书缺失时**提前失败**并报「钥匙串中不存在签名身份」，脚本根本走不到导出步骤。
  - 证书缺失时 Xcode 的报错清晰可操作：`No certificate for team … matching 'Developer ID Application: …' found`。
  - 由此加固：导出后的 bundle 改为**按目录发现**而非硬编码 `Xcode Switcher.app`（名字由产品名派生，猜错只会在发版时才暴露）。
- **仍未验证**：`-exportArchive` 真正跑完，以及其后的公证、staple、DMG、appcast。原因是本机**没有任何可用的导出证书**：`Developer ID Application` 数量为 0，`method: debugging` 需要 "Mac Development" 证书（本机只有 Apple Development），`app-store-connect` 需要 provisioning profile；`notarytool` 也无凭证。首次正式发布会是这部分的第一次实测——请预留调试时间。

**要补齐验证，需要**：一份 `Developer ID Application` 证书（团队管理员创建后导入钥匙串）+ `notarytool store-credentials` 保存的凭证，之后 `build_release.sh` 即可在有 `SU_FEED_URL`、`SPARKLE_PUBLIC_KEY`、`SPARKLE_DOWNLOAD_URL_PREFIX` 的情况下完整跑通。

### 本地化与 CLI

CLI 与 app 共用同一份 catalog：`xcodeswitcher` 位于 `Contents/MacOS/` 时 `Bundle.main` 解析到外层 app bundle，`String(localized:)` 直接命中 `Contents/Resources/<lang>.lproj`。因此 CLI target 只需开启 `SWIFT_EMIT_LOC_STRINGS`，`sync_string_catalog.sh` 合并 app 与 CLI 两个 target 的 `.stringsdata` 即可。若把 CLI 单独拷到别处运行，则回退到源语言字符串。

## Homebrew 分发（评估结论）

**官方 `homebrew/cask` 走不通**：Homebrew 的 Acceptable Casks 要求「Gatekeeper 能评估的可执行产物必须通过其 Gatekeeper 检查」，而本项目的 ad-hoc 产物 `spctl --assess` 判定为 rejected。同一份文档指出，开源图形软件从源码构建时属于 formula。

实测结论（详见 `Formula/xcode-switcher.rb` 头部注释）：

- `Casks/xcode-switcher.rb`：指向 GitHub Release 的预编译 zip，`brew audit --cask` **通过（exit 0）**——因为不要求公证，这类定义只能放在自定义 tap 里。
- `Formula/xcode-switcher.rb`：Sparkle 作为 `resource`（校验和与 Sparkle 自身 Package.swift 一致）、离线构建路径可用；但 `brew install` 在 active Xcode 为 **27** 时会失败——SDK 27 的 `@State` 宏经 `swift-plugin-server` 展开，被 Homebrew 的 formula 构建沙箱拒绝，且只对 cask 与 Linux 提供了沙箱开关。同一份源码用 **macOS 26 SDK（Xcode 26.3）** 可正常构建，故该组合预期可用，但未经 brew 验证（Homebrew 的 superenv 不传递 `DEVELOPER_DIR`）。
