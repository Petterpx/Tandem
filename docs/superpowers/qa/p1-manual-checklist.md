# P1 手动验收清单

测试日期：2026-10-18　设备：Samsung SM-G9730（Galaxy S10，Android 12，序列号 R28M31LKJ1J，USB）　构建：Debug，Xcode 27.1

结果图例：PASS 已在真机验证；FAIL 未通过；待用户验证 需要人在手机或 Mac 上操作；未验证（无对应设备）。

## 自动化可执行项（已在真机上跑过）

| # | 项目 | 预期结果 | 结果 | 证据 |
|---|------|----------|------|------|
| A1 | 集成测试 `MAGICDEVX_TEST_SERIAL=R28M31LKJ1J swift test --filter AndroidIntegrationTests` | 10 秒内 running，5 秒内有画面，剪切板往返一致，Home 键不抛错，stop 后无 `scrcpy_` 端口转发残留 | PASS | endToEnd 1.197 秒通过；未设环境变量时该 suite 显示 skipped |
| A2 | USB 插入后菜单出现设备 | 菜单栏设备列表中出现该设备 | 部分通过（窗口自动打开说明设备已被识别；菜单栏列表本身待用户验证） | 启动后自动出现 "SM G9730" 窗口 |
| A3 | 打开窗口，1 秒内出现画面 | 1 秒内出现手机画面 | 部分通过（约 1.1 秒，首帧未单独测量） | 启动后约 1.1 秒（0.25 秒轮询）窗口出现且服务端已启动，测的是窗口/服务端而非首帧；启动 3 秒后 `screencapture -l` 截图显示实时画面，标题 "SM G9730" |
| A4 | 退出 App 后清理 | 退出后无残留 adb forward、手机上无 app_process | PASS | `osascript quit` 后 `adb forward --list` 为空，`ps -A \| grep -c app_process` = 0 |
| A5 | 删除 Vendor 后构建 | 构建失败并报"请先运行 scripts/fetch-vendor.sh" | PASS | 临时移走 App/Resources/Vendor，xcodebuild 输出 `error: 请先运行 scripts/fetch-vendor.sh` 与 BUILD FAILED；已移回，再次构建 BUILD SUCCEEDED |
| A6 | 系统中没有可用 adb 时使用内置 adb | AdbLocator 在其他候选都不可运行时回退到内置 adb | PASS（单元测试） | AdbLocatorTests 8 项全过，含 fallsBackToBundled、skipsBrokenCandidate；内置 `Vendor/adb version` 为 37.0.0。未卸载用户 SDK |
| A7 | 运行 60 秒期间手机上 app_process 保持 | 2 个进程（server 与其 CleanUp 进程）持续存在 | PASS（见报告） | 干净启动后每 5 秒采样 14 次均为 2 个进程（PID 22320、22347 不变） |

## 需要人工操作的项

| # | 项目 | 预期结果 | 结果 |
|---|------|----------|------|
| M1 | 点击 | 点击窗口内位置，手机在对应位置响应 | 待用户验证 |
| M2 | 拖动 | 按住拖动，手机上列表/页面跟随滑动 | 待用户验证 |
| M3 | 滚轮 | 滚轮或触控板滚动，手机内容滚动 | 待用户验证 |
| M4 | 右键返回 | 右键等同于返回 | 待用户验证 |
| M5 | Esc | 等同于返回 | 待用户验证 |
| M6 | ⌘H | 回到手机桌面 | 待用户验证 |
| M7 | ⌘S | 打开多任务（最近任务）界面 | 待用户验证 |
| M8 | ⌘↑ / ⌘↓ | 音量加 / 减 | 待用户验证 |
| M9 | ⌘P | 电源键（亮灭屏） | 待用户验证 |
| M10 | Mac 中文输入法输入"你好世界" | 手机输入框中出现"你好世界" | 待用户验证 |
| M11 | ⌘V 粘贴 Mac 剪切板文本 | 手机输入框中出现该文本 | 待用户验证 |
| M12 | 旋转手机 | 窗口比例随之改变，画面不拉伸 | 待用户验证 |
| M13 | 拔线再插回 | 拔线后显示"已断开"；插回后自动恢复画面 | 待用户验证 |
| M14 | 两台设备同时开窗口 | 互不干扰，各自独立控制 | 待用户验证（仅有一台设备） |
| M15 | 扫码配对 | 配对成功，Wi-Fi 设备可以投屏 | 待用户验证（CLI 曾遇 No route to host，疑为 macOS 本地网络权限或 AP 隔离，需在 App 内确认） |
| M16 | 对 USB 设备"一键转无线"后拔线 | 仍能继续操控 | 待用户验证 |
| M17 | 同一台手机同时 USB + Wi-Fi | 菜单只显示一台（按 ro.serialno 去重） | 待用户验证 |
| M18 | 小米设备未开安全设置 | 出现横幅；打开开关后点"已打开，重新连接"，可正常点击 | 未验证（无对应设备，本机为三星） |

注：输入类项目（M1–M9）需要向 Mac 窗口注入事件，会真实操作用户手机上的个人应用，未擅自执行。
