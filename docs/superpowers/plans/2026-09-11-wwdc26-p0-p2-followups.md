# WWDC 2026 对照审查：P0–P2 实施与后续项

日期：2026-09-11
范围：对照 WWDC 2026（wwdc.ai 会话摘要）审查 `xcode-switcher-macos` 后确定的 P0–P2 改进项。

## 已实施

### P0 正确性与风险

| 项 | 改动 | 位置 |
| --- | --- | --- |
| 主线程磁盘 I/O | 项目解析结果按 3 秒生命周期缓存，输入变化时失效；`applyAndOpen` 绕过缓存取实时结果 | `Sources/XcodeSwitcher/ViewModel.swift` |
| 进程挂死 | `ProcessRunner` 改用非阻塞 `poll` 读取，直接子进程退出且输出排空后不再等待持有管道的孙进程；超时先 `SIGTERM` 再 `SIGKILL` | `Sources/XcodeSwitcherKit/Services.swift` |
| 配置静默丢失 | `AppConfigurationStore.save` 改为 `throws`，失败在状态栏与设置页可见 | `Sources/XcodeSwitcherKit/Services.swift`、`Sources/XcodeSwitcher/Views.swift` |
| 备份无限增长 | 历史备份上限 10 份；内容未变化时不新增；滚动 `.bak` 保留 | `Sources/XcodeSwitcherKit/Services.swift` |
| 逐键落盘 | 项目名/绑定编辑 400ms 防抖，失焦、回车、退出应用时立即落盘 | `Sources/XcodeSwitcher/ViewModel.swift`、`Sources/XcodeSwitcher/Views.swift` |

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
- `build_app.sh` 的 CLI 源文件清单改为自检：`Sources/` 下新增文件若未登记会直接构建失败。（该清单与自检已在 2026-09-18 的模块拆分中删除——目录本身成了目标定义，见文末结项记录。）
- `XcodeViewModel` 改为接受注入的 `AppConfigurationStore` 并可跳过系统服务初始化，使缓存与持久化行为可测；`Tests/ViewModelCachingTests.swift` 覆盖解析缓存、失效判定、防抖落盘、保存失败提示与备份上限（已验证：去掉缓存后两个缓存用例会失败）。
- 由上述测试发现并修正一个真实缺陷：历史备份的去重原先只看“最新”文件，而快速连续保存的修改时间会相同，导致相同内容被重复归档；现改为按内容比对全部归档文件，并用时间戳前缀命名使归档顺序确定。
- `openXcodeSettings` 的菜单自动化不再静默失败：脚本现在会返回是否找到 Settings 项，缺少辅助功能权限、脚本执行报错、菜单项缺失分别给出明确原因与手动替代方式；脚本语法由 `Tests/XcodeSettingsAutomationTests.swift` 编译校验（已验证：删掉一个 `end tell` 会让用例失败）。

## 后续项（当时未实施，附理由；结项情况见文末）

### 1. 提权方式：保留 `AuthorizationExecuteWithPrivileges`，不再迁移（已结案）

现状：`Sources/XcodeSwitcherKit/Services.swift` 通过 `@_silgen_name` 调用一个自 10.7 起废弃的符号。该决定与理由已写入代码注释，便于后续维护者看到上下文。

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

其中一条前置约束：`XcodeInstallation.id` 目前是 `appURL.path`（`Sources/XcodeSwitcherKit/Models.swift`），属于 per-device 值；按 310 的要求，暴露为 App Entity 前必须先改为跨设备稳定的标识符。

### 5. `XcodeViewModel` 的完整拆分

本轮只把高频变化的下载进度拆成 `RuntimeDownloadState`。把模型按安装列表/项目/签名/更新四向拆分仍会触及全部视图，且该文件目前没有测试覆盖，建议先补测试再动结构。

## 结项记录（2026-09-18）

上面标为「未实施」的四项（2、3、4、5）里，三项已经落地、第四项部分完成，而且**做法与当初的建议路径并不相同**——这正是不该只留建议路径的原因，记在这里免得后来者照着重走一遍。

### 2. 模块拆分 —— 已完成（提交 `59fd57c`）

与建议路径的三点不同：

- **用 `public` 而不是 `package`**：`package` 只在 SwiftPM 的包上下文里成立，另外两条构建路径不提供它（已核实 `build_app.sh` 与工程生成器都不传 `-package-name`）。这一点是设计判断，没有做实测对照。
- **Kit 在 Xcode 工程里必须是工程内的 target（静态库），不能改用「本地 Swift 包引用」**：SwiftPM 包 target 不携带 `SWIFT_EMIT_LOC_STRINGS`，Kit 里上百处 `String(localized:)` 会静默不再进入目录。这是实测结果——走包产物时 sync 只合并到 10 个 `.stringsdata`（应为 17）、目录掉到 444 键并出现约 65 条 stale。
- **`UpdateService` 里与 Sparkle 无关的版本比较逻辑没有一并移入**：不在本次范围，仍留在 app 侧。

落地时另外撞到两件当初没预料的事：SwiftPM 的 CLI target 名不能与 app target 只差大小写（macOS 卷大小写不敏感，两者的中间目录会是同一个）；以及 `sync_string_catalog.sh` 按 target 目录名取 `.stringsdata`，新增的 Kit 目录必须补进那份清单，否则它贡献的文案会被判成 stale。

### 3. String Catalog —— 已完成（先于本节记录，v1.5.0）

最终做法就是建议路径的第一条：用 `xcstringstool compile` 编进 `Resources`，两条构建路径都产出 `.lproj`，随后迁移到 Xcode 工程、用上完整的提取与合并流程。现状：`Resources/Localizable.xcstrings` 447 键、英文已译 429 条；`Scripts/sync_string_catalog.sh` 与 `Scripts/verify_string_catalog.sh` 都在 CI 里作为门禁（`.github/workflows/ci.yml` 第 32–44 行）。

### 4. 形态较大的新能力 —— 部分完成

- **Liquid Glass 视觉适配**：已完成（macOS 26 上的 glass 按钮样式与 `NSGlassEffectView` 录制控件，`AppearanceDecisions` 有测试覆盖）。
- **最低版本抬到 macOS 15**：已完成（提交 `b1d921d`）。**但没有做 `@Observable` / `SettingsLink` 迁移**：七个 store 与协调器仍都是 `ObservableObject`（共 8 个），而 `objectWillChange` 再发布的方案工作正常，迁移收益只有少量性能与可读性，不值得为此再动一遍全部视图。地板已是 15，将来有别的理由动视图时可以顺带做。
- **App Intents / Shortcuts** 与 **Xcode Cloud**：仍未动。前置约束依旧成立——`XcodeInstallation.id` 现在还是 `appURL.path`（`Sources/XcodeSwitcherKit/Models.swift:55`），是 per-device 值，要暴露成 App Entity 必须先换成跨设备稳定的标识符。

### 5. `XcodeViewModel` 完整拆分 —— 已完成（提交 `3df554d` … `3d6b2bf`）

1574 行、41 个 `@Published` 拆成七个 store：`InstallationStore`、`SigningStore`、`DiskCleanupStore`、`ReleaseStore`、`EnvironmentStore`、`ProjectStore`、`SettingsStore`；协调器剩 421 行，只含 store 与接线、同名转发、四个应用命令，以及唯一知道全部 store 的那处刷新扇出。

当初「该文件没有测试覆盖，建议先补测试再动结构」的顾虑，实际上是靠**拆分方式**绕开的而不是靠补测试：全程保持同名转发并订阅各 store 的 `objectWillChange` 再发布，于是视图与测试零改动，既有的 148 个用例恰好成了这次重构的安全网。结构约定与三条防退化规则记在 `AGENTS.md` 的「`XcodeViewModel` is a coordinator over stores」一节。

## 追加决定（2026-09-21）

### 索引内直接下载安装 Xcode —— 不做

「所有 Xcode 版本」窗口只到「打开 Apple 下载页 / 复制直链」为止，不在应用内实现下载、
校验与安装。理由、以及将来若重开需要先满足的前置条件，见
[2026-09-21-no-in-app-xcode-download.md](2026-09-21-no-in-app-xcode-download.md)。

### 已安装 Xcode 的「有新版本」提示 —— 已实现

同一天补上：`XcodeReleaseCatalog.newerRelease(than:in:)` 在索引里找同主版本、比本机更新
且本机跑得起来的**正式版**，`ReleaseStore.newerRelease(for:)` 转发到界面，主窗口列表行与
详情页「版本详细信息」各显示一处。只做提示、不做安装——这正是上面那条决定的产品后果。

### 英文文案补漏 —— 已实现，并记下漏法

起因是一个错判：一开始按「catalog 里 `en` 的 `stringUnit.value` 为空」统计，得到 29 个
「缺英文」的键，但其中 5 个其实是用 `variations.plural` 写的英文复数（`%lld 个版本`、
`已发现 %lld 个 Xcode。` 等），并不是没翻译。**再判断是否需要翻译时，必须同时看
`stringUnit` 与 `variations.plural`**，只看前者会虚报。

真正的问题在另一处：有约 40 处用户可见文案**根本没有进入 catalog**——`String(localized:)`
之外的普通字符串字面量（窗口与菜单标题、状态消息、体检详情与建议、磁盘清理目录名、
签名页的空值占位）。它们在英文系统下原样显示中文。

查法（可复用）：编译后 `build/DerivedData` 下每个源文件都有 `.stringsdata`，里面是编译器
**实际提取到**的键与 `location.startingLine`。把源文件里含中文的字面量与同一行的提取结果比对，
没有对应键的就是漏网之鱼。两个坑：

- 路径要统一（`.stringsdata` 里的 `source` 是绝对路径，脚本里用相对路径匹配会全部落空，
  于是把整棵树都报成候选）。
- 嵌套引号（`String(localized: "…\(x.joined(separator: "、"))")`）会让朴素的字面量正则只截到
  半个字符串，需要允许「提取到的键是字面量前缀」才算命中，否则同样是假阳性。

修法：把这些字面量包进 `String(localized:)`，跑 `sync_string_catalog.sh` 让它们进入 catalog，
再补 `en`。有一处不能只包壳——`SigningServices.targetReports` 原先用 `value == "未设置"`
判断是否告警，包上本地化后显示值与比较值会分家，因此改成对同一个 `unset` 常量比较。
数据层的哨兵值（`XcodeDetails.unknownValue`、`Services` 里 simctl 字段的 `"未知"` 回退）
**故意不本地化**，其理由写在 `Models.swift` 的注释里：它们参与相等比较，改了会静默改变分支。

### 同一条漏法已经变成门禁（2026-09-21 晚些时候）

上面那套临时脚本已经固化为 `Scripts/audit_unlocalized_strings.py`，并作为 CI 的一个 step
（`.github/workflows/ci.yml` 的「Audit for unlocalized strings」，紧跟在构建之后）。判据从
「提取到的键是字面量前缀」换成了更强的一条：`.stringsdata` 里的 `startingLine` /
`startingColumn` 就是提取到的字面量位置，**列号是 UTF-8 字节列**，直接比对位置即可，既不
怕嵌套引号也不怕重复文案。三条踩过的坑与豁免注释的写法写在 `AGENTS.md` 的
「`audit_unlocalized_strings.py` and the localization gate」一节；豁免条数会被打印出来，
不会静默放过。

顺带记一个仍未处理的隐患：`sync_string_catalog.sh` 判断 `.stringsdata` 是否陈旧仍按 mtime，
于是「内容正确但 mtime 陈旧」的文件会被跳过，它贡献的键被整批误标 `stale`——本次就因此误标
188 个键，按文档里的办法（删掉该文件整组产物再重建）恢复。审计脚本用的内容判据（记录的
位置是否仍落在引号上）是更可靠的替代，将来若动 `sync` 可以从那里借。
