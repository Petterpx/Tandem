# iOS Simulator Performance Implementation Plan

> **For agentic workers:** Use systematic-debugging and executing-plans; independent native coding tasks use Sol. Keep changes uncommitted for local evaluation.

**Goal:** 将模拟器从 10 fps / 数秒文字输入改为接近 Android 的低延迟控制，使用真实模拟器测量结果验收。

**Architecture:** 原生 framebuffer 完成事件驱动采集，CoreImage 一次旋转/缩放到独立 NV12 缓冲，再由 VideoToolbox H.264 硬件编码，预览长边 1920。编码最多 2 帧在途和 1 个可替换待采集请求，独立视频 IPC 和硬件解码；控制继续使用逐条确认的 JSON。文字由会话内 guest 进程通过 AXRuntime 向当前 first responder 注入 Unicode，避免每次菜单粘贴；保留正确 Unicode/选区语义，退出恢复本会话改变的 AX 状态。

**Tech Stack:** Swift 6、FBSimulatorControl 1.7.7、VideoToolbox、Unix IPC、AppKit。

**Spec:** 用户 2026-11-04 要求提高投屏帧率、降低文字输入延迟，达到 Android 的交互水平；延续 2026-11-03-ios-simulator-design.md 的平台边界。

## Constraints / Review Focus

- App macOS 14；模拟器 helper Apple Silicon / macOS 15+，不增加常驻端口服务。
- 不修改用户当前模拟器的键盘、语言或内容；原生实验使用独立测试设备。
- 视频不能积压导致输入延迟；慢消费者、退出、重连和旋转都要有界并隔离旧帧。
- 文本必须实际落入输入框；不能以 HID/RPC 成功冒充文字插入成功。
- 保留 Unicode、emoji、换行、选区替换与按键/触摸/粘贴的顺序。
- 验证动画期间收到并解码的帧率；区分配置目标、静止画面不产帧和实测结果。

## Tasks

- [x] 视频：保存旧 helper 基准；真实连续动画记录实际帧率；接入 H.264 硬件编码 + 独立私有视频 socket，复用硬件 decoder；协议分包、关闭和跨代隔离测试。原生库强制逐帧等待的策略实测约 35 fps，降分辨率也仅 38 fps；自有有界 VT pipeline 实测 55–60 fps，静止首尾帧、旋转和最终 App 内置 helper 集成通过。
- [x] 文字：定位进程启动、剪贴板、AX 与固定等待耗时；验证原生 Unicode 注入路径；实测连续文字、中文/emoji/换行和选区替换，保留有意义的失败。
- [x] 输入队列：先测试复现慢发送时历史 move 积压；只合并相邻同来源 move，保留 down/up 与输入边界；文本合批不积累重复唤醒消息。隔离运行真实源码 9 项测试通过，独立审阅未发现问题；最终 App 测试仍需覆盖。
- [x] 集成：回归 App / TandemCore / helper，独立代码审阅；最终打包后原生测量、严格签名检查，更新 README / QA 并提供本地测试版。
