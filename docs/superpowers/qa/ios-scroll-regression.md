# iOS 模拟器滚动积压回归（2026-11-04）

用户报告：双指触控板滚动卡顿，松手后仍持续滚动，最后模拟器画面卡住；Tandem 侧栏仍能点击。

## 已确认的缺陷

- iOS 输入队列只合并连续触点移动，没有合并无 phase 的滚轮事件。每个滚轮事件会转换为一次完整拖动（5 次 12 ms 插值和一次 80 ms 原生抬手 drain），输入速度高于消费速度时持续重放旧滚动。
- 惯性分支直接返回，可能在手指结束与惯性阶段重叠或结束事件缺失时漏掉触点释放。
- 输入消费者取消、视图移除或失焦时，没有可靠释放已发送的触点。
- 真实 App 输入链路还复现了连续快速手势积压：即使移动事件已合并，每次人工抬手仍等待 DTUHID 固定 80 ms drain；连续 10 次手势后，后续按键确认延迟 1125 ms。

这些路径通过回归测试复现；尚未记录用户本次物理触控板的原始 NSEvent，因此不把特定事件分支当成已确认的唯一现场原因。

## 修复与验证方法

- iOS 队列合并相邻同位置滚轮，保持触点、文字、按键和粘贴边界。
- iOS 无 phase 的精确滚动改为一次连续拖动，停止输入 80 ms 后自动抬手；源时间戳间隔、计时器代际、失焦和输入切换共同约束结束。普通滚轮与 Android 不使用这条兼容路径。
- 惯性接管、视图退出和消费者退出均补齐释放；旧消费者清理结束后才启动下一代输入。
- 只有实际移动过的人工拖动抬手跳过 80 ms drain；普通点击和 AI 操作仍保留原来的等待，关闭会话仍执行 drain。
- 默认 Android 输入通道保持原行为。
- 原生 ScrollFixture 记录 UIKit 实际触点、拖动状态、帧回调和恢复按钮；日志缓冲有界，序列化与写盘不占主线程。
- App 集成测试直接把合成 NSEvent 交给隐藏 VideoSurfaceView，经真实 ScrollGesture、InputRouter、IOSSimulatorSession 到模拟器；不向 macOS 全局注入事件。
- 性能测试先执行并单独记录冷启动手势，再测稳定状态：UIKit 测试列表第一次滚动有约 1.7 秒的初始化停顿，同进程预热后原生实际释放为 8.6 ms，不能把这段测试页面冷启动开销归因于稳定输入传输。

## 证据

- `/tmp/tandem-scroll-app-red.log`：滚轮积压、消费者取消漏释放、惯性漏释放三项先失败。
- `/tmp/tandem-scroll-view-red.log`：移除视图和失焦漏释放先失败。
- `/tmp/tandem-scroll-app-green.log`：22 项针对性回归通过。
- `/tmp/tandem-scroll-live-baseline.log`：真实 App 链路的连续 10 次手势超过 300 ms 停止预算，实际约 1.1 秒。
- `/tmp/tandem-scroll-live-drag-drain.log`：普通 120 Hz 拖动实际释放 48 ms；连续 10 次快速手势实际释放 133 ms、后续按键 219 ms；取消释放 25 ms。各恢复点击通过，无输入或会话错误。此阶段无 phase 的精确滚动仍失败：每次合并后的完整滑动耗时 225–300 ms，最终实际释放 490 ms、后续按键 582 ms。

早期原生释放统计还包含测试状态文件发布延迟：状态定时器最初只运行在默认 run-loop mode，跟踪期间不能及时写入。最终 fixture 改为 common mode，并使用 UIKit 事件自己的时间戳判断实际释放，正常减速不计为仍在按住触点。早期日志中的释放等待数字不作为最终性能证据。

## 最终真实输入链路

`/tmp/tandem-scroll-live-final.log` 及补齐无后续输入场景的 `/tmp/tandem-scroll-live-final-idle.log`：两次均通过，无输入或会话错误。表中“实际释放”使用 UIKit 触点结束事件的时间戳，“后续按键”包含按键本身的原生等待；区间覆盖两次最终运行。

| 情景 | 后续按键等待 | 实际触点释放 |
|---|---:|---:|
| 正常 120 Hz 双指事件 | 124–132 ms | 41–46 ms |
| 连续 10 次快速手势 | 137–228 ms | 61–138 ms |
| 无 phase 精确滚动 60 Hz | 129–151 ms | 37–57 ms |
| 缺少 ended，惯性接管 | 129–131 ms | 39–53 ms |
| 手势取消 | 138–147 ms | 56 ms |
| 失焦 | 127–152 ms | 41–65 ms |
| 视图移除 | 115–119 ms | 27–30 ms |

消费者取消后实际释放 19–34 ms；后续恢复点击 36–80 ms。另行验证停止精确滚动后不按键、不点击、不切换焦点，实际自动抬手 116 ms，随后点击恢复 63 ms。兼容滚动全程没有下发旧式 `.scroll` 操作。真实 UIKit 持续移动被观测到，但这些输入观测值不代表 60 Hz 触点交付承诺。

用相同最终前端和修正后的测量方法换回原 helper，连续 10 次快速手势再次失败：后续按键 1221 ms、实际释放 1058 ms；其余路径无输入错误。证据：`/tmp/tandem-scroll-live-oldhelper.log`。这组对照只隔离原生抬手等待的影响，不混入旧前端的滚轮积压。

Helper 完整回归 22 项通过（20 XCTest + 2 Swift Testing），`/tmp/tandem-touch-movement-green.log`。前端连续滚动兼容路径先失败后通过，26 项定向测试，`/tmp/tandem-continuous-scroll-{red,green}.log`。两轮独立代码审阅未发现确认的剩余问题。

## 打包与交付

- 完整 App 回归：552 项、63 suites 通过；原生 opt-in suite 在默认回归中跳过，已单独运行上述真实验证。
- 最终 `xcodebuild test`、严格 deep codesign、`git diff --check` 通过，日志 `/tmp/tandem-scroll-final-app.log`。
- 最终包内 helper 与真实输入链路验收用 helper 的 SHA256 一致：`66c8fa763fefa1a95d7d008e63aee43c6880ffbe15d1740892fd932e41f2ab3d`。
- 最终包内 helper 的原生帧、剪贴板、输入确认、触点所有权、quit/EOF/SIGTERM smoke 通过：`/tmp/tandem-scroll-final-smoke.log`。
- 本轮创建的专用模拟器 `Tandem-Scroll-Regression` 已关闭并删除；用户 iPhone 18 Pro 保留。
- 已启动修复后的本地 App（`DerivedData/Tandem-ios-perf/Build/Products/Debug/Tandem.app`），本地控制接口确认用户设备投屏中，并获取到实时投屏帧。

桌面 ScreenCaptureKit 接口仍报 -3811，未能替用户选中侧栏，也未自动重放物理触控板操作。验收基于实际 App 输入代码、合成 NSEvent 与真实模拟器 UIKit 事件，物理触控板手感仍需要用户试用确认。
