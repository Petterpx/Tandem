# Tandem（同驾）设计文档

日期：2026-10-17
状态：待评审

## 1. 背景与目标

开发时控制测试手机需要频繁直接触碰设备：看屏幕、截图、读写剪切板、开关网络等都要手动操作。Tandem 是一个 macOS 原生 App，用于：

- 在 Mac 上实时查看并用鼠标/键盘操控测试手机（Android 为主，iOS 次之）；
- 通过快捷面板一键完成常用开发操作；
- 通过 MCP 让 AI（Claude Code 等）操控同一批设备，人和 AI 可同时协作。

**GUI 与 AI 同等重要**，二者共享同一条设备连接与同一套能力。

### 已确认的需求决策

| 项 | 决策 |
|---|---|
| 优先级 | 人用 GUI 和 AI 操控同等重要，经常同时使用 |
| 设备数量 | 常连 2～4 台，需同时查看；每台设备一个独立窗口；AI 调用需指定设备 |
| 连接方式 | USB 为主，支持 Android Wi-Fi adb（扫码配对 + 一键转无线）；iOS 仅 USB |
| AI 架构 | App 是唯一的设备管理者，常驻菜单栏；MCP 为薄桥接，App 未运行时自动后台拉起 |
| 技术路线 | Swift 原生 App；Android 端复用 scrcpy-server（锁定 v5.0.1），Mac 端协议自行实现 |
| 剪切板 | 以手动"读取 / 写入 / 写入并粘贴"为主；双向自动同步为可选开关，默认关闭 |
| 快捷面板范围 | 截图录屏、剪切板、网络开关、应用管理、Deeplink、日志、开发者开关、系统设置、文件传输；**不做**模拟定位 |
| 最低系统 | macOS 14 |

### 品牌（2026-10-18 确定）

- 应用名：**Tandem**，中文名「同驾」；标语「你和 AI，一起驾驶你的测试机」。
- 图形：两个错位叠放的圆角手机轮廓（一实一描边），象征人与 AI 协同、镜像投屏；主色 #2F6FED。
- 界面以浅色为主设计，深色模式跟随系统派生。
- 名称尚未做商标检索，公开发布前需检索。
- 代码已于 2026-10-18 统一改名：产品名 Tandem、Bundle ID `dev.tandem.Tandem`、Swift 包 TandemCore、MCP 可执行文件 `tandem-mcp`；仓库目录与本文件名随后也改为 Tandem。App 图标与菜单栏图标采用方案 A。

### 非目标

- 不做 Windows/Linux 版本；
- 不做 5 台以上的设备墙/网格总览；
- 不做模拟定位；
- 不支持 CI/无界面环境运行（AI 依赖 Mac App）；
- 第一版不传音频。

## 2. 整体架构

```
Tandem.app
├─ UI 层 (SwiftUI + AppKit)
│   ├─ 工作台主窗口: 左侧设备列表 | 中间投屏 | 右侧控制面板 | 底部最近截图 + 操作记录
│   ├─ 独立设备窗口 ×N: 从工作台"弹出"，用于多台对照（P1 已实现的设备窗口）
│   └─ 菜单栏: 设备列表、连接状态、无线配对入口、设置（快速入口）
├─ ControlServer: Unix socket ~/Library/Application Support/Tandem/control.sock, JSON-RPC
├─ DeviceCore
│   ├─ DeviceManager: 设备发现、上下线、按 id 管理会话
│   ├─ DeviceSession (actor): 每设备一个，串行处理 GUI 与 AI 的全部指令
│   └─ Capability: 驱动声明支持的能力集合
├─ AndroidDriver: adb 调用、scrcpy 会话、快捷操作实现
├─ MediaKit: 固定画布录屏（与平台无关）
└─ IOSDriver: CoreMediaIO 投屏 + WebDriverAgent 控制 (P4)

tandem-mcp (App 内 Contents/MacOS 下的 CLI)
└─ stdio MCP Server → 连接 control.sock；连接失败时 `open -g` 拉起 App 并重试
```

### 关键原则

- **单一路径**：鼠标输入与 AI 调用都进入同一个 `DeviceSession`，避免冲突。
- **能力驱动**：面板按钮与 MCP 工具列表都由设备声明的 Capability 动态生成，不在 UI/MCP 层写平台判断。
- **adb 来源**：优先使用系统已有 adb（PATH、Homebrew、`$ANDROID_HOME/platform-tools`），找不到时才用 App 内置版本（platform-tools r37.0.0），避免与 Android Studio 的 adb server 版本冲突互杀。每个候选都必须实际运行 `adb version` 验证（例如 Apple 芯片上残留的 x86_64 adb 会报 `bad CPU type`），不能运行的跳过。
- **工程结构**：一个 Xcode 工程，含 App target 与 MCP CLI target；核心逻辑放在本地 Swift Package（`DeviceCore`、`AndroidDriver`、后续 `IOSDriver`），可脱离 UI 单测。

## 3. Android 投屏与控制会话

### 3.1 设备发现

- 常驻 `adb track-devices` 监听插拔，菜单栏实时显示状态（已连接 / 未授权 / 离线）。
- 点击设备在工作台中选中它；可设置"插上自动显示"（打开工作台并选中新设备）。
- 断开后窗口保留并显示"已断开"，设备回来自动重连。

### 3.2 scrcpy 会话（v5.0.1）

- 推送内置的 `scrcpy-server.jar` 到 `/data/local/tmp/`，通过 `app_process` 启动，建立视频与控制两个 socket（`audio=false`）。
- **视频**：解析 scrcpy 帧头 → H.264 送入 VideoToolbox `VTDecompressionSession` 硬解 → `CVPixelBuffer`（IOSurface）直接设为窗口 layer 内容。设备旋转时按新分辨率调整窗口比例。
- **最新帧缓存**：会话始终保留最近一帧，供 AI 快速截图。
- **截图两档**：面板截图走 `adb exec-out screencap -p`（无损原分辨率）；AI 截图默认取最新帧，`hq=true` 时走 screencap。
- **无线连接**时默认降低码率与 `max_size`。

### 3.3 输入映射

| Mac 输入 | 设备行为 |
|---|---|
| 左键点击 / 拖动 | 触摸 / 滑动（INJECT_TOUCH_EVENT） |
| 鼠标滚轮 | 滚动（INJECT_SCROLL_EVENT，横向取反，与 scrcpy 一致） |
| 触摸板双指滑动 | 模拟手指拖动：约 4pt 后按下并锁定方向，松手抬起，惯性交给 Android（逐个发滚动事件会让桌面每个事件翻一页） |
| 右键 / Esc | 返回 |
| ⌘H / ⌘S | 主页 / 多任务 |
| ⌘↑ / ⌘↓ / ⌘P | 音量加 / 音量减 / 电源 |
| 普通按键 | INJECT_KEYCODE |
| 文本 | ASCII 走 INJECT_TEXT；非 ASCII（中文等）走"SET_CLIPBOARD + paste" |

### 3.4 剪切板

- **读取**：GET_CLIPBOARD，内容显示在面板预览并复制到 Mac 剪切板。
- **写入**：把 Mac 剪切板当前内容（或面板输入框文本）SET_CLIPBOARD 到设备。
- **写入并粘贴**：SET_CLIPBOARD 时带 paste 标志，直接粘贴到当前输入框。
- 面板保留最近 10 条读写历史，可一键再次写入。
- **双向自动同步**：可选，每设备单独开关，默认关闭。scrcpy-server 一律以 `clipboard_autosync=true` 启动，设备端变化主动推送，开关关闭时丢弃；Mac 端轮询 `NSPasteboard.changeCount`；记录最后一次同步内容以防回环。

### 3.5 无线连接

- **扫码配对（Android 11+）**：App 生成 `WIFI:T:ADB;S:<name>;P:<password>;;` 二维码，手机在"无线调试 → 使用二维码配对设备"中扫描；App 通过 `adb mdns services` 发现配对服务后执行 `adb pair` 与 `adb connect`。
- **一键转无线**：对 USB 已连设备执行 `adb tcpip 5555`，读取设备 IP 后 `adb connect`。

### 3.6 国产 ROM 检测

监听 scrcpy-server 输出，出现输入注入权限异常（INJECT_EVENTS）时，在窗口顶部显示横幅，按品牌（小米 / OPPO / vivo / 华为等）给出打开"USB 调试（安全设置）"类开关的路径。

## 4. 快捷面板

位于工作台主窗口右侧（2026-10-18 确定采用工作台方案）。每个功能同时注册为 MCP 工具。

### 4.0 工作台布局

- **左栏**：设备列表（名称、连接方式、状态点），点击切换当前设备；悬停出现「弹出」按钮，把设备弹成独立窗口（可同时弹出多台，用于对照），已弹出的设备显示「已弹出」标签；底部为「无线配对…」「设置」入口。
- **中间**：当前设备的投屏；上方为设备名、系统 · 分辨率 · 连接方式、状态徽标与「弹出为独立窗口」；下方按钮行为返回 / 主页 / 多任务 | 截图 / 录屏。
- **右栏**：三个标签——
  - **快捷操作**：按分段滚动排列网络、应用（装包 / 清数据 / 强停 / 卸载 / 重启 / 日志入口）、打开链接、系统、开发者、自定义命令、能力概览（列出当前设备各能力支持与否）。
  - **剪贴板**：读取、写入、写入并粘贴、历史、双向自动同步开关（默认关）。
  - **AI**：MCP 连接状态与接入命令、「禁止 AI 操作」开关。
- **底部**：左为「最近截图」（本次会话的截图与录屏缩略图，悬停可「拷贝」「在 Finder 中显示」，可清空）；右为「操作记录」（时间、来源标签 你 / AI、描述，失败标红），取代原 §5.5 的面板内"AI 操作记录"。
- 设备不支持的分段整体置灰并标注原因（如"iOS 不支持"）。
- 视觉：浅色为主，层次靠明度区分（侧栏冷灰、面板近白、投屏画布浅灰加淡点阵），单一强调色 #2F6FED；深色模式跟随系统派生。参考原型：claude.ai 画布中的 Workspace 页面。

| # | 功能 | Android 实现 | 交互 |
|---|---|---|---|
| 1 | 截图 | `exec-out screencap -p` | 保存到可配置目录 + 复制到剪切板 + 缩略图预览（可拖出） |
| 1 | 录屏 | 录制投屏解码画面，固定画布（首帧尺寸，旋转时等比缩放居中）+ VideoToolbox H.264 编码；无时长限制（2026-10-18 取代 `screenrecord` 方案） | 开始/停止，输出 mp4 |
| 2 | 剪切板 | 见 3.4 | 读取 / 写入 / 写入并粘贴 / 历史 |
| 3 | 网络 | `svc wifi`、`svc data`、`cmd connectivity airplane-mode` | 三个开关，状态实时回读，不假设成功 |
| 4 | 应用管理 | `install -r -d`、`uninstall`、`pm clear`、`am force-stop` | 拖 APK 入窗口安装；"当前前台 App"：清数据 / 强停 / 卸载 / 重启 |
| 5 | Deeplink | `am start -a android.intent.action.VIEW -d <url>` | 输入框 + 历史 |
| 6 | 日志 | `logcat --pid=<当前前台 App>` | 独立日志窗口：级别 / 关键字过滤、暂停、导出 |
| 7 | 开发者开关 | `settings put` / `setprop`：显示触摸点、布局边界、动画倍速、保持唤醒 | 开关 + 下拉 |
| 8 | 系统设置 | 深色模式 `cmd uimode night`；字体 `settings put system font_scale`；App 语言 `cmd locale set-app-locales`（Android 13+）+ 打开系统语言设置页（普通 adb 权限无法改系统语言，2026-10-18 调整，见 `2026-10-18-p3b-quick-actions-design.md`） | 下拉 |
| 9 | 文件传输 | `push` / `pull` | 非 APK 文件拖入推送到 `/sdcard/Download`；简易文件浏览器拉取 |
| + | 自定义按钮 | 用户配置的 `adb shell` 命令 | 面板底部按钮 |

不支持的系统版本（如部分版本禁止 shell 改飞行模式）返回明确错误，按钮提示"该系统版本不支持"。

**截图 / 录屏完成提示条**

- 默认目录：截图 `~/Pictures/Tandem/`，录屏 `~/Movies/Tandem/`（设置中可改）；文件名 `<设备名>_yyyyMMdd_HHmmss.<ext>`。
- 录屏完成：缩略图 + 时长 + 大小 + 文件名，按钮「拷贝」（以文件 URL 写入 Mac 剪切板，等同 Finder ⌘C，可粘贴到 Finder / 聊天工具）与「在 Finder 中显示」（`NSWorkspace.activateFileViewerSelecting`，打开目录并选中该文件）。
- 截图完成：图片已自动复制，提供「在 Finder 中显示」。
- 提示条停留 8 秒，鼠标悬停时不消失。
- 每次截图 / 录屏完成后同时追加到工作台底部「最近截图」，提示条关闭后仍可在那里拷贝或在 Finder 中显示。

### 4.1 ⌘V 粘贴文件到设备

设备窗口获得焦点时按 ⌘V，按 Mac 剪切板内容分流：

| 剪切板内容 | 行为 |
|---|---|
| 文本 | 写入设备剪切板并粘贴（同"写入并粘贴"），不弹窗 |
| 文件 / 文件夹（`public.file-url`） | 弹出确认框 |
| 仅图片 / 视频数据（无文件路径） | 按下方"原样落盘"规则生成临时文件，再弹出确认框 |

**原样落盘规则（不解码、不重编码）**

1. 有文件路径时一律使用原文件字节，保留格式、EXIF、动图。
2. 仅有图片数据时，遍历 `NSPasteboardItem.types`，按写入顺序选取第一个**非 TIFF** 的图片 UTType（JPEG / PNG / GIF / HEIC / WebP 等），将该数据原样写入临时文件，扩展名取自 `UTType.preferredFilenameExtension`（Android 媒体扫描与相册依赖扩展名识别类型）。文件名 `paste_yyyyMMdd_HHmmss.<ext>`。视频数据同理。
3. 仅有 TIFF 时（通常为 macOS 生成的转换副本，Android 相册基本不支持），无损转为 PNG，并在确认框标注"原始为 TIFF，已无损转为 PNG"。
4. 推送使用 `adb push -a` 保留修改时间。

**确认框**（设备窗口上的 sheet）

- 列出每个文件：文件名、大小、实际格式与来源（如 `paste_….jpg · JPEG · 原始数据`）。HEIC 额外提示"部分 Android 设备无法预览"，并提供"转为 JPEG"选项，默认不勾选。
- APK：默认"安装"，可切换为"仅推送"。
- 目标目录：默认 `/sdcard/Download`，下拉含 Pictures、DCIM、Documents 与最近使用目录。
- "图片和视频加入相册"：推送后触发媒体扫描（具体命令在实现时按 Android 版本验证兼容性）。
- 同名文件：覆盖 / 自动重命名。
- "记住选择，以后不再询问"：之后直接按上次设置推送，仅显示进度；可在设置中改回"每次询问"。
- 推送中窗口底部显示进度（含百分比）；完成后提示，可跳转文件浏览器查看。

**iOS**：无公共存储，"目标目录"换为"目标 App"（仅开启文件共享的 App，经 `devicectl` 复制）；IPA 默认安装；不支持写入相册。

**实现归属**：P3c，与第 9 项文件传输共用同一推送队列与进度显示。拖拽属于明确意图，保持不弹确认框。AI 侧复用 `push_file` / `install_app`，不新增 MCP 工具。

## 5. AI 接口（MCP）

### 5.1 接入

- 工作台右栏「AI」标签"添加到 Claude Code"：`claude mcp add --scope user tandem -- <App 包内 tandem-mcp 的实际路径>`（2026-10-18 由设置页移到「AI」标签，详见 `2026-10-18-p2-mcp-design.md`）。
- 提供可复制的 JSON 配置供其他 MCP 客户端使用。
- `tandem-mcp` 拉起 App 时带 `--background`，App 不打开工作台、只常驻菜单栏。
- AI 操作一台未在投屏的设备时自动启动其会话，空闲 5 分钟后停止（人仍在查看则继续）。

### 5.2 约定

- 每个工具带 `device` 参数（serial 或用户别名）；仅连一台时可省略，多台时省略则报错并列出可选设备。
- **坐标系 = 截图坐标**：设备当前方向的屏幕比例、长边固定 1280，截图像素尺寸即操作坐标空间；UI 树坐标同样换算到该空间；App 负责换算为设备坐标。

### 5.3 工具清单

| 类别 | 工具 |
|---|---|
| 设备 | `list_devices`（型号、系统、连接方式、能力） |
| 感知 | `screenshot(hq?)`、`get_ui_tree(all?)`、`current_app`、`wait_for(text \| id, timeout)` |
| 操作 | `tap(x,y \| element)`、`long_press`、`swipe`、`scroll(direction)`、`type_text(text, submit?)`、`press_key(back/home/recents/enter/…)` |
| 剪切板 | `get_clipboard`、`set_clipboard(text, paste?)` |
| 应用 | `current_app`、`launch_app`、`install_app(path)`、`uninstall_app`、`clear_app_data`、`force_stop`、`open_url` |
| 系统 | `get_network_state`、`set_network(wifi\|data\|airplane, on\|off)`、`get_dev_options`、`set_dev_option`、`get_system_settings`、`set_system(dark_mode\|app_locale\|font_scale, …)` |
| 调试 | `get_logs(app?, level?, grep?, lines)`、`push_file`、`pull_file`、`shell(cmd)` |

工具列表按设备 Capability 过滤。

### 5.4 UI 树

- 底层 `uiautomator dump`（通过 `exec-out`），默认仅返回可交互或含文本的元素，每行一个：
  `[12] Button "登录" id=login_btn (540,1820)`
- `tap(element=12)` 或 `tap(element="登录")` 均可。
- 已知限制：每次 1～3 秒，动画中可能失败；失败自动重试一次。若后续性能不足，再考虑设备端无障碍服务辅助 App（不在本期范围）。

### 5.5 人机协作

- AI 每次操作在窗口显示点击涟漪与顶部提示（如"AI: tap 登录"）。
- 工作台底部「操作记录」按时间列出人与 AI 的操作（来源标签区分）及结果。
- 每设备"锁定，禁止 AI 操作"开关：锁定后操作类工具返回 `AI_LOCKED`，感知类（截图、UI 树、日志、读剪贴板）照常可用。
- `shell` 工具可在设置中整体关闭，默认开启。

## 6. iOS 支持（P4）

仅 USB。

| 能力 | 实现 | 备注 |
|---|---|---|
| 发现与信息 | `xcrun devicectl list devices --json-output` + 直连 usbmuxd | 依赖已安装 Xcode |
| 投屏 | CoreMediaIO 开启 `kCMIOHardwarePropertyAllowScreenCaptureDevices`，AVCaptureSession 采集 | 延迟约 100～200ms；首次需解锁并信任电脑 |
| 点击 / 输入 / UI 树 / 截图 | 内置 WebDriverAgent 源码，用用户开发团队签名安装；usbmux 端口转发后调用 HTTP 接口 | 首次设置向导选择团队；免费 Apple ID 签名 7 天过期，检测到后在设备连接时自动重签 |
| 剪切板 | WDA `setPasteboard` / `getPasteboard` | iOS 16+ 读取时 WDA 会短暂切到前台 |
| 装包 / Deeplink | `devicectl device install app` / `devicectl device process launch --payload-url` | |
| 网络、开发者开关、系统设置 | 不支持 | 面板置灰，MCP 不暴露 |
| 日志、文件 | 本期不做 | 后续评估 |

## 7. 错误处理

所有操作返回结构化错误 `{code, message, suggestion}`，面板与 MCP 共用同一套错误码，例如：

| code | 含义 / 建议 |
|---|---|
| `DEVICE_NOT_FOUND` | 设备不存在或已断开 |
| `DEVICE_UNAUTHORIZED` | 请在手机上允许 USB 调试 |
| `INJECT_PERMISSION_DENIED` | 国产 ROM 需打开"USB 调试（安全设置）"，附品牌路径 |
| `UNSUPPORTED` | 该设备 / 系统版本不支持此能力 |
| `AI_LOCKED` | 设备已锁定禁止 AI 操作 |
| `DEVICE_AMBIGUOUS` | 连接了多台设备，需指定 `device` |
| `WDA_SIGN_EXPIRED` | WDA 签名过期，正在重签或需连接设备 |
| `TIMEOUT` | 操作超时（MCP 请求默认 30 秒） |
| `INVALID_ARGUMENT` | 工具参数不合法 |
| `ELEMENT_NOT_FOUND` / `ELEMENT_AMBIGUOUS` | 按序号或文字找不到元素 / 匹配到多个（列出候选） |
| `APP_UNAVAILABLE` | `tandem-mcp` 无法拉起或连接 Tandem |

## 8. 测试策略

- **单元测试（无需真机）**：scrcpy 控制消息字节编码、视频帧头解析、UI 树 XML 解析（fixture）、截图坐标与设备坐标换算、各 shell 命令输出解析、错误码映射。
- **集成测试（真机 / 模拟器，手动触发）**：会话建立、截图、点击、剪切板、网络开关。
- **MCP 测试**：以假 ControlServer 测试协议层与工具参数校验。

## 9. 子项目与顺序

每个子项目单独出实施计划。执行顺序（2026-10-18 调整）：P1 → P3a → P2 → P3b → P3c → P4。

1. **P1 基础框架 + Android 投屏控制**：工程结构、DeviceCore、菜单栏、多设备窗口、USB 与无线连接、scrcpy 视频与输入、国产 ROM 检测。
2. **P2 ControlServer + MCP 核心**：`list_devices`、`screenshot`、`get_ui_tree`、`tap`/`long_press`/`swipe`/`scroll`、`type_text`、`press_key`、剪切板工具、`wait_for`、AI 操作可视化与锁定开关、右栏「AI」标签（详见 `2026-10-18-p2-mcp-design.md`）。
3. **P3 工作台 + 快捷面板 1～9 + 自定义按钮**，分三段（详见 `2026-10-18-p3a-workspace-design.md`）：
   - **P3a** 工作台外壳、截图、录屏、最近截图、操作记录、剪贴板标签；
   - **P3b** 网络、应用管理、打开链接、开发者开关、系统设置、自定义命令；
   - **P3c** 日志窗口、文件传输（含 ⌘V 粘贴文件、拖 APK 安装）。
   P2 之后完成的功能同步注册对应 MCP 工具。
4. **P4 iOS 驱动**。
