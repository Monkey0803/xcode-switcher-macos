# 决定：移除守卫要读项目里的 `.xcode-switcher.json`

日期：2026-09-28
状态：**已实施**（2026-09-28，方案未偏离）

## 决定

`XcodeRemoval` 的 `boundProjects` 拒因，以前只看 App 全局项目列表里的 `xcodeID`。从现在起它还要看
**App 已知项目自带的本地绑定文件**：项目列表里的项目，以及项目扫描目录下发现的项目。

判定与拒因的具体形状：

1. **候选项目的来源**是两个集合的并集——`AppConfiguration.projects` 里已经登记的项目，加上
   `AppConfiguration.projectSearchPaths` 下由现有 `ProjectDirectoryScanner.scan` 发现的项目。
2. **本地文件里的 `xcode` 值交给 `XcodeSelector.resolve` 解析**（它已经支持版本、别名、app 路径、
   developer 路径与安装 ID，正是 README 承诺的四种写法）。解析结果是「就是本安装」算绑定；
   解析结果是**歧义**但候选里含本安装，也算绑定——判不出是哪一台时两台都不许移除，与 2.2.2
   在命令行上的规则同源。
3. **拒因带上来源**：`XcodeRemovalRefusal.boundProjects` 的载荷从 `[String]` 改为
   `[XcodeRemovalBinding]`（项目名 + 来源）。理由是两个来源该采取的动作不同：App 内绑定去
   「项目」页改绑，仓库里的文件要改那个文件。现在这条消息只会说「请在「项目」页把它们改绑」。

## 现状与问题

README 第 212 行把本地文件写成受支持的团队用法：

> 项目也可以在仓库中保存 `.xcode-switcher.json`，其中 `xcode` 支持版本、别名、Xcode 路径或安装 ID；
> 它的优先级高于 App 内绑定和 `.xcode-version` / `.tool-versions`

而移除守卫读的是另一处：

- `Sources/XcodeSwitcher/InstallationStore.swift` 与 `SourcesCLI/CLIEntryPoint.swift` 都把
  `boundProjectNames` 从 `configuration.projects[].xcodeID` 取出来；
- `ProjectStore` 只在**解析用哪个 Xcode 打开项目**时读本地文件（`ProjectLocalConfigurationStore`）。

于是「项目绑定着它」这条承诺有个缺口：**仓库里自带绑定的项目，即使已经被 App 登记甚至扫描进来，
守卫也看不见**——扫描进来的 `ProjectProfile` 不携带 `xcodeID`，而本地文件从不参与移除判定。
同事克隆一个带 `.xcode-switcher.json` 的仓库后，`uninstall` 会照移。这与 2.2.1 修的
`pin` 缺口是同一类的另一面（那次修的是 `pin` 自己写的文件，`pin` 现在会同时登记全局列表）。

## 成本与边界

| 来源 | 读法 | 成本 |
| --- | --- | --- |
| `configuration.projects` | 逐个项目读一个小 JSON | O(项目数) 次小文件读，量级是个位数到几十，渲染路径可直接用 |
| `projectSearchPaths` | 沿用 `ProjectDirectoryScanner.scan` | 一次目录遍历；已有跳过规则（`Pods`/`Carthage`/`DerivedData`/`node_modules`、隐藏项、包内容、符号链接、发现项目后不再下探） |

因此扫描**按需且缓存**：在磁盘清理区显示该安装时算一次，刷新时失效——与
`DiskCleanupStore.installationSizesByID` 完全相同的模式（那条路已经证明了这个位置可以承担一次
有界 I/O）。扫描只读，不写任何文件；`projectSearchPaths` 为空时退化为「只读已登记项目」。

## 被否决的备选

- **只让 CLI `pin` 登记全局列表**（2.2.1 已做）：覆盖不到仓库里自带的、以及手工写的本地文件。
- **扫描时把本地绑定同步进 `projects[].xcodeID`**：会把「仓库里的决定」静默变成「本机的决定」，
  文件改了也不同步，而且等于替用户改配置。
- **让守卫遍历整个磁盘找 `.xcode-switcher.json`**：成本不可控，且与「用户在设置里指了哪些
  目录」这一既有约定相悖。

## 验收方式

1. Kit 单元测试：用临时目录造出「仓库布局」，覆盖本地绑定命中本安装、命中别的安装、歧义写法、
   文件损坏、扫描目录为空等情形。
2. CLI 契约 E2E：往临时项目写一个 `.xcode-switcher.json`（不经过 `pin`），`uninstall --dry-run`
   必须拒绝并列出该项目的名字；删掉文件后又能预演。
3. 真机复验：用**已发布**的产物对真实 Xcode 跑一次预演，确认仓库自带的绑定真的拦得住。
