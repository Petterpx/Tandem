# iOS 模拟器控制

## 目标与范围

将本机 iOS 模拟器接入现有工作台，让鼠标、键盘和 MCP 使用同一设备会话。用户已确认这个范围。本轮实现运行中设备发现、启动入口、画面、坐标点击/长按/滑动、受支持的键盘按键、英文及中文输入、剪贴板、截图、沿用画面录屏和打开链接。

iOS 真机沿用后续 P4 计划。本轮不宣称模拟器支持 UI 树、Android 网络/开发者设置、文件传输、日志或完整应用管理；MCP 按真实能力暴露工具。文字/元素点击需明确提示改用坐标。

## 技术选择

- 保留 App 与 TandemCore 的 macOS 14 最低版本；模拟器交互后端限定 Apple Silicon、macOS 15+ 和已安装 Xcode。
- `IOSSimulatorDriver` 实现现有 DeviceDriver / DeviceSession / DeviceActions。simctl 负责枚举、启动、原分辨率截图和 URL；通用进程执行器移入 DeviceCore 复用。
- 单独 Swift Package 构建 `tandem-simulator` 子进程，固定依赖 Meta idb 的 FBSimulatorControl 1.7.7。与主 App 通过标准输入/输出通信，不新增监听端口或常驻服务。
- 使用原生 framebuffer 和 HID，避免依赖 Simulator 窗口的位置与焦点。helper 为每个已投屏的 UDID 单独启动；停止投屏结束 helper，保留模拟器本身运行。
- 文字通过 Application HID 键打开焦点处原生编辑菜单，helper 内部使用 FBSimulatorAX 定位经验证的系统粘贴项；不修改硬件键盘或输入法设置。文本及粘贴请求预算 25 秒，排在它后面的命令继承长预算；普通请求 5 秒。helper 之间通过同用户文件锁串行化剪贴板写入与粘贴，防止多模拟器互相覆盖文本。
- iOS 输入泵合并积压的相邻已提交文字，按键/触摸/显式粘贴保持顺序边界；Android 原输入通道保持不变。
- 预览帧采用最多 10 fps 的 JPEG 传输，主进程解码为有 IOSurface 的 CVPixelBuffer；高清截图使用 simctl PNG。它是可操作的首版预览，不承诺 Android 的视频流帧率。
- 不把 Android 初始化失败当作全局退出条件。缺少 Xcode/helper 时给出明确说明，Android 可独立使用。

## IPC v1

helper 参数：`--udid <UUID>`。stdin/stdout 均为逐行 JSON；日志只写 stderr。每行上限 32 MiB。

请求字段：`id`（整数）、`command`；响应为 `{"id":1,"ok":true}`，或 `{"id":1,"ok":false,"code":"UNSUPPORTED","error":"原因"}`。读取剪贴板的成功响应另含 `text`。

| command | 字段 | 行为 |
|---|---|---|
| touch | phase: down/move/up, x/y: 0…1, pointer: finger/ai | 有序持续触摸；另一来源占用时明确拒绝，不能释放它的触点 |
| key | key: DeviceKey.rawValue | home/enter/delete/forwardDelete/tab/up/down/left/right |
| text | text | 向焦点输入文字，包括 Unicode |
| clipboard_get | | 返回 text |
| clipboard_set | text, paste: Bool | 只写或写入并粘贴 |
| quit | | 释放触点并退出 |

主动事件：`{"event":"ready"}`；`{"event":"frame","jpeg":"base64","width":W,"height":H}`；不可恢复失败 `{"event":"error","code":"CONNECTION_FAILED","error":"原因"}`。

只有第一帧解码成功后会话才变为 running。IPC 失败、EOF、超时和停止必须完成等待中的请求、清掉旧帧；重连不能接受旧进程的帧。新增 DeviceSession.sendChecked，以默认实现兼容 Android，模拟器覆盖为有确认/错误的输入路径，MCP 使用它防止误报成功。

## 验证

核心测试覆盖运行时过滤、设备状态、参数安全、IPC 分包/错误/EOF、会话生命周期、帧与坐标。App 测试覆盖独立驱动启动、模拟器标签、按键支持、MCP 能力边界与错误传播。实际模拟器验证首帧、Home、点按/拖动、英文中文输入、剪贴板与截图；既有 Android/Core 和 App 测试回归。

## 来源

- [FBSimulatorControl 官方说明](https://github.com/facebook/idb/blob/main/FBSimulatorControl/README.md)
- [固定版本依赖清单](https://github.com/facebook/homebrew-fb/blob/v1.7.7/Package.swift)
