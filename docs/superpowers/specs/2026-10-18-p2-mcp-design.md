# P2 ControlServer + MCP 设计文档

依据总设计 `docs/superpowers/specs/2026-10-17-tandem-design.md`（下称"总设计"）§2、§5、§7、§9。本文件覆盖 P2；与总设计冲突时以本文件为准，并已同步回总设计。

## 1. 目标与范围

在 Claude Code 等 MCP 客户端里执行 `claude mcp add tandem -- …/tandem-mcp` 后，AI 能对 Tandem 管理的设备截图、读 UI 树、点按、滑动、输入、读写剪贴板，完成一段完整操作；人同时在工作台操作同一台设备不冲突，并能看到 AI 做了什么、随时禁止 AI 操作。

顺序：P1（已完成）→ P3a（已完成）→ **P2** → P3b → P3c → P4。

P2 包含：

- App 内 ControlServer（Unix socket，JSON-RPC）与 `tandem-mcp` CLI（stdio MCP）；
- 工具：`list_devices`、`screenshot`、`get_ui_tree`、`wait_for`、`tap`、`long_press`、`swipe`、`scroll`、`type_text`、`press_key`、`get_clipboard`、`set_clipboard`；
- AI 自动启动会话、操作可视化、每设备「禁止 AI 操作」、右栏「AI」标签、菜单栏 AI 状态。

不在 P2：`current_app` 与应用 / 系统 / 调试类工具（随 P3b、P3c 的功能一起注册）、`shell` 工具及其设置开关、设备别名。

## 2. 进程与接入

```
Claude Code ──stdio(MCP)── tandem-mcp ──control.sock(JSON-RPC)── Tandem.app
```

### 2.1 tandem-mcp

- Xcode tool target，构建后放进 `Tandem.app/Contents/MacOS/tandem-mcp`；逻辑在 TandemCore 的 `MCPBridge` 库中，CLI 只有 `main.swift`。
- 本地直接应答 `initialize`、`ping`、`notifications/initialized`，声明 `capabilities.tools.listChanged = true`；`tools/list`、`tools/call` 转发给 App；App 推来的 `tools/list_changed` 转成 MCP 的 `notifications/tools/list_changed`。
- 第一次需要转发时才连接 socket。连不上时由自身路径（`…/Tandem.app/Contents/MacOS/tandem-mcp` 向上三级）得到 App 位置，执行 `open -g -a <Tandem.app> --args --background`，每 0.5 秒重试，最多 15 秒；仍失败返回 `APP_UNAVAILABLE`。
- 连接建立后先发 `hello`（协议版本、MCP 客户端名称与版本，取自 `initialize` 的 `clientInfo`）。版本不一致时所有调用返回错误，提示重启 Tandem（只会在 App 更新后旧 CLI 进程仍在运行时发生）。
- 调用中途连接断开：本次返回 `APP_UNAVAILABLE`，下次调用重新连接 / 拉起。不重放进行中的调用（操作类工具重放可能执行两次）。

### 2.2 后台拉起

App 启动参数含 `--background` 时不打开工作台，只常驻菜单栏；设备发现、ControlServer、AI 自动启动的会话照常工作。App 已在运行时 `open -g` 不改变任何窗口。

### 2.3 ControlServer

- 监听 `~/Library/Application Support/Tandem/control.sock`；目录权限 0700、socket 0600；启动时删除残留的 socket 文件，退出时关闭并删除。
- 分帧：一行一条 JSON（与 MCP stdio 相同）。每个连接独立，同一连接上的请求可并发处理；同一设备上的操作由 `DeviceSession` 串行执行。
- 方法：`hello`、`tools/list`、`tools/call`；服务端通知：`tools/list_changed`。
- 记录已连接客户端（名称来自 `hello`），供「AI」标签与菜单栏显示。
- 启动失败（如 socket 无法创建）：「AI」标签显示原因，App 其他功能照常。

## 3. 工具

### 3.1 通用约定

**设备参数** `device`（除 `list_devices` 外所有工具可选）：依次按逻辑 id、adb serial、设备名（不区分大小写，完全匹配）查找。省略时：只连接了一台 → 用它；没有 → `DEVICE_NOT_FOUND`；多台 → `DEVICE_AMBIGUOUS`，信息中列出可选设备（id 与名称）。按名称匹配到多台同样返回 `DEVICE_AMBIGUOUS`。

**坐标空间**：设备当前方向的屏幕比例，长边固定为 1280（屏幕更小时同样放大到 1280）。这样投屏帧（Wi-Fi 下分辨率会降低）、screencap、UI 树三种来源算出的空间一致。截图像素尺寸、UI 树坐标、点按坐标都在这个空间中。App 把坐标除以空间宽高得到 0…1 归一化坐标交给 `InputAction`。比例取自会话的视频尺寸（操作类工具都需要会话在跑）、UI 树根节点 bounds 或 screencap 图片尺寸。

**工具属性**：每个工具声明**类别**（感知 / 操作，操作类受锁定限制）与**是否需要会话**（需要时自动启动，§4.1）。

**超时**：默认 30 秒；`wait_for` 以自己的 `timeout` 为准。

### 3.2 清单

| 工具 | 参数 | 类别 | 需要会话 | 行为 |
|---|---|---|---|---|
| `list_devices` | — | 感知 | 否 | 每台设备：id、名称、系统、连接方式、状态、是否投屏中、是否禁止 AI、可用工具 |
| `screenshot` | `hq?` | 感知 | 否 | 会话 running 时取最新帧，缩放后编码为 JPEG；会话未运行或 `hq=true` 时走 `DeviceActions.screenshot()`（screencap），缩放后编码为 PNG。返回 image 内容块 + 一行文字（尺寸、来源） |
| `get_ui_tree` | `all?` | 感知 | 否 | 默认只列可交互或有文字 / content-desc 的元素，`all=true` 列全部；一行一个：`[12] Button "登录" id=login_btn (540,1820)`，坐标为元素中心。结果按设备缓存，供 `tap(element: 12)` 使用。失败自动重试一次 |
| `wait_for` | `text?` / `id?`（至少一个）、`timeout?`（秒，默认 10，最长 60） | 感知 | 否 | 反复读 UI 树（上一次读完立即读下一次），直到出现匹配元素，返回该元素一行并更新缓存；超时返回 `TIMEOUT` |
| `tap` | `x`,`y` 或 `element` | 操作 | 是 | 见 §3.3 元素查找；按下后立即抬起 |
| `long_press` | 同 `tap`，`duration_ms?`（默认 800） | 操作 | 是 | 按下、等待、抬起 |
| `swipe` | `x1`,`y1`,`x2`,`y2`，`duration_ms?`（默认 300） | 操作 | 是 | 按下，约每 16ms 线性插值一次 move，抬起 |
| `scroll` | `direction`（up / down / left / right），`x?`,`y?`（默认屏幕中心） | 操作 | 是 | 用滑动实现（不用滚轮事件，原因见总设计 §3.3）。`down` 表示查看下方内容，即手指向上滑；滑动距离为对应方向屏幕边长的 60%，以给定点为中点，超出屏幕时截断 |
| `type_text` | `text`，`submit?` | 操作 | 是 | 发 `InputAction.text`；非 ASCII 走"写设备剪贴板 + 粘贴"，会覆盖设备剪贴板（写在工具描述中）；`submit=true` 时再按一次 enter |
| `press_key` | `key` | 操作 | 是 | `back` / `home` / `recents` / `enter` / `delete` / `tab` / `up` / `down` / `left` / `right` / `volume_up` / `volume_down` / `power`，映射到 `DeviceKey` |
| `get_clipboard` | — | 感知 | 是 | 读取设备剪贴板文本；为空或非文本时返回明确提示（`TIMEOUT` 附"设备剪贴板可能为空或不是文本"） |
| `set_clipboard` | `text`，`paste?` | 操作 | 是 | 经 `ClipboardService.write`，进剪贴板历史 |

### 3.3 元素查找（`tap` / `long_press`）

- `element` 为数字：指该设备最近一次 `get_ui_tree` / `wait_for` 缓存中的序号；没有缓存或序号不存在 → `ELEMENT_NOT_FOUND`，建议先调用 `get_ui_tree`。缓存不会因屏幕变化自动失效，由 AI 自行决定何时重新读取。
- `element` 为字符串：现读 UI 树，按 text 或 content-desc 先完全匹配、无结果再包含匹配；唯一则点其中心；多个 → `ELEMENT_AMBIGUOUS`，信息中列出候选（序号 + 一行描述），并更新缓存以便按序号再点；没有 → `ELEMENT_NOT_FOUND`。
- `x,y` 与 `element` 同时给出或都缺 → `INVALID_ARGUMENT`。

### 3.4 工具列表过滤

`tools/list` 返回当前已连接设备能力并集所需的工具，`list_devices` 始终在内。没有任何已连接设备时返回全部工具（调用时再报 `DEVICE_NOT_FOUND`），避免 AI 一开始看不到工具。并集变化时推送 `tools/list_changed`。

| 能力 | 工具 |
|---|---|
| `screenshot` | `screenshot` |
| `uiTree`（新增） | `get_ui_tree`、`wait_for` |
| `touch` | `tap`、`long_press`、`swipe`、`scroll` |
| `text` | `type_text` |
| `keys` | `press_key` |
| `clipboard` | `get_clipboard`、`set_clipboard` |

调用时目标设备不具备所需能力 → `UNSUPPORTED`。

### 3.5 结果与错误

- 工具执行失败（含参数不合法）以 MCP 结果 `isError: true` 返回，文字为 `CODE: 信息。建议：…`，AI 能看到并调整。
- JSON-RPC 错误只用于协议层问题：未知方法、消息格式错误、未知工具名。

## 4. 执行路径

### 4.1 AI 自动启动会话

- `MirrorSet` 新增 `ai` 集合：`wanted = (工作台打开 ? kept : ∅) ∪ popped ∪ ai`。
- 需要会话的工具：设备未锁定时加入 `ai`，等待会话进入 running，最多 10 秒；超时返回会话的失败原因（如 `INJECT_PERMISSION_DENIED` 附品牌路径），没有失败原因则返回 `TIMEOUT`。
- AI 对某台设备的每次调用（任何工具）都刷新其最近使用时间；5 分钟没有调用则移出 `ai`。若仍在 `kept`（工作台打开）或 `popped` 中，会话继续运行，否则停止。
- 锁定的设备不加入 `ai`。
- 进入 / 离开、超时判断写成 `AppPolicy` 纯函数。

### 4.2 组件（`App/AI/`）

- **`ToolRegistry`**：工具表（名称、描述、Schema、所需能力、类别、是否需要会话、执行函数），提供 `list(capabilities:)` 与 `call(name:arguments:client:)`。
- **`AICommands`**（@MainActor）：AI 工具的执行层，与 `DeviceCommands` 并列，同样经 `ActionRunner` 执行（来源 `.ai`）。不复用 `DeviceCommands.screenshot`，因为那条路径会存文件、写 Mac 剪贴板、弹提示条。负责设备解析、锁定检查、会话就绪、坐标换算、元素查找与缓存。
- **`AIPresence`**（@MainActor @Observable）：每台设备的最近使用时间（驱动 §4.1 空闲超时）与最近一次 AI 动作（驱动 §5.2 可视化）。
- **`ControlServer`**：§2.3。

### 4.3 对现有代码的调整

- **`ActionRunner`**：来源为 `.ai` 的失败只写操作记录，不设置 `lastError`，避免 AI 的错误显示在面板上打断人。
- **`ClipboardService.read`**：新增参数控制是否写 Mac 剪贴板与面板预览；AI 读取时都不写，历史照常记录。
- **会话不 running 时 `send` 静默丢弃**：`AICommands` 在发送前检查会话状态，不 running 就报错，不把丢弃当成功。
- **`DeviceActions`** 新增 `uiTree() async throws -> UITree`。

### 4.4 TandemCore

- **`ControlProtocol`**（新 target，无依赖）：JSON-RPC 2.0 请求 / 响应 / 通知、按行读写、Unix socket 收发、`ToolDescriptor`、`ToolResult`（text / image 内容块 + `isError`，`ToolResult.failure(code:message:suggestion:)` 生成错误结果）、协议版本常量。
- **`MCPBridge`**（新 target，依赖 ControlProtocol）：§2.1 的全部逻辑；stdio、socket 连接与"拉起 App"均可注入，便于测试。
- **DeviceCore**：`UITree` / `UIElement`（类名、text、content-desc、resource-id、设备像素 bounds、是否可点击 / 可滚动 / 可编辑）；`Capability.uiTree`；`DeviceError.Code` 新增 `INVALID_ARGUMENT`、`ELEMENT_NOT_FOUND`、`ELEMENT_AMBIGUOUS`、`APP_UNAVAILABLE`。
- **AndroidDriver**：`uiautomator dump` 到设备临时文件，再 `exec-out cat` 读回并解析；根节点 bounds 即当前方向屏幕尺寸。Android 设备声明 `uiTree` 能力。
- **MediaKit**：`ScreenshotEncoder`——输入 `CVPixelBuffer` 或 PNG 数据，按 §3.1 规则缩放，输出 JPEG 或 PNG 与像素尺寸。

## 5. 人机协作与界面

### 5.1 操作记录

- 操作类工具每次调用都写一条（来源 AI），描述如 `tap 登录`、`tap (640,1820)`、`swipe (640,2000)→(640,800)`、`输入文字（12 字）`；输入内容与剪贴板内容不写进记录。
- 感知类工具只在失败时记录（AI 频繁截图会刷满记录）。
- 锁定拒绝也记一条失败（`禁止 AI 操作`），人能看到 AI 试过。

### 5.2 可视化

工作台投屏区与弹出窗口都显示，数据来自 `AIPresence`，坐标沿用 `ViewGeometry` 的归一化 → 视图换算；视图只观察，不参与执行。

- `tap`：落点处一个强调色扩散圆环；`long_press`：圆环停留到抬起。
- `swipe` / `scroll`：起点到终点一条渐隐轨迹。
- 顶部提示胶囊：`AI: tap 登录`，停留 2 秒，新提示替换旧提示。

### 5.3 锁定（禁止 AI 操作）

- 每台设备一个开关，位于「AI」标签，按设备 id 存 UserDefaults（重启后仍生效），默认关闭。
- 锁定后操作类工具返回 `AI_LOCKED`；感知类（含 `get_clipboard`）照常可用；不因 AI 调用自动启动会话（`get_clipboard` 在会话未运行时返回错误，建议在 Tandem 中打开该设备）。
- 左栏设备行显示小锁图标；菜单栏设备行后标注「禁止 AI」。

### 5.4 右栏「AI」标签

右栏标签变为「快捷操作 / 剪贴板 / AI」。自上而下：

1. **连接**（全局，未选设备时也显示）：服务状态（运行中 / 启动失败及原因），已连接客户端数与名称。
2. **接入**：
   - 「添加到 Claude Code」：经登录 shell（`/bin/zsh -lc`，GUI App 的 PATH 里通常没有 `claude`）先执行 `claude mcp remove --scope user tandem`（忽略失败，用于更新路径），再执行 `claude mcp add --scope user tandem -- '<tandem-mcp 路径>'`，显示成功或命令输出的错误。必须用 user 作用域：默认的 local 作用域绑定当前目录，从 App 里执行时毫无意义。
   - 可复制的命令文本，以及供其他 MCP 客户端使用的 JSON 配置。
   - 路径取运行中 App 包内 `tandem-mcp` 的实际位置，开发构建也能直接使用。
3. **当前设备**：「禁止 AI 操作」开关；会话因 AI 而运行时显示「AI 正在使用，空闲 5 分钟后停止」。

接入入口只放在这里，设置页不再放（调整总设计 §5.1）。

### 5.5 菜单栏

菜单顶部（「打开工作台」之上）加一行「AI：已连接 n 个客户端」或「AI：未连接」。图标不变。

## 6. 错误处理

| 情况 | 结果 |
|---|---|
| 设备解析失败 | `DEVICE_NOT_FOUND` / `DEVICE_AMBIGUOUS`（列出可选设备） |
| 设备不具备能力 | `UNSUPPORTED` |
| 设备锁定，调用操作类工具 | `AI_LOCKED`，记一条失败 |
| 会话 10 秒内未 running | 会话失败原因，否则 `TIMEOUT` |
| 参数不合法 | `INVALID_ARGUMENT`，信息指出哪个参数 |
| 元素不存在 / 多个 | `ELEMENT_NOT_FOUND` / `ELEMENT_AMBIGUOUS`（列候选） |
| UI 树 dump 失败（动画中、secure 页面） | 重试一次；仍失败则报错，建议稍后重试或改用截图 |
| CLI 拉不起 App / 连接中断 | `APP_UNAVAILABLE`，建议确认 Tandem 已安装且能正常打开 |
| CLI 与 App 协议版本不一致 | 错误提示重启 Tandem |
| App 退出 | 关闭 socket；进行中的调用返回 `APP_UNAVAILABLE` |
| ControlServer 启动失败 | 「AI」标签显示原因，其他功能照常 |

所有错误在 App 内统一为 `DeviceError`，由 `ToolRegistry` 转成 `ToolResult.failure`；CLI 自己产生的错误（`APP_UNAVAILABLE` 等）同样用 `ToolResult.failure`。

## 7. 测试

**单元测试**

- `ControlProtocol`：消息编解码；分行读写（半行、一次读到多行）。
- `MCPBridge`（内存管道模拟 stdio，假 ControlServer）：`initialize` 本地应答；`tools/list` / `tools/call` 转发；`list_changed` 转发；连接失败时调用注入的拉起函数并重试；15 秒仍失败返回 `APP_UNAVAILABLE`；版本不一致；连接中断后下次调用重连。
- `ToolRegistry` / `AICommands`（复用 FakeDeviceSession / FakeActions）：参数校验；设备解析（省略、多台、按名称、名称重复）；能力过滤与无设备时全量；锁定拒绝并写记录；坐标换算（竖屏、横屏、长边不足 1280）；元素按序号 / 文字查找、完全匹配优先、歧义；`scroll` 方向与距离；会话不 running 时报错；操作记录描述不含输入内容；AI 失败不设置 `lastError`。
- UI 树：XML fixture 解析、默认过滤、单行格式、根节点尺寸。
- `MirrorSet` / `AppPolicy`：`ai` 集合进出、5 分钟空闲移出、与 `kept` / `popped` 重叠时不停止、锁定设备不加入。
- `ScreenshotEncoder`：缩放后尺寸、不足 1280 不缩放、JPEG / PNG 输出可解码。
- `ClipboardService`：AI 读取不写 Mac 剪贴板与预览、仍记历史。

**端到端测试**：启动真实 `ControlServer`（临时 socket 路径 + 假设备），用 `MCPBridge` 走完 `initialize → tools/list → tools/call screenshot → tools/call tap`。

**真机集成测试**（设置 `TANDEM_TEST_SERIAL` 时运行）：`uiTree()` 返回非空，根节点尺寸与设备当前分辨率一致。

**人工验收清单**

- 在 Claude Code 中经「添加到 Claude Code」接入后，完成"截图 → 读 UI 树 → 点按 → 输入"。
- App 未运行时调用工具，App 自动在后台启动且不开窗口。
- 人在工作台滑动的同时 AI 点按，两者都生效。
- 锁定后操作类被拒、截图与 UI 树可用，操作记录有失败条目。
- AI 自动启动的会话空闲 5 分钟后停止；工作台中选中过的设备不受影响。
- 涟漪、轨迹与顶部提示在工作台和弹出窗口都出现。
- 两个 Claude Code 会话同时连接，「AI」标签显示 2 个客户端。
