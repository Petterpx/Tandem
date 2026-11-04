# iOS 模拟器验证（2026-11-03）

> 本文保留首次接入的验收记录。11 月 4 日已替换视频和文字链路；当前性能与验证结果见 [性能报告](ios-simulator-performance.md)。

环境：Apple Silicon，Xcode 27.1，iOS 27.0 / iPhone 18 Pro。全部原生测试使用 headless 模拟器，不需要常驻网络服务。

已验证：

- 模拟器枚举、运行时过滤、启动与 bootstatus 命令路径。
- 原生 helper 画面进入 IOSSimulatorSession，解码为 IOSurface-backed CVPixelBuffer；退出后旧帧与 activeSerial 清空。
- 原分辨率 PNG 截图。Xcode 27.1 实测 `screenshot -` 写成名为 `-` 的文件，现改用唯一临时文件读回并校验，所有路径清理临时目录。
- HID Home、触摸 down/move/up；300 ms 采样滑动的 RPC 总耗时 0.474 秒，截图确认由主屏进入 App 资料库；不同输入来源不能释放对方触点。
- 剪贴板中文/emoji 往返；原生菜单将整段中文、emoji 和换行插入测试 UITextView；Enter/Delete 在硬件键盘关闭时生效。
- 静止画面开始录屏也可生成有时长的视频；无任何画面时仍明确报错。
- MCP 未支持按键、无 UI 树的文字定位、后端错误、取消长按和已取消操作正确回报/清理。
- iOS 积压文字合批、跨按键/触摸/粘贴的边界与多代消费者取消顺序。
- 同用户多模拟器粘贴采用跨进程锁；锁竞争、取消、0600 权限与符号链接拒绝均有测试覆盖。
- 驱动去重快照，避免轮询绕过 Android 失败重试限制；旧进程、旧请求和旧手势与新一轮隔离。

最终验证：App 541 项测试（62 suites）通过；TandemCore 全量通过（报告汇总 409 项，未配置设备的集成测试默认跳过）；helper 12 项测试通过。最终 App 构建及 `codesign --verify --deep --strict` 通过，另使用 App 内置 helper 运行真实模拟器集成测试，1 项通过。测试输入 App 已卸载，键盘与语言设置已恢复，保留本轮 iPhone 18 Pro 模拟器运行以供试用。

验证入口：

```sh
swift test --package-path Packages/TandemCore
swift test --package-path Packages/SimulatorHelper
xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tandem-ios-test"
# 原生只读链路：环境变量见 README
swift test --package-path Packages/TandemCore --filter IOSSimulatorLiveTests
```

待人工确认的边界：

- 桌面窗口实拍：本轮 Computer Use 的 ScreenCaptureKit 报采集错误，无法用桌面截图确认新选择器布局；App 编译和视图测试已通过。
- 同一设备已由 Device Hub 显示时的长期并存、其他 Xcode/iOS 版本及 Intel/macOS 14 上仅 Android 的实际运行。
- 模拟器旋转操作、CoreDevice 已接管剪贴板时的分支。
- 自定义输入控件、系统粘贴许可弹窗、中文/英文以外的系统编辑菜单。无法确认菜单时明确失败，不自动重试粘贴。

本轮不支持 iOS 真机、UI 树/按文字点按、模拟器应用管理、文件与日志等未声明能力。预览最多 10 fps；文字粘贴每批数秒。
