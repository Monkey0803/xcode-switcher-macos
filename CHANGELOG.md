# Changelog

## 1.4.0 - 2026-09-11

对照 WWDC 2026 的优化与稳定性改进：

- 项目解析结果改为缓存，视图渲染与菜单构建不再触发磁盘读取；打开项目的决策仍读取实时结果。
- 修复进程执行可能在子进程退出后永久等待孙进程释放管道的问题；超时与取消现在先 `SIGTERM` 再 `SIGKILL`。
- 配置保存失败不再静默，会在状态栏与设置页显示；历史备份上限 10 份且内容未变化时不新增。
- 项目名称与绑定的编辑改为防抖保存，打字不再逐字符重写配置文件与备份。
- 移除 30 秒定时全量扫描，改为监听 Xcode 搜索目录变化并按需刷新；缓存应用图标。
- 运行中下载进度不再重发布整个视图模型。
- 设置窗口只保留一条呈现路径，窗口按标识符区分而不是按标题字符串。
- Shell 环境 Hook 只在目录变化时执行，不再每条命令都启动一次 CLI。
- 应用声明的开发语言由英文修正为 `zh-Hans`。
- 测试改用默认构建后端可用（修正 Xcode 27 工具链下测试包无法加载 Sparkle 的问题），并开始增量引入 Swift Testing。
- 视图模型改为可注入配置存储，项目解析缓存、防抖保存、保存失败提示与备份上限现在都有测试覆盖。
- 修正历史备份去重依赖文件修改时间的缺陷：同一时刻的多次保存不再重复归档相同内容。
- 「打开 Xcode Settings」不再静默失败：缺少辅助功能权限、脚本执行报错、菜单中找不到 Settings 项都会在状态栏给出具体原因与手动替代方式；自动化脚本的语法由测试编译校验。
- 免 root 的 `DEVELOPER_DIR` 路径提到显眼位置：详情页把「系统级切换（需要管理员授权，影响全机）」与「不改系统设置」分成两个分组；后者可打开已注入 `DEVELOPER_DIR` 的终端，或一键复制 `export` 命令。
- 设置页新增「Shell 集成」分组，直接给出 zsh Hook 命令与把 App 内 CLI 链接到 PATH 的命令，并可一键复制。
- 项目推荐版本与当前版本不一致时，确认对话框改为三个选项：切换系统默认并打开、用推荐版本打开（不改系统设置）、取消。新增的中间选项直接用指定 Xcode 打开工程，不执行 `xcode-select --switch`；原来的「保留当前 Xcode 打开」已移除，避免与它语义重叠。
- 记录提权方式的决定：在不上架 App Store 的前提下仍保留 `AuthorizationExecuteWithPrivileges`——Apple 要求含 LaunchDaemon 的应用必须签名并公证，而本项目仍提供 ad-hoc 签名的直接分发构建；触发重新评估的条件写入代码注释与设计文档。
- 新增 `XcodeSwitcher.xcodeproj`（由 `Scripts/generate_xcode_project.py` 生成，可重复生成且结果一致），包含 app、`xcodeswitcher` CLI 与单元测试三个 target；`xcodebuild build` / `xcodebuild test` 与原有的 `swift test`、`build_app.sh` 并存，产物结构一致。
- 发布链路改为 `xcodebuild archive`：新增 `Scripts/archive_app.sh`（归档并校验 bundle 结构、arm64、CLI、Sparkle、图标），`build_local_release.sh` 与 `build_release.sh` 都走归档；正式分发用 `-exportArchive`（Developer ID）后再公证、做 DMG 与 appcast。`--preflight` 行为保持不变。
- CLI 本地化：`xcodeswitcher` 位于 app bundle 内时 `Bundle.main` 解析到外层 app，因此复用同一份 String Catalog；CLI 帮助、错误与状态消息，以及 `EnvironmentDoctor` 报告、`ProjectMatching` 诊断、`Services` 失败描述都已可本地化（catalog 273 条 `en`）。
- 修正一个本地化会触发的真实缺陷：`sdkVersion` 曾用字面量 `"未知"` 作哨兵值参与比较，一旦本地化会让英文下走错分支；现改为具名常量 `XcodeDetails.unknownValue`，只在展示时翻译。
- 测试断言改为语言无关（用同一处 `String(localized:)` 构造期望值），并在 `-testLanguage en` 下实测通过——修复前英文环境下确有断言失败。
- 按 WWDC 2026 session 213 的流程补上英文翻译：`Resources/Localizable.xcstrings` 现有 237 个键，其中 220 条提供 `en` 译文（其余为纯技术名或仅占位符的键，按术语表有意保留源值）；`en` 已加入工程 `knownRegions`，构建会产出 `en.lproj/Localizable.strings`。
- 新增 `TRANSLATION.md`（术语表、不可翻译清单、语气与占位符规则）并从 `AGENTS.md` 引用，对应 session 213 建议的按需上下文。
- 新增 `Scripts/verify_string_catalog.sh`：校验占位符与换行数量一致、译文非空、无遗留 stale 条目，并已接入 CI。
- 修掉一处不可翻译的源字符串：`正在%@ Simulator %@…` 把动词注入句子，英文无法用同一套祈使词构成进行时；改为三条完整句子。
- 接入 String Catalog：`Resources/Localizable.xcstrings`（源语言 `zh-Hans`）收录 232 个字符串键，覆盖视图字面量、状态栏消息、模型层标签与菜单项；新增 `Scripts/sync_string_catalog.sh` 在命令行把编译器提取结果合并回 catalog（`xcodebuild` 不会自动做这一步）。
- CI 改为两个 job：`macos-26` 上用 `xcodebuild build test` 验证 Xcode 工程并校验 String Catalog 与源码同步，脚本路径继续由 `run_smoke_test.sh` 完整验证；`release.yml` 的 runner 同步升级。
- 构建门槛提升为 Xcode 26（macOS 26 SDK）；`effectIsInteractive` 属 macOS 27 API，为不把门槛推到 beta 工具链而暂未启用，恢复方式记录在设计文档中。
- 适配 Liquid Glass（macOS 26+）：快捷键录制控件改用 `NSGlassEffectView` 背景、录制状态用玻璃着色表达，主要操作按钮改用 `.glassProminent`；macOS 13–25 保持原有外观。注意 macOS 上 SwiftUI 没有 `.glassEffect()`，Liquid Glass 是 AppKit 特性。
- 修正本次改动引入的可访问性回归：录制控件的标签改为真实文本控件后，控件本身不再是 AX 元素；现已恢复为可访问按钮并在实机 AX 树确认。
- 界面文案改为可本地化：49 处状态栏消息、28 处模型层标签、9 处菜单项标题与 7 处视图参数改用 `String(localized:)`；源语言下运行时行为不变。

## 1.3.0 - 2026-09-08

项目打开前的 Xcode 差异确认：

- 当项目固定绑定、`.xcode-version` 或 `.tool-versions` 要求的 Xcode 与当前激活版本不一致时，显示当前版本、推荐版本和匹配依据。
- 支持选择切换并打开、保留当前 Xcode 打开或取消；保留和取消均不会修改 `xcode-select`。
- 菜单栏项目入口也会显示确认对话框，避免后台静默切换开发者目录。
- 增加项目解析来源和打开决策的单元测试。

## 1.2.0 - 2026-09-07

稳定性和开发效率增强：

- GitHub Release 检查的 User-Agent 现在从应用版本动态生成，避免发布版本与请求标识不一致。
- 历史配置备份使用唯一文件名，连续保存不会覆盖同一秒内生成的恢复副本。
- 配置文件增加 schema 迁移、保存前备份和一键恢复，避免升级或导入配置造成数据丢失。
- CLI 增加 `--json` 和 `--dry-run`，便于脚本集成和在切换前预览操作。
- Simulator 支持读取设备状态，并可启动、关闭和抹掉设备；Xcode 切换成功后保留最近记录并支持回滚。
- 直分发构建增加 GitHub Releases 下载入口；Sparkle 仍仅在配置 HTTPS feed、公钥和正式签名时启用。
- 直接分发构建可读取 GitHub 最新 Release 并提示版本差异，菜单栏和设置页均可发起检查。
- 新增配置迁移、备份恢复、CLI 参数和 Simulator JSON 解析测试。

## 1.0.0 - 2026-09-04

首个公开版本，提供：

- 多版本 Xcode 发现、搜索、收藏、别名和环境诊断。
- 项目与 Xcode 版本绑定，支持 `.xcode-version` 和 `.tool-versions`。
- 菜单栏常驻、全局快捷键、登录启动和仅菜单栏运行。
- CLI 列表、解析、诊断、切换和打开项目。
- Keychain 证书/Profile 检查、App/CLI 构建和 Sparkle 更新支持。

当前版本最低支持 macOS 13.0；直接分发包需要用户按 macOS 安全提示确认首次运行。
