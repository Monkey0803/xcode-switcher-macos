# 决定：不做 App Intents / Shortcuts

日期：2026-09-21
状态：**已决定，不做**（与「索引内下载安装」同类：记录在案，不要每轮重新评估）

## 决定

不为应用实现 App Intents、App Shortcuts 或任何面向 Shortcuts/Siri/Spotlight 的意图接口。
现有自动化路径保持不变：

- 菜单栏菜单与应用菜单里的全部动作（激活版本、按项目打开、打开终端、清理……）。
- 内置 `xcodeswitcher` CLI：`use` / `open` / `pin` / `workspace` / `doctor` / `sizes` / `clean`
  等，设置页的「Shell 集成」提供把它链接到 `PATH` 的命令。
- 因此想要 Shortcuts 自动化的用户，可以用 Shortcuts 自带的「运行 Shell 脚本」调用
  `xcodeswitcher use|open …`，不必等应用内建意图。

## 理由

1. **前置不是「改个标识符」那么小。** `XcodeInstallation.id` 现在是 `appURL.path`
   （`Sources/XcodeSwitcherKit/Models.swift:55`），是 per-device 值，不能作为 App Entity 的
   标识。换成跨设备稳定标识意味着：为每个安装引入稳定 ID，并给出迁移策略——同一台机器上
   同一个 Xcode 被移动/重命名/重装时如何判定「还是它」、两个路径指向同一 bundle 时如何去重。
   所有以安装 ID 为键的持久化数据都会受影响（收藏、项目绑定、快捷键无关但切换历史相关，
   都在 `AppConfiguration` 里）。这是一次数据结构改造，不是附加功能。
2. **场景价值被 CLI 覆盖。** 意图能表达的动作基本是「切到某个版本」与「用某个版本打开某个
   项目」，两者 CLI 已有且更灵活（能被任何脚本、CI、Shortcuts 的 shell 动作调用）。剩下
   只有「用自然语言问当前版本」这类只读查询，价值不足以支撑第 1 条的改造。
3. **维护面会扩大构建矩阵。** App Intents 带来实体/意图的元数据生成与
   `AppShortcuts` 本地化，且 API 面随系统版本演进。本仓库的构建已经被 SDK 27 的 `@State`
   宏（Homebrew 沙箱）与 SwiftPM/脚本路径在 Xcode 27 下的失败折腾过（见 `AGENTS.md`），
   再引入一个只在特定系统版本可用的框架，会让「三条构建路径都要能用」这条既有约束更难守。
4. **与本项目的分发形态不匹配，且无法验证。** 应用是 ad-hoc 签名、未经公证、明确不上架
   App Store（见 `README.md` 的分发一节与 `2026-09-21-no-in-app-xcode-download.md` 的理由 4）。
   意图的主要入口由系统与 Shortcuts 应用提供，对这类构建是否可见、能否被索引，在缺少
   Developer ID/公证的前提下无法端到端验证——本仓库对「无法验证的能力」一贯是不做
   （同提权迁移的结论）。

## 如果将来要重开

按顺序满足以下条件，再谈实现：

1. 先落地稳定标识：`XcodeInstallation.id` 换成跨设备稳定值，并写清 `AppConfiguration`
   的迁移与去重规则；这一步本身可以独立提交、独立验收，与本决定解耦。
2. 明确暴露哪些动作。只读查询（列出安装、当前版本、项目推荐版本）比有副作用的切换更适合
   作为意图，后者应继续走 CLI 或菜单。
3. 有可验证的分发与签名形态，否则做出来也无法确认系统真的能发现这些意图。
4. 以「当前 Xcode」这一个只读意图做最小试点，确认可回退、可测试，再考虑铺开。

## 与既有文档的关系

`docs/superpowers/plans/2026-09-11-wwdc26-p0-p2-followups.md` 的「形态较大的新能力」一节把
App Intents 与 Xcode Cloud 列为未动项，前置约束写在同处。本决定是其中 App Intents 一项的
结论；Xcode Cloud 仍未定，不在此文范围内。
