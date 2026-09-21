# Changelog

## 未发布

### 修复

- **Xcode 27 / macOS 27 下无法构建与测试**：`swift build`、`swift test`（因而 `run_smoke_test.sh`）在 Xcode 27 上编译 CLI 目标时报 `unable to open dependencies file …/CLIEntryPoint.d`。根因是 `Package.swift` 里两个 SwiftPM **产品**名只差大小写——app 的 `XcodeSwitcher` 与 CLI 的 `xcodeswitcher`；新版 Swift Build 后端按 `<产品名>-p.build` 建立目录，而 APFS 默认大小写不敏感，两者塌进同一个目录（实测同一 inode），互相覆盖文件列表与 output map。app 产品改名 `XcodeSwitcherApp`（与 `CFBundleExecutable` 一致）后修复；目标名早就为此改过（`xcodeswitcher-cli`），产品名漏了。Xcode 27.1 与 26.3 下均实测 `swift build` 与 `run_smoke_test.sh` 通过。注意这不等于 formula 支持 macOS 27——那条还卡在 Homebrew 沙箱的 SDK 27 `@State` 宏问题上。
- **`sync_string_catalog.sh` 不再因 mtime 误报陈旧**：它原先按 mtime 判断 `.stringsdata` 是否过期，而「提取出的字符串没变」时构建系统会复用该文件（mtime 旧、内容正确），`git checkout`/`stash`/`cp` 也会只改 mtime 而不动内容——两种情况下该文件贡献的键都会被整批误标为 `"extractionState": "stale"`，目录门禁随之变红却没有任何真问题（本次会话中就发生了两次，其中一次误标 204 个键）。判断改为按内容：记录的位置是否仍落在字面量的起始引号上，实现抽到 `Scripts/stringsdata_freshness.py`，与 `audit_unlocalized_strings.py` 共用同一份判断，两个门禁不会各自漂移。
- **`sync_string_catalog.sh` 不再打印生成文件的跳过噪声**：Swift 每个 target 都会写一份 `ExtractedAppShortcutsMetadata`（编译器元数据而非字符串键，没有对应源码），此前每次 sync 都会为它打印两行「its source no longer exists」。审计脚本本来就按名字忽略它，现在两处一致。

### 变更

- **工程**：新增 `Scripts/sync_tap_repo.sh`，把 `Casks/` 与 `Formula/` 同步进 Homebrew tap 仓库（并改掉 tap README 里的两处版本引用），打印 diff 与提交/推送命令——推送仍由人做，且必须用 tap 仓库要求的 noreply 提交身份（用本机邮箱会被 GitHub 拒收）。此前这一步完全靠记忆：v2.0.0 发布时就没做，于是 `brew install --cask xcode-switcher` 在两个版本里一直提供 1.5.1，且那个 cask 还写着 `depends_on macos: :ventura`。
- **工程**：新增应用日志（`AppLog`，subsystem `com.yostar.xcodeswitcher`，按领域分为 launch / switching / cleanup / runtime / release / projects / environment / settings）。每次启动先记「哪个构建、哪个系统、哪个开发者目录」，切换、清理目录、删除 Runtime、Runtime 下载与发布索引加载各记一条——界面上这些失败只有一行状态消息，此前排查只能读代码并现场复现。取证方式见 `AGENTS.md` 的「Diagnosing from the log」。

## 2.1.0 - 2026-09-21

### 新增

- **版本列表判断本机能否运行**：索引声明的 `requires` 此前只被当作文字显示（「需要 macOS 26.6」），从不与当前系统比较——在 macOS 15 上看到需要 26.6 的条目只能靠肉眼读那行小字。现在按点分数字比较（覆盖 `10.15.4` 这类两位主版本与补丁位），跑不了的条目标注并可按「隐藏本机无法运行的版本」过滤；只有 x86_64 下载的条目按「需要 Rosetta 2」提醒，而不是判定为跑不了。解析不了的最低版本、为空的架构列表都按「索引没说」处理，不猜成装不了。
- **版本列表按芯片筛选**：「所有 Xcode 版本」窗口在「安装状态」旁多一个「芯片」选择器（全部 / Apple Silicon / Intel），依据索引的 `downloadArchitectures`；两者都提供则两边都算，索引没说的（空列表）一律保留、不参与筛选——不说并不等于不提供。
- **「所有 Xcode 版本」窗口的刷新按钮**：此前只在加载失败时才有「重新加载」，而索引按天缓存，成功加载后想手动拉新最长要等一天。按钮贴在搜索框右侧，与主窗口的刷新按钮同位置、同写法。
- **已安装 Xcode 的「有新版本」提示**：「所有 Xcode 版本」索引里存在同一主版本、比本机更新、且本机跑得起来的**正式版**时，主窗口列表行显示「有新版 x.y」，详情页「版本详细信息」显示完整提示。只做提示不做安装——应用不提供索引内下载，理由见 `docs/superpowers/plans/2026-09-21-no-in-app-xcode-download.md`。判断规则：只看 `release` 渠道（beta/GM/RC 不算更新）、只比同一主版本（15.x → 26.x 是迁移而非更新）、版本号按数字逐段比较、本机无法运行的版本不作为升级目标。
- **模拟器设备补齐克隆、重命名与新建**：此前只有启动/关闭/抹掉/删除，而应用已经能下载 Runtime 却不能为它建一台设备，流程到此断掉只能回命令行。标题行「新建…」打开表单（名称 + 运行系统 + 设备类型，设备类型按所选运行系统过滤，免得在 130 个型号里盲选），行内「⋯」菜单承载克隆与重命名。
- **环境体检补上「终端里的 Xcode」与第三方工具链**：经登录 shell 读 `DEVELOPER_DIR` 并跑 `xcodebuild -version`，与正在体检的版本比较，分「一致 / 指向不存在的路径（错误）/ 指向另一台（警告）」三种情形；另按工具做条件检查（目前是 CocoaPods 的 `pod env`），未安装的工具不产生条目，读不出则报「信息」而不是猜。这回答的正是「明明切了 Xcode，构建还是老 SDK」的常见成因。

### 修复

- **「下载」改走 Apple 下载页**：原先「下载」直接打开索引里的 `.xip` 直链，而它需要开发者会话 cookie；未登录时 Apple 不报错而是 302 跳到 `/unauthorized/`，用户看到的只是一句「未授权」。现在打开带版本号查询的 Apple 下载页（查询词用 Apple 的英文标题形式，刻意不用界面文案「正式版」，否则在 Apple 站上搜不到东西），登录并接受许可后才给文件；按钮加了提示语说明这一点。
- **「复制直链」改为可见按钮**：直链没有丢，但上一版把它放在「下载」链接的右键菜单里，实测等于找不到（用户反馈「没有看到」）；现在是与链接并排的一个按钮，悬停显示将要复制的地址。
- **刷新失败时把原因显示出来**：有缓存时 `load()` 的 catch 分支把错误丢掉了，界面只能区分「刷新失败」与「成功」，无法区分网络断了和服务器返回错误响应——现场那条橙色提示正是这种无从下手的状态。现在把失败原因一路带到界面，在原有提示下补一行次要文字。
- **删除 Simulator Runtime 失败时看不出原因**：状态栏此前只报「清理失败：iOS 27.0 (24A5380i)」——`XcodeTooling.deleteSimulatorRuntimes` 把 simctl 的 stderr 丢掉了，只回传标识符。现在失败项带上 simctl 的原话（多行折成一行，状态栏只有一行），例如「清理失败：iOS 27.0 (24A5380i) — No runtime disk images or bundles found matching '…'. Try 'runtime list'.」。
- **「这一项已经不存在」不再报成清理失败**：删除前先重读一次 `simctl runtime list -j`，标识符已经不在里面、或 simctl 仍回「No matching images found to delete」的，都算「已经不存在」而不是失败，状态栏改为「… 已经不存在，列表已刷新。」并照常刷新列表。重读失败（列表命令本身出错）时不做任何假设，仍照原样尝试删除——「列表读不到」不等于「东西没了」，混为一谈会静默漏删。

### 变更

- **英文界面补齐**：此前有约 40 处用户可见文案没有走本地化，系统语言为英文时仍然显示中文——窗口与菜单标题（「所有 Xcode 版本」「Xcode Switcher 设置」「项目」）、状态栏消息（更新检查、GitHub Releases 错误）、Runtime 下载进度、磁盘清理目录名、签名页的空值占位（「未设置」「未命名 Target」）、环境体检的详情与建议。现在全部接入 String Catalog 并补上英文（552 键，`en` 已译 535 条，其余为按 `TRANSLATION.md` 无需翻译的纯 ASCII 术语）。
- 签名页的「未设置」判定改为对同一个本地化值比较：原先 `value == "未设置"` 在英文环境下会因为显示值变成译文而失效。
- **工程**：新增 `Scripts/audit_unlocalized_strings.py` 作为 CI 门禁，任何含中文却没进 String Catalog 的字面量都会让构建失败（可加 `unlocalized-audit:ok：<理由>` 豁免）。此前 `sync` 与 `verify` 只看已经进目录的字符串，发现不了「文案根本没进目录」——上面那约 40 处就是这样漏了很久。测试同时改为用 `xcodebuild test -testLanguage en` 在本机复现 CI 的英文环境，不再靠「本地中文环境碰巧过」判断。

## 2.0.0 - 2026-09-18

### 变更

- **最低支持版本从 macOS 13 抬到 macOS 15**：`Package.swift`、`Info.plist`、生成的 Xcode 工程与 `build_app.sh` 的部署目标一并升到 15.0，cask 的 `depends_on macos` 改为 `:sequoia`。macOS 13 与 14 不再受支持。
- **迁移随版本抬升而失效的 API**：`onChange(of:perform:)` 自 macOS 14 起废弃，在 13 的部署目标下不触发、抬到 15 后会被「警告即错误」拦下，三处已改为两参数形式。
- **内部结构重组（不影响功能）**：app 与 CLI 共享的代码拆成 `XcodeSwitcherKit` 模块，两条构建路径真正共用同一份而不是各编译一份；1574 行的 `XcodeViewModel` 按职责拆成七个 store，它本身只剩协调与转发。这两项都不改变用户可见行为，一并列出以便对照版本变化。

## 1.6.0 - 2026-09-17

### 新增

- **「所有 Xcode 版本」窗口**：列出社区发布索引中的全部版本（453 条按构建号去重为 387 行），本机已安装的标记「已安装」，每行显示图标——已安装的用其自身 bundle 的图标，未安装的复用本机任一 Xcode 的同一份 artwork（不把 Apple 的图打包进仓库），本机完全没有 Xcode 时回退为系统符号。可按版本号或构建号搜索、按渠道（全部 / 仅正式版 / 仅预发布）与安装状态筛选，并可隐藏 8 条 2005 年代的 Xcode Tools 包；可按版本或发布日期排序，两个方向都支持，版本号按数字逐段比较，避免字符串比较把 9.0 排在 26.3 前面。
- **版本浏览的四个入口**：主窗口左栏底部、状态栏菜单、详情页「版本与兼容」区，以及应用菜单 `⇧⌘V`。此前只有应用菜单里有这个入口，而菜单栏应用通常不是最前应用，实际上很难点到。
- **所选版本的版本与兼容详情栏**：显示构建号、发布日期、最低 macOS、架构、随附 SDK、编译器，以及发行说明与下载链接；选中的版本本机已安装时，并列显示 bundle 自身的平台版本、iPhoneOS SDK 构建、其声明的最低 macOS 与安装路径，便于与索引数据对照，并提供「在主窗口中显示」。
- **详情页的版本详细信息**：汇总版本、构建、发布日期与发行类型、最低 macOS、平台版本、iPhoneOS SDK 构建与安装路径，以及联网获取的随附 SDK 清单与 Swift / Clang 版本。
- **可拖动、可折叠的左右分栏**：主窗口与「所有 Xcode 版本」窗口的分隔条都能拖动；标题栏各有一个开关可一键折叠侧栏——主窗口折叠版本列表让详情占满整宽，「所有 Xcode 版本」折叠右侧详情栏。开关只用图标，文字放在悬停提示与无障碍标签里。

### 修复

- **显示的构建号取错了来源**：此前读 `Info.plist` 的 `CFBundleVersion`，26.3 得到 24587、27.2 得到 25400.27.8，都是 Apple 内部号；改为读 `version.plist` 的 `ProductBuildVersion`，与 `xcodebuild -version` 一致（17C529 / 27B5019j）。这也是版本索引匹配的前提——索引按公开发布构建号匹配，而同在 `Info.plist` 的 `DTXcodeBuild`（17C528）其实是 RC 2，用它匹配会把正式版误标为候选版。
- **同名构建号的版本可能被标错渠道**：`release(matchingBuild:)` 原先只比分布名，是否命中正式版取决于数据文件里的顺序；改为按 `release > gm > gmSeed > rc > beta > dp` 择优。真实数据里 60 个重复构建有 32 个渠道不一致（`17F113` 同时是 release 与 rc2）。
- **「所有 Xcode 版本」窗口曾以最小尺寸打开**：指定 `contentViewController` 后 AppKit 会采用视图的最小尺寸并静默忽略 `contentRect`，窗口实际开在 640x420 的下限而非预期尺寸；改为随后显式 `setContentSize`。
- **版本窗口的筛选控件被截断**：渠道 / 安装状态 / 排序三个 Picker 原先写死宽度，而菜单型 Picker 会把标题与选中值并排布局，导致「已安装」「未安装」被截断成省略号；改为按内容自适应，不再预先猜宽度。
- **打开「所有 Xcode 版本」窗口不再自动聚焦搜索框**：SwiftUI 会把新窗口里的第一个 TextField 设为第一响应者，于是窗口一打开搜索框就处于激活状态、第一次按键被当成搜索输入；现在与主窗口一致，打开时保持中性，点击才聚焦。

### 变更

- **详情页改为顶部分类切换**：右栏此前是单页长滚动，本机实测 80 行以上（Simulator 设备列表独占 27 行），看到底部内容需要长距离滚动；现在按「概览 / 环境 / 版本与兼容 / 模拟器 / 磁盘清理」分类，头部与切换器固定在滚动区之外，切换分类不必先滚回顶部，每类内容独立滚动。
- **排版改用语义化角色**：把「字体 + 字重 + 颜色」按信息角色（sectionTitle / itemTitle / fieldLabel / fieldValue / fieldValueStrong / note / identifier / warning / failure / success）一次定好，调用处不再各自挑字号。起因是改造前详情页约 90 处文字样式里有 67 处是 `.font(.caption)`，键、值、脚注完全同级，重要性只能靠颜色单独承担；路径、构建号、SDK 构建号与工具链版本改用等宽角色，便于逐字符比对。全部使用语义字体，系统的文字大小设置仍然生效。

## 1.5.1 - 2026-09-15

### 修复

- **Runtime 回收的预览会误报失败**：`simctl` 在选择器无匹配时退出码为 2，并把 `No matching images found to delete` 写到 stderr。此前一律按失败处理，于是预览「不可用」与「30 天未使用」会显示「检查失败」并标红——而这只是「没有可回收的镜像」这一正常结果（最近 30 天用过的机器本就没有符合条件者）。现在识别该标记并不再报错。
- **Runtime 回收每次只删一个**：`simctl runtime delete` 每次只接受一个标识符，传入多个会静默忽略其余（以 `--dry-run` 实测确认）。因此批量清理每次只删掉一个，用户需要反复点击，而且并不知道删掉的是哪一个。改为先解析出目标集合再逐个删除，一次完成，并在结果消息中列出被删 Runtime 的名称。
- **磁盘清理会列出占用为 0 的目录**：空缓存或内容不足 1 KB 的目录会被 `du -sk` 报成 0 B，列出它们等于宣称一份并不存在的可释放空间。现在不再显示。该目录仍在删除白名单内，下次扫描发现有内容时会照常出现。
- **CLI 补全脚本缺少 `clean` 子命令**：zsh / bash / fish 的补全此前各自维护一份子命令列表，新增 `clean` 时三处全部漏掉。改为统一由同一份列表生成，并新增测试防止再次漂移。

### 变更

- Runtime 回收的预览不再直接展示 `simctl` 的日志行（`Would delete P: <uuid> iOS (27.0 - 24A5380i) (Ready)`——裸 UUID 加 `P:` 标记、版本与构建挤在一起），改为解析回运行时的版本、构建与大小，并给出「将清理 N 个 Runtime，可回收约 X」的合计；无法解析的行仍原样保留，以免少报即将删除的内容。
- 清理的删除策略抽出为可注入的 `XcodeCleanupRemover`：实删、移入废纸篓、以及三类拒绝（家目录外、不在白名单、含符号链接祖先）现在都有测试覆盖。此前白名单与家目录在编译期写死，这条能销毁数据的路径完全无法测试。

## 1.5.0 - 2026-09-15

### 新增

- **Xcode 磁盘清理**：详情页新增清理区，覆盖 DerivedData、Products、DeviceLogs、文档缓存与索引、CoreSimulator 缓存、Developer/Packages、SwiftPM 缓存、Archives 子项与 iOS DeviceSupport 子项。按「可安全清理 / 需谨慎清理」分级，可一键在 Finder 中显示或重新扫描。
- **Simulator Runtime 回收**：列出每个运行时的占用大小与最近使用时间，可逐个删除；批量按 `--outdated`、`30 天未使用`、`--unusable` 处理。哪些镜像符合条件完全交给 `simctl` 判断，预览展示的就是它的 `--dry-run` 输出。
- **删除不可用模拟器设备**：这类设备不受当前 Xcode SDK 支持，无法启动或抹掉，此前只能不断堆积。
- **CLI 新增子命令**：`clean`、`sizes`、`pin`、`unpin`、`alias`、`unalias`、`workspace`、`unworkspace`、`completions`。`sizes` 分段列出各 Xcode 与各模拟器运行时的占用及合计，支持 `--json`。
- **切换前检测运行中的 Xcode**：会说明哪些 Xcode 正在运行以及切换会影响其工具链，并要求确认。

### 修复

- **脚本构建缺少本地化资源**：`build_app.sh` 过去只产出图标、没有 `lproj`，脚本路径构建的 app 是中文单语，所有译文被静默忽略；现在用 `xcstringstool compile` 编译 String Catalog 并复制进 `Resources`，与 Xcode 构建一致。
- **CLI 在符号链接下丢失译文**：Foundation 按调用路径决定 `Bundle.main`，经包管理器安装的符号链接会让 CLI 静默回退到源语言；改为按解析后的路径重新执行一次。
- **切换前未检测运行中的 Xcode**：`xcode-select --switch` 会改变正在运行的 Xcode 使用的工具链，可能干扰构建或调试。
- **清理类删除路径的安全性**：删除前必须同时满足「位于家目录内」「命中已知清理白名单」「路径不含符号链接组件」，且清理白名单由与界面同一个表派生，避免「界面能选、实际拒绝」的漂移。

### 变更

- 模拟器运行时大小改用 `simctl runtime list -j`：新运行时的 cryptex 镜像挂在 `/Library/Developer/CoreSimulator/Volumes`，不在 `Profiles/Runtimes` 下，旧扫描方式在新 Xcode 上找不到任何东西。
- `sizes` 改为并发测量并增量输出；清理扫描同样并发执行，并支持被新的扫描取代时真正中止。
- 需要谨慎清理的内容（归档、真机支持、包缓存）删除时移到废纸篓以便恢复；可自动重建的缓存仍直接删除。
- `clean` 默认只预览，需显式 `--force` 才执行，`--all` 才会一并处理 Xcode 无法重建的内容。
- String Catalog 同步脚本在 `xcstringstool sync` 之后把 JSON 归一化回仓库格式并排序键，同时报告真实键数（此前 `print | grep -c .` 会把 342 个键报成 367，并因 Xcode 版本差异产生整文件重排）。
- `@available` 依赖的界面判断抽成纯函数，使只在旧系统执行的样式分支可在任意机器上被测试覆盖。

## 1.4.1 - 2026-09-11

### 修复

- **修复会导致 app 无法启动的发布签名问题**：`xcodebuild archive` 路径产出的产物能通过 `codesign --verify --deep --strict`，却因 Library Validation 拒绝加载内嵌的 `Sparkle.framework`（`mapping process and mapped file (non-platform) have different Team IDs`）在启动时 `SIGABRT` —— 1.4.0 因此对任何用户都打不开。归档后改为按 `Scripts/sign_bundle.sh` 的顺序逐个重签组件即可修复。
- **发布脚本新增强制启动校验**：归档产物必须真正启动并存活，否则发布中止。此前版本号、内嵌 CLI 输出与签名校验全部通过，而 app 根本无法启动 —— 只做结构校验不足以把关。

### 变更

- Homebrew cask 的安装指引修正：去掉 Homebrew 6 已移除的 `--no-quarantine`，补充覆盖非 Homebrew 管理的 app 需要 `--force`。
- cask 的 CLI 由符号链接改为 `command_wrapper`：Foundation 按调用路径决定 `Bundle.main`，符号链接下 CLI 会丢掉 String Catalog 并静默回退中文。

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
