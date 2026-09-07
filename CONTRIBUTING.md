# 贡献指南

感谢参与 Xcode Switcher。项目面向 macOS 13.0 及以上，当前采用直接分发方式，不依赖 App Store。

## 开始开发

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./run_smoke_test.sh
```

涉及 UI 或系统授权的改动，请在真实 macOS 环境验证窗口、菜单栏、辅助功能授权和 `xcode-select` 切换流程。不要在测试中提交管理员密码、签名私钥、AppKey 或其他凭据。

## 提交变更

- 一个提交尽量只包含一个逻辑变更。
- 新增行为应同时补充单元测试或可重复的 Smoke Test。
- 不要提交 `build/`、`release/`、证书、Provisioning Profile 或私钥。
- 发布版本由维护者在版本号、构建产物和校验文件完成核对后推送标签。

## 报告问题

请使用 Issue 模板，并提供 macOS、芯片、Xcode Switcher 版本和可脱敏的环境诊断信息。
