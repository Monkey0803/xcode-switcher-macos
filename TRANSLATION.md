# Translation guide

Guidance for translating the String Catalog (`Resources/Localizable.xcstrings`).
`AGENTS.md` references this file so the extra context is only read for
translation tasks — the same arrangement recommended by WWDC 2026 session 213
(“Translate your app using agents in Xcode”).

## Source and targets

- Source language: **zh-Hans** (the key *is* the Simplified Chinese string).
- Current target: **en** (English).

## Audience and tone

A macOS menu bar utility for developers who juggle several Xcode installations.
Write the way Apple writes its own English macOS UI:

- Buttons and menu items: imperative, sentence case, no trailing period
  （「重新扫描」→ “Rescan”, 「设为系统默认 Xcode」→ “Make Default Xcode”).
- Status messages and captions: full sentence with a period, present tense.
- Prefer the term macOS itself uses in English (System Settings, Accessibility,
  Keychain Access, Launch at login, Developer directory).
- Keep it short. These strings sit in a 900 pt window; long English wording
  truncates where the Chinese did not.

## Do not translate

Product names, trademarks, shell tokens, paths and identifiers stay verbatim:

`Xcode`, `Xcode Switcher`, `Sparkle`, `DEVELOPER_DIR`, `xcode-select`,
`xcodebuild`, `simctl`, `CoreSimulator`, `Rosetta 2`, `Simulator`, `Runtime`,
`Keychain`, `Provisioning Profile`, `Scheme`, `Configuration`, `Finder`,
`Command Line Tools`, `iPhoneOS SDK`, `GitHub Releases`, `CLI`, `PATH`, `zsh`,
`.xcodeproj`, `.xcworkspace`, `.xcode-version`, `.tool-versions`,
`.xcode-switcher.json`, `.cer`, and the `~/Library/...` paths.

Keys that are already ASCII and consist only of such terms need **no**
localization; leave them out of the catalog so the source value is used.

## Glossary

| zh-Hans | en |
| --- | --- |
| 开发者目录 | developer directory |
| 系统级切换 | system-wide switch |
| 设为系统默认 | make default / set as system default |
| 激活 / 已激活 / 当前激活 | activate / Active / Currently active |
| 管理员授权 | administrator authorization |
| 辅助功能 | Accessibility |
| 钥匙串 | Keychain |
| 签名 / 签名配置 | signing / signing settings |
| 证书 / 公钥证书 | certificate / public certificate |
| 项目绑定 | project binding |
| 收藏 / 取消收藏 | favorite / unfavorite |
| 别名 | alias |
| 环境体检 | environment check |
| 环境诊断 | environment diagnostics |
| 脱敏报告 | redacted report |
| 扫描 / 重新扫描 | scan / rescan |
| 刷新 | refresh |
| 回滚 | roll back |
| 抹掉 | erase |
| 启动（模拟器） | boot |
| 登录时启动 | launch at login |
| 仅在菜单栏运行 | menu bar only |
| 快捷键 / 全局快捷键 | shortcut / global shortcut |
| 录制（快捷键） | record |
| 搜索目录 | search folder |
| 运行时 | runtime |
| 设备 | device |
| 可用 / 不可用 | Available / Unavailable |
| 有效 / 无效 | Valid / Invalid |
| 已过期 / 到期 | Expired / Expires |
| Shell 集成 | Shell integration |
| 不改系统设置 | without changing system settings |
| 注入 | inject |
| 失效项目 | missing project |
| 自动匹配 | automatic match |
| 依据 | Based on |

## Rules

1. **Placeholders are positional and must survive verbatim.** Keep every
   `%@`, `%lld`, `%d` and keep the same count, in an order that reads naturally
   in English (reordering is allowed; dropping or adding one is not).
2. Multi-line keys keep their `\n` line breaks.
3. Match the source's trailing punctuation: a Chinese 「。」 becomes a period,
   a 「…」 becomes an ellipsis.
4. Use “…” (U+2026) rather than three periods, matching the source.
5. Run `Scripts/verify_string_catalog.sh` after editing; it checks placeholder
   parity and that every catalog entry is either translated or intentionally
   left to the source language.
