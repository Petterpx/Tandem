# P3b 快捷操作设计文档

依据总设计 `docs/superpowers/specs/2026-10-17-tandem-design.md`（下称"总设计"）§4、§5.3，P3a 设计 `2026-10-18-p3a-workspace-design.md` §1、§6，以及 P2 设计 `2026-10-18-p2-mcp-design.md`。本文件覆盖 P3b；与总设计冲突时以本文件为准，并已同步回总设计。

## 1. 目标与范围

在工作台右栏「快捷操作」标签里一键完成常用调试操作：网络开关、对目标 App 启动 / 强停 / 清数据 / 重启 / 卸载、打开链接、开发者开关、系统设置、自定义 shell 命令。每项功能同时注册为 MCP 工具，AI 与人用同一套能力。

顺序：P1 → P3a → P2（均已完成）→ **P3b** → P3c → P4。

不在 P3b：拖 APK 安装与 `install_app`、日志窗口与 `get_logs`、文件传输与 `push_file` / `pull_file`（均为 P3c）；iOS 实现（P4）。

## 2. 核心层

### 2.1 能力

`Capability` 新增 `network`、`apps`、`openURL`、`devOptions`、`systemSettings`、`shell`，Android 全部声明。能力概览中文名依次为：网络、应用管理、打开链接、开发者选项、系统设置、Shell。

### 2.2 DeviceActions

全部不依赖投屏会话，经 adb 按设备当前 serial 执行。

| 领域 | 方法 | Android 实现 |
|---|---|---|
| 网络 | `networkState() -> NetworkState` | `settings get global wifi_on`（非 0 为开）/ `mobile_data` / `airplane_mode_on`；每项可为「未知」（读不到或输出不是数字） |
| | `setNetwork(_ kind: NetworkKind, on: Bool) -> NetworkState` | `svc wifi enable\|disable`、`svc data enable\|disable`、`cmd connectivity airplane-mode enable\|disable`（Android 11+，低版本 `UNSUPPORTED`）。执行后约 1.5 秒回读，目标项未变为期望值则报错（§6） |
| 应用 | `foregroundApp() -> AppInfo` | `dumpsys activity activities` 中的 resumed activity（`topResumedActivity` / `mResumedActivity` / `ResumedActivity`（三星 Android 12）三种格式）取包名与 Activity；`dumpsys package <pkg>` 取 `versionName` |
| | `launchApp(_ package:)` | `cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <pkg>` 取启动 Activity，再 `am start -n <component>` |
| | `forceStop(_:)`、`clearData(_:)`、`uninstall(_:)` | `am force-stop`、`pm clear`、`pm uninstall`；后两者以输出含 `Success` 判断成功 |
| 链接 | `openURL(_ url:)` | `am start -a android.intent.action.VIEW -d <url>`（URL 经 shell 转义）；输出含 `Error` 判为失败 |
| 开发者 | `devOptions() -> DevOptions`、`setDevOption(_ option: DevOption)` | 显示触摸点 `settings put system show_touches 1\|0`；布局边界 `setprop debug.layout true\|false` 后 `service call activity 1599295570` 通知界面刷新；动画倍速同时设 `window_animation_scale`、`transition_animation_scale`、`animator_duration_scale`（取值 0、0.5、1、2、5、10）；保持唤醒 `settings put global stay_on_while_plugged_in 7\|0` |
| 系统 | `systemSettings() -> SystemSettings`、`setSystem(_ setting: SystemSetting)` | 深色模式 `cmd uimode night yes\|no`（读取 `cmd uimode night`）；字体大小 `settings put system font_scale`（0.85、1.0、1.15、1.3）；App 语言 `cmd locale set-app-locales <pkg> --locales <tag>`（Android 13+，`--locales ''` 表示跟随系统；读取 `cmd locale get-app-locales <pkg>`）；`openSystemLocaleSettings()` 用 `am start -a android.settings.LOCALE_SETTINGS` |
| Shell | `shell(_ command: String, timeout: Duration) -> ShellResult` | `adb shell <command>`；`ShellResult` 含 stdout、stderr、退出码、是否超时 |

普通 adb 权限无法修改**系统**语言，因此总设计中的"语言 `cmd locale`"改为「App 语言 + 打开系统语言设置」。

### 2.3 结构

- 模型类型放在 DeviceCore：`NetworkKind`、`NetworkState`、`AppInfo`、`DevOption`、`DevOptions`、`SystemSetting`、`SystemSettings`、`ShellResult`。
- `AndroidActions` 按领域拆为 `AndroidActions+Network.swift`、`+Apps.swift`、`+Settings.swift`、`+Shell.swift`。
- 命令拼装与输出解析写成纯函数（`AndroidCommands` 命名空间按领域分组），以真机输出为夹具单测。
- shell 转义：统一用单引号包裹，内部 `'` 写作 `'\''`。
- 包名在核心层校验：必须匹配 `^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$`，否则 `INVALID_ARGUMENT`。

## 3. 「快捷操作」面板

### 3.1 布局

自上而下：网络 / 应用 / 打开链接 / 开发者 / 系统 / 自定义命令 / 设备能力（P3a 的能力概览移到最下）。

- 每个分段可折叠，折叠状态存 UserDefaults。
- 设备缺少该分段的能力时，分段整体置灰并标注原因。

### 3.2 状态读取

- 以下时机各读一次：选中设备、切到本标签、点分段右上角「刷新」。
- 每次修改后以回读值更新界面。不定时轮询。
- 读取失败显示「—」，悬停显示原因。

### 3.3 网络

- Wi-Fi、移动数据、飞行模式三个开关。
- 切换中显示进度。
- 回读状态与期望不符时，开关回到实际状态，并在操作记录中记为失败。
- 设备经 Wi-Fi 调试连接时，关闭 Wi-Fi 会断开 adb：先弹确认框「关闭 Wi-Fi 会断开与设备的无线调试连接」。
- 同样经 Wi-Fi 调试时，开启飞行模式通常会关闭 Wi-Fi 射频：先弹确认框「开启飞行模式通常会关闭 Wi-Fi，断开无线调试连接」。

### 3.4 应用

- **目标**：顶部下拉，选项为「前台 App」和已固定的包名。
  - 「前台 App」显示包名与版本，旁边「📌 固定」把它加入固定列表。
  - 固定列表全局一份（所有设备共用），存 UserDefaults，下拉中每项可移除。
- **按钮**：「启动」「强停」「清数据」「重启」「卸载」。
  - 重启 = 强停后启动。
  - 只有卸载弹确认框，写明包名与"不可恢复"；清数据直接执行。
- 目标为「前台 App」但读不到时，按钮置灰并说明原因（如锁屏、桌面）。
- 当前目标即自定义命令中 `{package}` 的值。

### 3.5 打开链接

- 输入框加「打开」，回车同样打开。
- 下方是最近 20 条历史：全局一份，存 UserDefaults，点击直接打开，可删除单条。

### 3.6 开发者

- 「显示触摸点」「布局边界」「保持唤醒」三个开关。
- 「动画倍速」下拉：关、0.5x、1x、2x、5x、10x。

### 3.7 系统

- 「深色模式」开关。
- 「字体大小」下拉：小、默认、大、特大（对应 0.85、1.0、1.15、1.3）。
- 「App 语言」：作用于「应用」分段当前目标。
  - 下拉含「跟随系统」、简体中文、繁體中文、English、日本語、한국어。
  - Android 13 以下置灰，注明"需要 Android 13+"。
- 「打开系统语言设置」按钮。

### 3.8 自定义命令

- 全局一份列表，存 UserDefaults。每条为名称加 `adb shell` 命令。
- 支持占位符 `{package}`：用「应用」分段当前目标替换，并做 shell 转义。没有可用包名时，含占位符的按钮置灰。
- 点击执行。最近一次输出显示在该按钮下方：最多 200 行，带「拷贝」；失败时标红并显示退出码。
- 「编辑」模式：添加、修改、删除、拖动排序。
- 超时 30 秒。

### 3.9 记录与执行路径

- 所有操作经 `DeviceCommands` → `ActionRunner`（来源「你」）进入操作记录。读取状态不记录。
- 记录标题：
  - 网络：`关闭 Wi-Fi`
  - 应用：`清数据 com.demo`、`卸载 com.demo`
  - 链接：`打开链接 <url>`
  - 开发者 / 系统：`显示触摸点：开`
  - 自定义命令：`执行：<名称>`

## 4. MCP 工具

- 执行路径沿用 P2：`ToolRegistry` → `AICommands` → `ActionRunner`（来源 AI）。
- 均不需要投屏会话，不会因此自动启动会话。
- 操作类受「禁止 AI 操作」限制（`AI_LOCKED`），感知类照常可用。

| 工具 | 参数 | 类别 | 能力 | 说明 |
|---|---|---|---|---|
| `current_app` | — | 感知 | apps | 包名、Activity、版本 |
| `launch_app` | `package` | 操作 | apps | |
| `force_stop` | `package` | 操作 | apps | |
| `clear_app_data` | `package`（必填） | 操作 | apps | 破坏性操作须显式给出包名 |
| `uninstall_app` | `package`（必填） | 操作 | apps | 同上 |
| `open_url` | `url` | 操作 | openURL | |
| `get_network_state` | — | 感知 | network | |
| `set_network` | `kind`（wifi / data / airplane）、`on` | 操作 | network | 返回回读后的实际状态 |
| `get_dev_options` | — | 感知 | devOptions | |
| `set_dev_option` | `option`（show_touches / layout_bounds / stay_awake / animation_scale）、`value` | 操作 | devOptions | 开关项 `value` 为布尔；`animation_scale` 为数字，仅 0、0.5、1、2、5、10 |
| `get_system_settings` | `package?` | 感知 | systemSettings | 深色模式、字体大小；给出 `package` 时附该 App 的语言 |
| `set_system` | `setting`（dark_mode / font_scale / app_locale）、`value`；`app_locale` 需 `package` | 操作 | systemSettings | `font_scale` 仅 0.85、1.0、1.15、1.3；`app_locale` 的 `value` 为 BCP 47 语言标签或空字符串（跟随系统） |
| `shell` | `command` | 操作 | shell | 输出超过 64 KB 截断并注明；超时 30 秒 |

- **shell 开关**：设置页新增「允许 AI 执行 shell 命令」，默认开启（总设计 §5.5）。
  - 关闭后 `shell` 不出现在 `tools/list` 中，并推送 `tools/list_changed`。
  - 已缓存旧列表的客户端调用时返回 `UNSUPPORTED: 已在 Tandem 设置中关闭`。
- 工具列表仍按已连接设备的能力并集过滤（P2 §3.4）。
- **操作记录标题**：`launch_app com.demo`、`set_network wifi off`、`shell <命令前 80 字>`。shell 命令写入记录，便于排查；它与 `type_text` 的输入内容不同，后者不写入。

## 5. 设置页

新增「允许 AI 执行 shell 命令」开关，默认开启，存 UserDefaults。切换时同步更新工具列表（§4）。

## 6. 错误处理

| 情况 | 结果 |
|---|---|
| 系统版本不支持（飞行模式 Android < 11、App 语言 Android < 13，或命令输出 `Unknown command` / `not found`） | `UNSUPPORTED`，"该系统版本不支持 …"；对应控件置灰并说明 |
| 开关修改后回读未生效 | `CONNECTION_FAILED`，"设置未生效"，建议"部分 ROM 禁止通过 shell 修改此项，请在手机上手动设置" |
| `pm clear` / `pm uninstall` / `am start` 输出不含成功标记 | 失败，信息中原样带上设备输出（如 `Failure [DELETE_FAILED_INTERNAL_ERROR]`） |
| 读不到前台 App | 「前台 App」显示「—」并说明原因；依赖它的按钮置灰；`current_app` 返回 `CONNECTION_FAILED`，"无法识别前台 App" |
| 包名不合法 | `INVALID_ARGUMENT` |
| shell 超时 | `TIMEOUT`，并附已取得的部分输出 |
| AI 对经 Wi-Fi 调试的设备调用 `set_network wifi off` | `UNSUPPORTED`，"设备经 Wi-Fi 调试连接，关闭 Wi-Fi 会断开连接"（面板上人可以在确认后执行） |
| AI 对经 Wi-Fi 调试的设备调用 `set_network airplane on` | `UNSUPPORTED`，"设备经 Wi-Fi 调试连接，开启飞行模式会断开连接"（面板上人可以在确认后执行） |

## 7. 测试

**单元测试**

- `AndroidCommands`：每个领域的命令拼装与输出解析，以真机输出为夹具。
  - `settings get` 的 `0`、`1`、`2`、`null`、空输出。
  - `dumpsys activity` 三种 resumed activity 格式（`topResumedActivity` / `mResumedActivity` / 三星 Android 12 的 `ResumedActivity`）。
  - `dumpsys package` 取 versionName。
  - `pm` / `am` 的成功与失败输出。
  - `cmd uimode night`、`cmd locale get-app-locales` 的输出。
  - shell 转义：引号、空格、`&`、中文。
  - 包名校验。
- `AndroidActions`：用 `FakeProcessRunner` 验证调用序列，包括"修改后回读不一致即报错"和低版本 `UNSUPPORTED`。
- App 层：
  - `DeviceCommands` 新入口：写记录；只有卸载需要确认。
  - 固定包名、链接历史（20 条上限）、自定义命令的存取、排序与占位符替换。
  - `ToolRegistry` 新工具：参数校验、锁定、shell 开关关闭后从列表消失并推送通知。

**真机集成测试**（设置 `TANDEM_TEST_SERIAL` 时运行；只做可逆操作，结束时恢复原状）

- 读取网络状态。Wi-Fi 关掉再打开：仅当设备经 USB 连接时执行，serial 含 `:` 时跳过，以免断开 adb。
- 读取前台 App。
- 显示触摸点：开后关。
- 深色模式：切换后恢复。
- shell 执行 `echo tandem`。

卸载、清数据、飞行模式不做自动化，放入人工验收清单。

**人工验收清单**：每个分段走一遍，包括：

- 卸载确认框；
- App 语言在 Android 13 以下置灰；
- 自定义命令的编辑、排序与 `{package}` 替换；
- AI 端到端调用新工具；
- 关闭 shell 开关后工具消失；
- 锁定后操作类工具被拒、感知类可用。
