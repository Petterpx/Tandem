# iOS 模拟器性能验证（2026-11-04）

环境：Apple Silicon、Xcode 27.1、iOS 27.0 / iPhone 18 Pro。测试使用独立模拟器和本地测试 App，用户正在试用的设备不作输入实验。

## 变化

- 去掉 100 ms JPEG 轮询、Base64 传帧与逐帧软件 JPEG 解码。原生 framebuffer 完成事件驱动采集，CoreImage 旋转缩放到独立 NV12 缓冲，VideoToolbox 硬件 H.264 编码，App 复用 Android 的 H.264 解码器。预览长边 1920，原分辨率高清截图不变。
- 视频用每会话独立 Unix socket，控制回复保持小型 JSON。最多 2 帧编码在途、1 个可替换采集请求；App 丢弃过时的已解码帧，不丢 H.264 依赖帧。
- 普通文字由会话内 guest AXRuntime 插入当前 first responder，不切换键盘语言、不操作菜单、不覆盖剪贴板。仅确认尚未尝试插入的密码框回退到系统粘贴；不确定是否生效的输入不自动重放。
- iOS 队列合并相邻文字与同来源的移动位置，保留 down/up、按键、显式粘贴、不同来源触点的边界。

## 测量方法

视频使用 60 Hz CADisplayLink 持续动画。统计真实 App 驱动解码后的到帧时间、像素变化及同一链路上的按键回复耗时，不把配置帧率或静止重复帧当作实测帧率。视频包时间戳始于编码输出，故“编码输出到解码”不包含采集/编码或桌面呈现延迟。

文字使用 UITextView / UITextField delegate 在实际内容变化时写入测试状态，与 host 发送时的单调时钟对比；区分每个新 App 的冷调用和连续热输入。密码框由 fixture 内部真实值确认，不以 helper 回复成功代替内容确认。

同一动画、设备暖机后的对比：

| 指标 | 旧 JPEG 链路 | 新 H.264 链路 |
| --- | ---: | ---: |
| 实际解码到达率 | 8.73 fps | 58.18 fps |
| 背景像素采样变化率 | 8.73 次/秒 | 56.05 次/秒 |
| 帧间隔 p50 / p95 | 114.31 / 126.53 ms | 18.23 / 31.26 ms |
| 视频传输期间 Enter 回复 p50 / p95 | 85.95 / 117.73 ms | 90.11 / 100.35 ms |

新链路在 12.238 秒内收到 712 个解码帧，尺寸 884×1920；编码输出到解码的 p50 / p95 为 3.37 / 7.77 ms。独立静态 IOSurface 首帧 116.64 ms，最后一次提交 15.13 ms，未因 1 帧编码流水线滞留。Enter 的约 80 ms 固有 HID 时序未改变，不能将回复耗时当成文字延迟或画面呈现延迟。

最终打包的 App 内置 helper 又独立验收一次：12.306 秒收到 683 帧，**55.50 fps**，真实背景变化 **53.39 次/秒**；帧间隔 p50 / p95 为 15.49 / 34.85 ms，编码输出到解码 p95 11.37 ms。多个实测区间约 **55–60 fps**，不把单次最高值当作所有负载下的保证。此构建的热 ASCII 实际变化/回复中位为 **7.27 / 12.45 ms**，热中文/emoji 为 **13.26 / 18.94 ms**，冷首字约 **315–335 ms**，密码框回复约 **3.11 秒**。

普通文字在完整 host → guest → UIKit 链路中，连续 ASCII 实际变化中位 7.32 ms（最大 18.64 ms）、回复中位 12.15 ms；热中文/emoji 实际变化中位 14.05 ms、回复约 20.69 ms。每个新 App 的首次输入约 0.3–0.4 秒。密码框回退实际插入约 2.81 秒、回复约 3.33 秒。旧 helper 在同一 fixture 上实际插入为 2.60–2.75 秒、回复为 3.06–3.22 秒。WKWebView textarea 的中文、emoji、换行及 JavaScript `input` 事件也已实测。详细分组、样本量与退出链见 [文字性能报告](ios-text-input-performance.md)。

原生库 `SimulatorVideoStream` 的固定编码策略强制 `MaxFrameDelayCount=0`，实测约 35–37 fps，降至 1280 仍约 38 fps；因此替换其编码调度，没有以降低清晰度作为最终方案。IOSurface seed 在 CoreImage 读取时也会变化，不能据此推断撕裂并丢弃静止帧；异步编码只引用自己持有的 NV12 快照。

## 回归与清理

- App：543 项测试、62 suites 通过。
- TandemCore：全量通过；报告汇总 414 项，未配置设备的原生集成测试默认跳过。
- helper：18 项 XCTest 与 2 项真实视频/传输 Swift Testing 测试通过。
- 输入队列先复现 1000 个旧 move 积压，再验证只发送最新位置与释放事件；输入边界与代际取消顺序保持。
- 独立审阅发现并修复 framebuffer 结束后输出旧画面、旋转过渡清空 geometry、正常 VT 掉帧错误断连。真实 socket EOF、未 accept 时关闭、已连接时关闭、目录清理与慢消费者断流均有测试。
- 普通文本覆盖 UITextView、UITextField、选区替换、中文、emoji、换行及连续 ASCII；拒绝编辑时返回明确错误并保留会话，未自动重放。
- guest 原 AX 状态为开启/关闭两种情况下，quit、EOF、SIGTERM 恢复均已真实验证；完整 host → simctl → guest 的 quit、EOF、SIGTERM、SIGKILL × 两种原 AX 状态共 8/8 通过，guest PID 全部消失且原 AX 状态恢复。
- UIKit 真实横竖屏切换 4 次，解码尺寸在 1920×884 与 884×1920 间正确交替，同轮 59.69 fps、0 编码错误。真实关机未发送 framebuffer `.ended`，因此另加 250 ms 的设备状态检查，已验证关机后 helper 明确失败退出，不继续显示缓存画面。
- 最终 App 构建与 `codesign --verify --deep --strict` 通过；App 内置 helper 的真实帧/高清截图/停止、完整文字 fixture、smoke（剪贴板往返、输入确认、触点所有权、quit/EOF/SIGTERM）全部通过。
- 验收完成后已关闭并删除本轮创建的两台专用测试模拟器，没有 helper/guest 残留。用户的 iPhone 18 Pro 保持运行。
- 静态延迟测试的常规回归约束为 1 秒内交付，以免冷硬件/并行编译负载造成时序误报；`TANDEM_STATIC_LATENCY=1` 另执行 200 ms 严格性能验收，最终首帧 134.02 ms、尾帧 12.68 ms。

## 运行入口

```sh
swift test --package-path Packages/TandemCore
swift test --package-path Packages/SimulatorHelper
xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tandem-ios-perf"
```

原生性能测试仅在显式设置 `TANDEM_VIDEO_BENCHMARK=1`、`TANDEM_TEST_SIMULATOR` 和 `TANDEM_SIMULATOR_HELPER` 时运行。必须指定正在显示连续动画的专用设备；它会发送 Enter。

视频、文字 fixture 与输入/退出测试位于 [Integration](../../../Packages/SimulatorHelper/Tests/Integration/README.md)；smoke 位于 `Packages/SimulatorHelper/Tests/Smoke/`。这些脚本明确指定 UUID，不使用 `booted` 隐式选择用户设备。

## 边界

- 密码框仍使用系统编辑菜单，延迟明显高于普通文字；显式剪贴板写入仍有系统命令行调用成本。
- 每个新打开 App 的首次 AX 查询有冷启动成本，不能用连续热输入数字代表首字。
- Computer Use 桌面采集仍受 ScreenCaptureKit 错误影响；性能验收基于真实模拟器、解码帧和输入事件，不能代表已完成桌面布局实拍或端到端光学延迟测量。
- 本轮未验证与 Device Hub 同时显示、Flutter、自定义输入控件及全部 Xcode/iOS 版本；未新增 iOS 真机能力。
