# iOS 双指滚动起步与连续跟随（2026-11-04）

用户反馈：双指滑动后先卡一下才切换，移动过程不够跟手。此次重点是首段输入和持续移动，不能只以最终完成滑动或正确抬手作为验收。

## 已确认原因与改动

- iOS `.began` 可以携带有效位移，原来只在 `.changed` 开始触摸，丢失短手势的起步时机。现在立即处理首段位移，保留 4pt 防误触阈值。
- 人工触摸原来每个点分别读取显示配置、建立原生 HID 操作并完成显示校验。现在复用公开 `hid.send(events:)` 的连续操作，使用 framebuffer 已知的几何与 generation 绑定；连续移动不再逐点查询显示配置。
- ACK 在原生 primitive 的传输 barrier 完成后返回，不等同于 UIKit 已处理或画面已展示。普通点击、文字、按键、AI 切换与关闭仍保留必要的 drain；不能为了低 ACK 数字丢弃焦点和释放保证。
- 到屏幕边缘后丢弃越界累积位移，使反向立即生效。持续向同一方向超过屏幕长度仍受触点边界限制，本轮没有加入抬起重定位。
- 显示变更或关闭同步使旧触摸事务失效，再等待原生清理。旧 ACK 不能恢复已经释放的触点，也不能覆盖新显示上的触摸。
- 连续通道的早期 native 检查还发现首次配置报告的初始化竞态：`initialConfiguration` 可以为空，首个异步 snapshot 不能算作显示切换。现在只有已知 generation 发生变化才取消触摸；原来的旋转保护保留。`/tmp/tandem-native-stream/initial-config-red.log` 记录修复前的明确行为失败。

## 自动验证

- 首段位移、微小滑动不点击、边缘反向：20 项定向测试通过，`/tmp/tandem-scroll-semantics-green.log`。
- 连续通道 4 项测试覆盖 ACK 必须等待实际传输、失败不重放、finish 等待 drain、cancel 等待清理。
- 旋转取消后旧 down/move 提交的竞态先在旧行为下失败，再通过 epoch 校验修复。`/tmp/tandem-native-stream/epoch-red.log` 保留行为失败证据。
- 首屏初始化修复前 Helper 完整 29 项通过，`/tmp/tandem-native-stream/final-tests.log`。最终 31 项中 30 项通过，包括全部 25 项 XCTest、4 项 stream 与 slow-video 测试；静态编码首帧时间断言失败（1649ms 超过 1000ms），无编译并发时单项复测仍为 2289ms。最终两帧均写出，没有编码错误或丢帧；没有修改阈值或视频实现，也不能把此次完整 helper 回归称为全绿。日志：`initial-config-green-all.log`、`initial-config-static-recheck.log`（均位于 `/tmp/tandem-native-stream/`）。
- 最终 helper SHA256：`982f50b43bb940f0bc400399f3a57a9560f684078364ac89cc1fd72a8f7b0a0e`。初始化修复和取消竞态均经过代码复审；host、guest 与两个 stub 的签名验证通过。
- 完整 App 回归 555 项、63 suites 通过：`/tmp/tandem-scroll-follow-default-suite.log` 与同名 `.xcresult`。随后仅替换完成初始化修复的 helper，App 源码不变；测试包与交付包内 helper SHA 都与上述最终版本一致，均重新通过严格 deep 签名检查。原生性能 suite 默认跳过，不能把默认全量回归当成真实性能验收。

## 真实输入测量的边界

App 集成测试使用隐藏的 VideoSurfaceView，通过真实 ScrollGesture、InputRouter、IOSSimulatorSession 与模拟器 UIKit，同时记录首个页面位移、前 100ms、逐段移动、反向、按住暂停、实际释放和解码画面变化；不向桌面全局注入事件。

本轮机器出现明显启动与调度压力。首次 baseline 在测试状态文件的发布等待上失败；事后 guest 日志包含实际 began/moved/ended，状态文件一次写入耗时最高 2401ms，不能把文件晚到解释为触点未释放。证据：`/tmp/tandem-scroll-follow-baseline-failed-guest.json`、`/tmp/tandem-scroll-follow-baseline.log`。

因此 fixture 在 scene active 且经过 3 个显示回调后才发布 ready；测试允许最多 10 秒收集原生证据，实际输入延迟仍使用 guest 事件时间戳与原有 300ms 预算，未放宽性能断言。原型直接向 helper 排队的压力数据不代表完整 App 的性能，也不作为原生 Simulator 同等手感的证明。

候选阶段的测试页安装阻塞 136 秒后终止；后续启动现有测试页也超过 20 秒。因此本轮完整 App 的 candidate A/B 未执行，不能给出可靠的起步、跟随或视频延迟提升数字。默认 555 项回归与 helper 单元测试不替代物理触控板手感验收。

## 最终运行与交付

- 最终 helper 在用户 EED 设备上通过有限检查：ready、真实编码首帧、边缘 down → 两次 move → up、AI 锁、下一次 down/up、quit 退出。未访问文字或剪贴板。证据：`/tmp/tandem-native-stream/user-edge-smoke/result.json` 与 `commands.json`。这是传输和生命周期检查，不是 UIKit 跟随延迟测量。
- 已将新 App 放回 `/Users/petterp/Library/Developer/Xcode/DerivedData/Tandem-ios-perf/Build/Products/Debug/Tandem.app`；旧版保留在 `/tmp/Tandem-before-scroll-follow-20261104.app`。
- CUA 已确认新 App 前台窗口标题为 `Tandem · iPhone 18 Pro`，设备选中且 884×1920 实时投屏。实际鼠标拖动后，从带地图/日历组件的主屏切换到 Fitness/Watch 所在下一页，画面更新可见；不据此宣称物理触控板已达到原生手感。
- 本轮两个专用测试设备 61AA、8C 已关闭并删除；用户 EED 保持启动，未清除其应用或数据。
