# 决定：不做 Xcode Cloud

日期：2026-09-21
状态：**已决定，不做**（与「索引内下载安装」「App Intents」同类：记录在案，不要每轮重新评估）

## 决定

「不做 Xcode Cloud」在这个仓库里有两层含义，**两层都不做**：

1. **应用不集成 Xcode Cloud**：不显示或管理 workflow，不查构建状态与历史。
2. **本仓库不把 CI 迁到 Xcode Cloud**：现有 GitHub Actions 流水线保持不变。

## 理由

### 一、应用集成

1. **没有可操作的对象。** Xcode Cloud 的对象是 App Store Connect 里的**应用记录**，操作它需要
   团队级的 App Store Connect API key。本项目明确不发布到 Mac App Store
   （`README.md` 的「正式发布（非 App Store）」一节），既没有也不打算有应用记录，因此没有可
   展示、可管理的东西。
2. **它与这个应用的产品面无关。** 应用管的是**本机**：发现、切换、诊断、清理 Xcode。CI 服务
   的构建历史是另一条产品线——要做就得再背一套构建列表、详情与日志界面，而日志与产物都在
   Apple 那一侧，本地无法闭环。
3. **签名与凭据前提同样不满足。** 产物是 ad-hoc 签名、未公证，见
   [2026-09-21-no-in-app-xcode-download.md](2026-09-21-no-in-app-xcode-download.md) 与
   [2026-09-21-no-app-intents.md](2026-09-21-no-app-intents.md) 里同样的结论。

### 二、把本仓库的 CI 迁到 Xcode Cloud

1. **现状是一条免费、可复现、零凭据依赖的路径。** `.github/workflows/ci.yml` 在 `macos-26` 上
   跑两个 job（Xcode 工程 + 脚本构建路径），门禁全部是仓库内脚本——String Catalog 的
   sync/verify、文案审计、`run_smoke_test.sh`；发布由推送 `v*` tag 触发
   （`.github/workflows/release.yml`），**不需要 App Store、Developer ID 或 Actions Secrets**
   （README 已写明）。
2. **Xcode Cloud 需要应用记录，且按计算时间计费。** 而它产出的构建产物不会自动变成 GitHub
   Release 上的 ZIP/DMG/SHA256SUMS——迁移等于把一条已验证的流水线换成一条要凭据、要付费、
   还要另想办法发布资产的流水线，换来的只是「跑在 Xcode Cloud 上」。
3. **仓库里从未有过 Xcode Cloud 的配置。** 没有 `ci_scripts/`（Xcode Cloud 的仓库侧钩子目录），
   也没有任何 Xcode Cloud workflow 定义。这不是「半途而废」，而是从未开始——记下来是为了省掉
   下一次「要不要试试」的讨论。

## 如果将来要重开

**应用集成**，按顺序满足：

1. 先有 App Store Connect 应用记录，以及 API key 的存储与**撤销**方案。
2. 只读展示（构建状态/最近一次结果）优先于任何触发、取消之类的动作。
3. 明确服务的是哪个场景：团队 CI 看板，还是本机版本管理里的一个角落。后者与本应用现有定位
   关系很弱，先想清楚再动手。

**迁移 CI**，先证明 Xcode Cloud 能顶上现有门禁，两条都做不到之前不值得讨论：

1. 能跑现有全部检查——catalog 的漂移检查依赖 `git status` 与仓库内脚本，文案审计依赖构建
   产出的 `.stringsdata`，smoke test 里还有打包启动。
2. 能把 ZIP/DMG/SHA256SUMS 发布到 GitHub Releases（或另有一条同样零凭据的发布路径）。

## 与既有文档的关系

`docs/superpowers/plans/2026-09-11-wwdc26-p0-p2-followups.md` 的「形态较大的新能力」一节把
**App Intents** 与 **Xcode Cloud** 并列为未动项。两份结论现在都有了：App Intents 见
[2026-09-21-no-app-intents.md](2026-09-21-no-app-intents.md)，本文件是 Xcode Cloud 的结论。
