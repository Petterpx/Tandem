# P1 遗留事项（合并时记录，2026-10-18）

来自 P1 执行过程中的任务审查与最终审查，均不影响正常使用，留待后续子项目顺带处理。

## 下个子项目开始前优先处理
- App 宿主的测试会运行真实 `AppModel.start()`：开启"插上自动开窗"时跑测试可能在手机上残留投屏会话。应在 XCTest 下跳过 start 或使用独立的 defaults。
- ~~产品改名为 Tandem（App 名、Bundle ID、MCP 可执行文件名）。~~ 已于 2026-10-18 完成（含 Swift 包 TandemCore、日志 subsystem、测试环境变量 TANDEM_*）。
- `AndroidSession.latestFrame` 已按 run 清理；P2 截图前确认首帧时序。
- `AdbClient.shell(_:_:)` 接受原始命令串：P3 的 Deeplink、自定义命令需要参数转义辅助函数。

## 交互 / 生命周期
- 设备列表触发的重连 Task 内未再次检查窗口是否仍打开（极小概率给已关闭窗口留下空转会话，退出时清理）。
- 窗口代理转发对象从未解除挂载（当前视图树下安全）。
- 全屏时旋转仍会调整窗口尺寸。
- 自动重连 5 次用尽后，再次插拔不会重新获得自动重试，只能点「重试」。
- 启动时恢复已保存的设备窗口这条路径未实测。
- 窗口开关的 Task 顺序、`eventTasks` 不回收、getprop 期间延迟后续事件。
- InputRouter：等待前一轮时可被取消导致极短重叠；open 与 swap 不在同一把锁内；测试含 50/200ms sleep。
- 拖动途中失去焦点不会发送抬起事件；粘贴失败只写日志；底部按钮点击区域偏小。

## 底层
- ProcessRunner：超时只发 SIGTERM，孙进程会成为孤儿；被取消时返回信号退出码而非抛 CancellationError。
- 控制通道读循环异常退出后剪贴板请求只会超时，未结束会话。
- 解码器在锁内调用 VTDecompressionSessionInvalidate（onFrame 若回调解码器会死锁，目前不会）。
- 手机上与官方 scrcpy 客户端共用 `/data/local/tmp/scrcpy-server.jar` 路径。
- 无线：二维码页 adb 缺失时仍显示"等待扫码"；旧进度回调可能覆盖新状态；输入框缺显式无障碍标签；30 秒连接服务超时不可注入测试。

## 待用户真机验证
见 `docs/superpowers/qa/p1-manual-checklist.md` 中标记「待用户验证」的项目（输入、输入法、旋转、拔插、扫码配对、一键转无线、USB+Wi-Fi 去重、双设备、小米横幅）。
