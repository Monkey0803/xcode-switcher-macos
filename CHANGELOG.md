# Changelog

## 1.1.1 - 2026-09-07

稳定性和开发效率增强：

- GitHub Release 检查的 User-Agent 现在从应用版本动态生成，避免发布版本与请求标识不一致。
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
