# WWDC 2026 对照审查：P0–P2 实施与后续项

日期：2026-09-11
范围：对照 WWDC 2026（wwdc.ai 会话摘要）审查 `xcode-switcher-macos` 后确定的 P0–P2 改进项。

## 已实施

### P0 正确性与风险

| 项 | 改动 | 位置 |
| --- | --- | --- |
| 主线程磁盘 I/O | 项目解析结果按 3 秒生命周期缓存，输入变化时失效；`applyAndOpen` 绕过缓存取实时结果 | `Sources/ViewModel.swift` |
| 进程挂死 | `ProcessRunner` 改用非阻塞 `poll` 读取，直接子进程退出且输出排空后不再等待持有管道的孙进程；超时先 `SIGTERM` 再 `SIGKILL` | `Sources/Services.swift` |
| 配置静默丢失 | `AppConfigurationStore.save` 改为 `throws`，失败在状态栏与设置页可见 | `Sources/Services.swift`、`Sources/Views.swift` |
| 备份无限增长 | 历史备份上限 10 份；内容未变化时不新增；滚动 `.bak` 保留 | `Sources/Services.swift` |
| 逐键落盘 | 项目名/绑定编辑 400ms 防抖，失焦、回车、退出应用时立即落盘 | `Sources/ViewModel.swift`、`Sources/Views.swift` |

### P1 性能与现代 API

- 移除 30 秒定时全量 `mdfind` 扫描，改为目录 vnode 监听 + 按需（菜单打开、窗口出现）过期刷新。
- 缓存 `NSWorkspace.icon(forFile:)` 结果。
- 设置窗口只保留一条路径（AppKit 窗口），删除与 sheet 的重复；窗口区分改用 identifier，不再匹配中文字符串标题。
- 删除从未被引用的 `MenuBarContentView`。
- 运行中下载进度移出 `XcodeViewModel`，放进独立的 `RuntimeDownloadState`，下载输出不再重发布整个视图模型。
- 诊断与签名列表改用 `Grid`，去掉 125/220/240 pt 固定列宽；空状态图标尺寸改用 `@ScaledMetric`；补齐收藏按钮与快捷键录制控件的可访问性。

### P2 工程

- `run_smoke_test.sh` / CI 在新工具链下可用：Swift Build 已成为 SwiftPM 默认后端（WWDC26 262），它把 `Sparkle.framework` 放在 products 目录却只把 `PackageFrameworks` 加进测试包 rpath，导致测试包无法加载。测试 target 增加相对 rpath `@loader_path/../../../`，两种后端布局都成立。
- 引入 Swift Testing（WWDC26 267 主张增量迁移、与 XCTest 共存），新增 `Tests/ShellEnvironmentTests.swift` 行为测试。
- Shell hook 只在 `chpwd` 注册并增加同目录短路，不再每条命令都 spawn 一次 CLI。
- `CFBundleDevelopmentRegion` 由 `en` 改为 `zh-Hans`（此前声明为英文而界面全为中文）。
- `build_app.sh` 的 CLI 源文件清单改为自检：`Sources/` 下新增文件若未登记会直接构建失败。
- `XcodeViewModel` 改为接受注入的 `AppConfigurationStore` 并可跳过系统服务初始化，使缓存与持久化行为可测；`Tests/ViewModelCachingTests.swift` 覆盖解析缓存、失效判定、防抖落盘、保存失败提示与备份上限（已验证：去掉缓存后两个缓存用例会失败）。
- 由上述测试发现并修正一个真实缺陷：历史备份的去重原先只看“最新”文件，而快速连续保存的修改时间会相同，导致相同内容被重复归档；现改为按内容比对全部归档文件，并用时间戳前缀命名使归档顺序确定。
- `openXcodeSettings` 的菜单自动化不再静默失败：脚本现在会返回是否找到 Settings 项，缺少辅助功能权限、脚本执行报错、菜单项缺失分别给出明确原因与手动替代方式；脚本语法由 `Tests/XcodeSettingsAutomationTests.swift` 编译校验（已验证：删掉一个 `end tell` 会让用例失败）。

## 后续项（本轮未实施，附理由）

### 1. 提权方式：保留 `AuthorizationExecuteWithPrivileges`，不再迁移（已结案）

现状：`Sources/Services.swift` 通过 `@_silgen_name` 调用一个自 10.7 起废弃的符号。该决定与理由已写入代码注释，便于后续维护者看到上下文。

**已确认的前提**（2026-09-11）：

- 本项目只在 GitHub 开源分发，**不上架 App Store**，因此沙盒不是约束，走 `SMAppService` 特权 helper 在政策上完全允许。
- 但 Apple 对含 LaunchDaemon 的应用有签名与公证硬性要求。本机 SDK `ServiceManagement.framework/Headers/SMAppService.h` 原文：
  > Apps that use SMAppService APIs must be code signed.
  > For SMAppServices initialized as LaunchDaemons … **Apps that contain LaunchDaemons must be notarized.**
  对应错误 `kSMErrorInvalidSignature`：「The Application's code signature does not meet the requirements to perform the operation.」
- `xcode-select --switch` 需要 root，因此只能是 LaunchDaemon（LaunchAgent 以用户身份运行，改不了系统开发者目录）。
- 本机现状：`security find-identity -v -p codesigning` 只有 `Apple Development` 与 `Apple Distribution` 证书，**没有任何 `Developer ID Application`**；`xcrun notarytool` 也未存储凭证。仓库的 `Scripts/release_preflight.sh` 已经强制要求 `Developer ID Application` 证书，`build_release.sh` 已包含 `notarytool submit`，所以缺的是证书与凭证，不是脚本。
- 结论：**方案 C 目前无法端到端验证**，而 `build_app.sh` 的 ad-hoc 直接分发构建注册 daemon 必然失败，因此 C 还需要为 ad-hoc 构建保留回退分支，等于两套代码路径。

**结论（2026-09-11，维护者确认）**：**不做**这次迁移——不为一个已废弃但可用的符号引入签名/公证依赖与特权 helper。保留现状（方案 A）+ 文档化，不需要再评估。在不上架 App Store 的前提下，这条的唯一压力来自未来 macOS 可能移除该符号，而不是审核；替换它的收益低于上述风险。以下方案 C 仅作记录，**不计划实施**：helper target、`Contents/Library/LaunchDaemons/<label>.plist`（用 `BundleProgram` 指向包内可执行文件）、XPC 只暴露 `switchDeveloperDirectory(path:)`、`SMAppService.daemon(plistName:).register()`，并为 ad-hoc 构建保留现有 `AuthorizationCreate` 路径。

**未采用的备选**：`osascript -e 'do shell script "…" with administrator privileges'`。它不需要任何签名或公证，ad-hoc 构建也能用，但每次都是新进程、很可能每次切换都要重新授权，会丢掉现有「同一次运行内首次授权后可连续切换」的体验（未实测，因为需要真的弹出管理员授权对话框）。

### 1b. 同时把免 root 的 `DEVELOPER_DIR` 路径提到显眼位置

既然系统级切换必须走提权，产品上就把不需要授权的路径做成一等公民：

- Xcode 详情页拆成两个分组：「系统级切换」（`xcode-select --switch`，说明需要授权且影响全机）与「不改系统设置（不需要管理员授权）」（打开已注入 `DEVELOPER_DIR` 的终端、复制 `export` 命令）。
- 设置页新增「Shell 集成」分组，直接给出 `eval "$(xcodeswitcher shell-init zsh)"` 与把 App 内 CLI 链接到 PATH 的命令，两者都可一键复制。
- 项目推荐版本与当前版本不一致时，确认对话框改为三个选项：「切换系统默认并打开」「用推荐版本打开（不改系统设置）」「取消」。后者通过 LaunchServices 直接用指定 Xcode 打开工程，不切换系统开发者目录；原先的「保留当前 Xcode 打开」与之语义重叠，已移除。


### 2. 模块拆分，让 CLI 成为真正的 SwiftPM target

现状：CLI 由 `build_app.sh` 用共享源文件清单单独编译。CI 已经通过 `./build_app.sh` 编译并运行 CLI，`Scripts/shell_environment_e2e.sh` 也会执行它，清单漂移现在会直接构建失败，因此**当前并不存在“CLI 不被编译”的问题**。

**为什么没做**：拆分需要把 `Models/ProjectMatching/Services/EnvironmentDoctor/ProjectEnvironment/CLIModels` 移入库 target，并为跨模块使用的上百个声明补 `package` 或 `public`（结构体的 memberwise init 还需要逐个写成显式 init）；在收益有限的前提下，这是数百行纯注解改动加一次高风险结构变更。已复核并维持该判断：改为实现清单自检，把漂移变成构建期错误。

建议路径：引入 `XcodeSwitcherKit` 库 target，App 与 CLI 各自依赖；使用 Swift 5.9 的 `package` 访问级别控制暴露面，并把 `UpdateService` 中与 Sparkle 无关的版本比较逻辑一并移入。

### 3. String Catalog 本地化

现状：仅修正了 development region；字符串仍是硬编码中文。

**为什么没做**：当前构建是手写 `swiftc` 流程，Xcode 的字符串提取与 catalog 编译不可用；单语言下 catalog 的运行时效果为零，价值只在“为后续翻译铺路”。WWDC26 213 的 agent 翻译流程以 Xcode 工程为前提。

建议路径：先用 `xcstringstool compile` 把 `Resources/Localizable.xcstrings` 编进 `zh-Hans.lproj`，再逐步替换界面字符串；或迁移到 Xcode 工程后再采用 213 的全流程。

### 4. 形态较大的新能力

App Intents / Shortcuts（310、240、295）、Liquid Glass 视觉适配（289、269）、Xcode Cloud（261，该会话未讨论纯 SwiftPM 包）以及把最低版本抬到 macOS 14/15 以使用 `@Observable`、`SettingsLink` 等，都需要产品层面的取舍，本轮未动。

其中一条前置约束：`XcodeInstallation.id` 目前是 `appURL.path`（`Sources/Models.swift`），属于 per-device 值；按 310 的要求，暴露为 App Entity 前必须先改为跨设备稳定的标识符。

### 5. `XcodeViewModel` 的完整拆分

本轮只把高频变化的下载进度拆成 `RuntimeDownloadState`。把模型按安装列表/项目/签名/更新四向拆分仍会触及全部视图，且该文件目前没有测试覆盖，建议先补测试再动结构。
