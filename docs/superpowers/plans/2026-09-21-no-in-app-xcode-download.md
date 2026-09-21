# 决定：不提供索引内直接下载安装 Xcode

日期：2026-09-21
状态：**已决定，不做**（同 App Intents 与提权迁移，属「明确不做」而非待办）

## 决定

应用不实现「从版本索引里直接下载并安装 Xcode」这一路径。现状保留：

- 「所有 Xcode 版本」窗口的「下载」打开 Apple 开发者下载页（`release.downloadsPageURL`）。
- 「复制直链」把索引里的 `.xip` 地址放进剪贴板，供下载管理器或脚本使用。
- 下载成功后由用户自行挂载/展开 `.xip` 并把 `Xcode.app` 放进 `/Applications`，应用在下次刷新时发现它。

代码事实见 `Sources/XcodeSwitcher/AllVersionsView.swift` 中 `DownloadLink` 的注释与
`Sources/XcodeSwitcher/XcodeReleaseInfo.swift` 的 `downloadsPageURL` / `downloadURL`。

## 理由

1. **它不是「再多一个按钮」，而是一条认证链路。** 直链 `.xip` 需要已登录的开发者会话
   cookie；未登录时 Apple 会 302 到 `/unauthorized/`——这正是当初把「下载」改成打开
   下载页、而不是直接给直链的原因（`AllVersionsView.swift:292` 的注释）。要在应用内下载，
   先得让用户把 Apple ID 凭据交给应用，并处理会话失效、双因子、条款接受等问题。
2. **下载本身是数 GB 级、可中断的工程。** 需要断点续传、磁盘空间预检、SHA-256 校验、
   `xip --expand` 的空间与时间估算、进度与取消，以及失败后的残留清理。这些都不是
   `URLSession.download` 一行能覆盖的。
3. **安装动作会与既有能力重叠且更危险。** 应用已经能发现、切换、诊断和清理 Xcode；把
   「安装/替换 `/Applications/Xcode.app`」纳入进来，等于让它写一个用户可能正在使用的
   应用包，还要处理旧版本共存、`xcode-select` 指向与 Gatekeeper。收益与风险不成比例。
4. **本项目的分发前提是 ad-hoc 签名。** 一个把自己伪装成 Apple 下载流程、却由 ad-hoc
   签名的应用去索取 Apple ID 凭据，在信任上很难站得住，且没有公证路径可依托。
5. **已有替代路径足够好。** `xcodes` CLI、XcodesApp 以及 Apple 自己的下载页都做这件事；
   本应用把索引、兼容性判断和安装后管理做好即可，不必重复造认证与下载的轮子。

## 如果将来要重开

先满足以下前置条件，再谈实现：

- 有正式签名与公证的分发路径（`build_release.sh` 目前可用但没有 `Developer ID
  Application` 证书与公证凭据），否则不应引入凭据处理。
- 明确认证方案：由用户提供 Apple ID 会话、或改为引导用户在浏览器登录后导入 cookie；
  两者都需要安全存储与「如何撤销」的设计。
- 先补下载器的可测试边界（下载源、校验器、展开器都作为注入点），参照
  `XcodeCleanupRemover` 的做法——那条能销毁数据的路径就是因为抽成协议才被测试覆盖的。

## 与既有文档的关系

`docs/superpowers/plans/2026-09-11-wwdc26-p0-p2-followups.md` 的「后续项」一节列出了
当时未实施的能力。本决定是新增的一条，且结论是「不做」，记录在此以免每轮评估都重新讨论。
