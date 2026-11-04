# iOS Simulator Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; independent coding subtasks use Sol as required by AGENTS.md. Track completion below.

**Goal:** 在现有工作台与 MCP 中控制本机 iOS 模拟器。

**Architecture:** DeviceCore 保留跨平台协议，新增 IOSSimulatorDriver，原生控制隔离在 bundled helper 中。Android 和模拟器独立初始化，能力驱动 UI 与 MCP。

**Tech Stack:** Swift 6、SwiftUI/AppKit、simctl、FBSimulatorControl 1.7.7、stdio JSON。

**Spec:** ../specs/2026-11-03-ios-simulator-design.md

## Global Constraints

- App / TandemCore macOS 14；helper Apple Silicon / macOS 15+。
- 不引入本地端口服务；不记录用户输入文字或剪贴板正文。
- 不支持的能力必须明确拒绝，不可返回成功。
- 本轮不提交 Git；保留可审阅变更。

## Review Focus

- ADB 或 Xcode 缺失时，另一平台继续工作。
- helper 退出/重启后旧帧和请求不会污染新会话。
- 非 ASCII 输入与键盘按键确实到达模拟器。
- 人工和 AI 触控不会相互抬起对方触点。
- 旋转、坐标单位和 IPC 分包不造成偏移或假成功。

### Task 1: 平台显示与按键支持

- [x] DeviceInfo / InputAction 增加 simulator 与 isSupported(on:)；KeyMapping、工作台/弹窗导航过滤；连接文案统一。
- [x] 按键/展示回归测试先失败后通过；确认 Android 行为保留。

### Task 2: 原生 helper

- [x] 单独 package 固定 idb 依赖，按 spec 的 IPC v1 实现 native frame/HID/clipboard/text。
- [x] 真实模拟器验证 frame、touch、Home、Unicode；提供构建打包脚本与依赖许可证。

### Task 3: IOSSimulatorDriver

- [x] 通过共享 ProcessRunner 实现 simctl 枚举/boot/screenshot/openURL。
- [x] helper IPC、JPEG 帧转换、会话生命周期和 sendChecked；用替身进程/协议测试失败与取消。
- [x] 驱动只发布真实能力；仅枚举已 boot 的 iOS 设备。

### Task 4: App 与 MCP 集成

- [x] AppModel 独立初始化驱动；提供启动模拟器入口。
- [x] MCP 输入使用 checked 路径；不支持键/元素操作有清晰失败。
- [x] Xcode 构建复制 helper 及依赖，README/QA 更新。

### Task 5: 完整验证

- [x] swift test；xcodebuild test；实际模拟器端到端检查。
- [x] 独立代码审阅；修复实质问题后复测，记录未验证边界。
