# P3c 日志窗口与文件传输设计文档

依据总设计 `docs/superpowers/specs/2026-10-17-tandem-design.md`（下称"总设计"）§3.5 第 4、6、9 项、§4.1、§5，以及 P3b 设计 `2026-10-18-p3b-quick-actions-design.md`。本文件覆盖 P3c；与总设计冲突时以本文件为准，并已同步回总设计。

## 1. 目标与范围

- **日志窗口**：每台设备一个独立窗口，按包名跟踪目标 App 的 logcat；支持级别 / 关键字过滤、暂停、导出。
- **文件传输**：右栏「文件」标签浏览设备目录、拉取到 Mac、从 Mac 推送；拖入文件推送。
- **⌘V 粘贴文件**：按总设计 §4.1 分流 Mac 剪贴板，文件与图片弹确认框后推送。
- **拖 APK 安装**：拖入 APK 直接安装。
- **MCP**：新增 `get_logs`、`push_file`、`pull_file`、`install_app`。

顺序：P1 → P3a → P2 → P3b（均已完成）→ **P3c** → P4。

不在 P3c：iOS 的日志与文件（总设计 §6）；文件删除、重命名、新建文件夹；日志的正则过滤。

## 2. 核心层

### 2.1 能力

`Capability` 新增 `files`、`logs`，Android 声明。能力概览中文名为：文件、日志。安装归入已有的 `apps`。

### 2.2 模型类型（DeviceCore）

- `RemoteFile`：`name`、`path`、`kind`（file / directory / symlink / other）、`size: UInt64`、`modified: Date`。
- `TransferProgress`：`bytes: UInt64`、`total: UInt64?`。
- `LogLevel`：`verbose, debug, info, warn, error, fatal`，对应字母 V / D / I / W / E / F，可比较大小。
- `LogEntry`：`time`（原始 `MM-dd HH:mm:ss.SSS` 字符串）、`pid`、`tid`、`level`、`tag`、`message`。
- `LogQuery`：`package: String?`（nil 表示全部）、`minLevel: LogLevel`、`grep: String?`、`lines: Int`。
- `LogSnapshot`：`entries: [LogEntry]`、`pids: [Int]`（用于过滤的 pid）、`note: String?`（如"缓冲中没有 com.demo 的记录"）。

### 2.3 DeviceActions 新增方法

协议扩展中的默认实现一律抛 `UNSUPPORTED`。

| 方法 | 说明 |
|---|---|
| `listDirectory(_ path: String) -> [RemoteFile]` | 不含 `.` 与 `..`，目录在前，再按名称排序 |
| `stat(_ path: String) -> RemoteFile?` | 不存在时返回 nil |
| `push(_ local: URL, to remote: String, progress:) ` | 文件夹递归推送；保留修改时间（等同 `adb push -a`） |
| `pull(_ remote: String, to local: URL, progress:)` | 先写 `<名>.part`，完成后改名；失败或取消时删除 `.part` |
| `install(apk: URL, progress:) -> String` | 返回包名 |
| `mediaScan(_ remotePaths: [String])` | 加入相册 |
| `pids(of package: String) -> [Int]` | `pidof`，未运行时为空 |
| `logSnapshot(_ query: LogQuery) -> LogSnapshot` | 见 §2.6 |
| `logStream() -> AsyncThrowingStream<LogEntry, Error>` | 全量 logcat，过滤在 App 侧做 |

`progress` 为 `@Sendable (TransferProgress) -> Void`。所有方法响应任务取消。

`shellChecked` 对 `logcat -d` 与 `pm install` 不套用「not found」/「Unknown command」的 `UNSUPPORTED` 判断（参数 `detectUnsupported: false`），因为它们的正常输出常含这些词。

### 2.4 AdbSync（AndroidDriver）

直接和 adb server 走 sync 协议，不经 adb 命令行，以获得精确进度。

- **连接**：端口取 `ADB_SERVER_SOCKET`（`tcp:<port>` 形式）或 5037，经现有 `ByteStream`（`TCPByteStream`）连 127.0.0.1。请求为 4 位十六进制长度前缀加内容：先 `host:transport:<serial>`，收到 `OKAY` 后发 `sync:`。连接失败时先执行一次 `adb start-server` 再重试；仍失败抛 `CONNECTION_FAILED`「无法连接 adb 服务」。
- **特性**：先查询 `host-serial:<serial>:features`。设备支持 `ls_v2` / `stat_v2` 时用 `LIS2` / `STA2`（64 位大小），否则用 `LIST` / `STAT`（v1，大小 32 位）。
- **SEND**：`<path>,<mode>`，文件 mode 取本地权限（默认 0644）；数据按 64 KB 分块 `DATA`；结束发 `DONE <mtime>`（本地修改时间，秒）；读取 `OKAY` 或 `FAIL <原因>`。sync 协议会自动创建上级目录。
- **RECV**：读取 `DATA` 直到 `DONE`；`FAIL` 时抛错。
- **QUIT**：每次会话结束发送并关闭连接。
- 每次传输独占一条 sync 连接；取消时关闭连接。
- 纯协议实现只依赖 `ByteStream`，测试用内存流模拟 adb server。

**路径规则**：sync 协议传原始路径，不经 shell，不需要转义；但设备路径必须为绝对路径，且不含 NUL 与换行，否则 `INVALID_ARGUMENT`。凡是经 shell 使用的设备路径（`rm`、`pm install`、媒体扫描）一律用 `ShellQuote.quote`。

### 2.5 文件、安装与媒体扫描

- **推送进度**：按已发送字节计算；文件夹推送时 `total` 为全部文件之和。
- **取消推送**：关闭连接后，经 shell `rm -f <路径>` 删除设备上的半成品。
- **同名处理**（App 层决定策略，核心层提供 `stat`）：
  - 覆盖：直接推送。
  - 自动改名：`a.jpg` → `a (1).jpg` → `a (2).jpg`…，用 `stat` 找第一个不存在的名字。
- **安装**：
  - 先推送到 `/data/local/tmp/tandem_<uuid>.apk`（有进度）。
  - 再执行 `pm install -r -d <临时路径>`，输出含 `Success` 为成功。
  - 无论成败，最后都删除临时文件。
  - 包名在安装前于 Mac 上读取：`/usr/bin/unzip -p <apk> AndroidManifest.xml` 取出二进制清单，由纯函数 `ApkManifest.packageName(_ data:)` 解析（AXML：字符串池加 `manifest` 元素的 `package` 属性），以真实 APK 为夹具单测。读不到时安装照常进行，返回「安装成功」而不带包名。
  - 失败时信息带上 `pm` 原始输出；常见错误码附中文建议：`INSTALL_FAILED_VERSION_DOWNGRADE`、`INSTALL_FAILED_UPDATE_INCOMPATIBLE`（签名不一致，需先卸载）、`INSTALL_FAILED_INSUFFICIENT_STORAGE`、`INSTALL_FAILED_NO_MATCHING_ABIS`、`INSTALL_PARSE_FAILED_*`（不是有效 APK）。
- **媒体扫描**：对每个路径执行 `am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d <ShellQuote.quote("file://" + 路径)>`。已在 SM-G9730（Android 12）上验证：推送 PNG 到 `/sdcard/Pictures` 并广播后，`content query --uri content://media/external/images/media` 能查到该行，命令返回 `Broadcast completed: result=0`；删除文件后再广播，行随之移出。注意该机型的 MediaProvider 对 FUSE 里新建、删除的文件本身就会即时入库、出库，广播的独立效果无法单独观测，但广播无副作用，保留作为其他 ROM 的兜底。若某设备上广播无效，可改用 `content call --uri content://media/external/file --method scan_file --arg <路径>`（路径加引号）。

### 2.6 日志

- **格式**：一律 `-v threadtime`：`MM-dd HH:mm:ss.SSS  PID  TID L TAG: message`。解析为纯函数；无法解析的行（如 `--------- beginning of main`）丢弃。
- **级别**：快照在设备端过滤，参数为 `ShellQuote.quote("*:<字母>")`（`*` 必须转义，否则会被设备 shell 展开）。流式读取不在设备端过滤。
- **pid 查找**（`package` 非 nil 时）：
  1. `pidof <包名>` 取当前 pid；
  2. 从缓冲中 ActivityManager 的 `Start proc <pid>:<包名>/…` 行收集近期用过的 pid（匹配 `Start proc (\d+):<包名>[/:]`，以真机输出为夹具）；
  3. 两者合并。
- **快照**（`logSnapshot`）：执行 `logcat -d -v threadtime -t 50000 <级别参数>`，只读缓冲中最新的 50,000 行（SM-G9730 上完整转储约 25.8 万行 / 31 MB / 18 秒，与 `get_logs` 的 30 秒超时太近）；pid 查找、`grep`、取最后 N 行都在这个窗口内进行。该调用不套用 `UNSUPPORTED` 判断（见 §2.3）。按 pid 集合过滤（`package` 为 nil 时不过滤）；`grep` 在 Mac 上做不区分大小写的子串匹配；取最后 `lines` 行。pid 集合为空时返回空结果与 note「缓冲中没有 <包名> 的记录」。
- **流**（`logStream`）：经 `ProcessRunner.stream` 运行 `adb -s <serial> logcat -v threadtime -T 1`（从最新一行起跟随，不回放整个缓冲），逐行解析产出 `LogEntry`；进程退出时流结束。`LogSession` 若发现流的第一条与历史补全的最后一条相同则丢弃，避免重复。
- 包名一律先经 `PackageName.validate`。

## 3. App 层

### 3.1 传输队列

- `TransferQueue`（`@MainActor @Observable`）：每台设备一个 FIFO 队列，一次执行一项。
- 任务：`push(local:[URL], dest:, conflict:, mediaScan:)`、`install(apk:)`、`pull(remote:, to:)`；状态为等待 / 进行中（进度）/ 完成 / 失败 / 已取消。
- 面板拖放、⌘V、「文件」标签、AI 都提交到这里；面板提交的每个任务结束时恰好写一条记录：完成、失败、「已取消」，或因设备断开而被取消的等待项「设备已断开」。AI 提交的任务由 AI 命令按 §4 标题记录一次，队列不重复写。
- 取消只取消当前项；设备断开时当前项失败、其余项取消，记录写明「设备已断开」。
- 进度回调在后台触发，节流到每 100 毫秒更新一次界面。

### 3.2 拖放

- 设备弹出窗口与工作台投屏区都接受文件拖放。
- APK（扩展名 `.apk`）直接安装；其余文件与文件夹推送到 `/sdcard/Download`，同名自动改名；不弹确认框（拖拽为明确意图）。
- 一次拖入多个时按顺序入队；混有 APK 与普通文件时各自按上述规则处理。
- 拖入悬停时在画面上叠加半透明提示：「松开以安装」「松开以推送到 Download」或两者并列。
- 设备没有 `files` 能力时不接受普通文件；没有 `apps` 能力时不接受 APK。

### 3.3 ⌘V 粘贴文件

设备窗口获得焦点时按 ⌘V，交给 `PasteFileResolver`：

| 剪贴板内容 | 行为 |
|---|---|
| 文本 | 写入设备剪贴板并粘贴（现有行为），不弹窗 |
| 文件 / 文件夹（`public.file-url`） | 弹确认框 |
| 仅图片 / 视频数据 | 按原样落盘规则生成临时文件，再弹确认框 |

**原样落盘规则**（照抄总设计 §4.1）：

1. 有文件路径时一律使用原文件字节。
2. 仅有数据时，遍历 `NSPasteboardItem.types`，按写入顺序选取第一个非 TIFF 的图片或视频 UTType，将数据原样写入临时文件；扩展名取自 `UTType.preferredFilenameExtension`；文件名 `paste_yyyyMMdd_HHmmss.<ext>`。
3. 仅有 TIFF 时无损转为 PNG，并在确认框标注「原始为 TIFF，已无损转为 PNG」。
4. 推送保留修改时间。

临时文件放在 App 的临时目录，推送完成或取消后删除。

**确认框**（设备窗口上的 sheet）：

- 文件清单：文件名、大小、格式与来源（如 `paste_….jpg · JPEG · 原始数据`）。
- HEIC 提示「部分 Android 设备无法预览」，提供「转为 JPEG」，默认不勾。
- APK：「安装」（默认）/「仅推送」。
- 目标目录：默认 `/sdcard/Download`；下拉含 `/sdcard/Pictures`、`/sdcard/DCIM`、`/sdcard/Documents` 与最近使用的 5 个目录（全局一份，存 UserDefaults）。
- 「图片和视频加入相册」：默认勾选（仅当清单中有图片或视频时显示）。
- 同名文件：覆盖 / 自动改名（默认）。
- 「记住选择，以后不再询问」：勾选后保存本次设置，之后 ⌘V 直接按此推送，只显示进度。设置页「粘贴文件时」可改回「每次询问」。

### 3.4 传输进度与提示

- 投屏区（设备窗口与工作台）底部一条细栏：`推送 a.jpg · 45% · 还有 2 项`、`安装 app.apk · 推送中 80%` / `安装中…`，带「取消」。
- 完成时显示提示条（复用 P3a 的提示条，8 秒）：「已推送到 /sdcard/Download/a.jpg」，带「在文件中查看」（跳到「文件」标签对应目录）；安装成功为「已安装 com.demo」。
- 失败时提示条标红并显示原因。

### 3.5 「文件」标签

右栏新增「文件」标签（位于「快捷操作」之后），需要 `files` 能力。

- 顶部：「上级」按钮、可编辑的路径栏（回车跳转）、常用目录按钮 Download / DCIM / Pictures / Documents。
- 默认打开 `/sdcard/Download`；每台设备记住上次所在目录（不持久化）。
- 列表：名称、大小、修改时间；目录在前。双击目录进入；双击文件或选中后点「拉取」，拉到拉取目录，完成后在 Finder 中选中。
- 文件可直接拖到 Finder（file promise），放下时才开始拉取。
- 「推送文件…」按钮打开文件选择框（可多选、可选文件夹），推送到当前目录，同名自动改名。
- 「刷新」按钮；进入目录与传输完成后自动刷新当前目录。
- 读取失败（如权限不足）时列表位置显示原因。
- 拉取目录默认 `~/Downloads`，设置页可改，存 UserDefaults。拉取同名时自动改名，不覆盖。

### 3.6 日志窗口

- 入口：「快捷操作 › 应用」分段的「日志」按钮，打开该设备的日志窗口（每台设备一个，已打开则前置），目标初始为该分段的当前目标；无目标时为「全部」。
- **工具栏**：
  - 目标下拉：「前台 App（<包名>）」、已固定的包名、「全部」。「前台 App」在选择时读取一次前台包名并固定下来，之后不随前台切换而变；要换目标需重新选择。
  - 最低级别：V / D / I / W / E / F（默认 V）。
  - 关键字：不区分大小写的子串。
  - 暂停 / 继续、清空、导出。
- **跟踪**：
  - 每 2 秒执行一次 `pids(of:)`；pid 集合变化时插入分隔行「—— 进程重启（pid 1234 → 5678）——」。
  - App 未运行时显示「等待进程启动…」，启动后自动接上。
  - 打开窗口或切换目标时，先用 `logSnapshot`（`lines` 2000）补上缓冲中已有的历史日志，再接上流。
- **缓冲**：每个窗口最多保留 50,000 条，超出丢弃最早的。级别与关键字只过滤显示，不丢弃数据。
- **列表**：时间、pid、级别（颜色取自 `Theme`）、tag、内容；等宽字体；可多选，⌘C 按导出格式复制。列表为 `NSTableView`，行高固定、单行显示；过长的内容在列表中截断，完整文本见悬停提示、复制与导出。是否跟随最新由滚动位置决定：默认自动滚到最新；用户向上滚动后停止自动滚动并显示「回到最新」，点击后恢复跟随。
- **暂停**：冻结显示，后台继续收集，提示「已暂停 · 新增 N 条」。
- **导出**：当前过滤后的内容存为 `.txt`（`NSSavePanel`，默认名 `<设备名>_<包名或all>_yyyyMMdd_HHmmss.txt`）。
- **断开**：显示「设备已断开」，重新连接后自动续上。关闭窗口即停止 logcat 进程。
- 日志解析在后台进行，按 100 毫秒批量提交到界面。

### 3.7 记录与执行路径

- 面板操作经 `DeviceCommands` → `ActionRunner`（来源「你」）；读取（列目录、日志）不记录。
- 记录标题：`推送 a.jpg`（多个时 `推送 3 个文件`）、`安装 app.apk`、`拉取 x.log`。
- 传输任务的记录规则见 §3.1；AI 提交的任务只由 AI 命令记录一次。

### 3.8 设置页

新增：

- 「拉取目录」（选择…）。
- 「粘贴文件时」：每次询问 / 按上次的选择直接推送。

## 4. MCP 工具

执行路径沿用 P2 / P3b：`ToolRegistry` → `AICommands` → `ActionRunner`（来源 AI）；均不需要投屏会话。

| 工具 | 参数 | 类别 | 能力 | 说明 |
|---|---|---|---|---|
| `get_logs` | `app?`、`level?`（V/D/I/W/E/F，默认 V）、`grep?`、`lines?`（默认 200，1–2000） | 感知 | logs | 规则见 §2.6；首行注明过滤条件与 pid；总长 64 KB 截断并注明 |
| `push_file` | `path`（Mac 绝对路径）、`dest?`（设备路径，默认 `/sdcard/Download/`） | 操作 | files | `dest` 以 `/` 结尾视为目录；同名自动改名；返回设备上的实际路径 |
| `pull_file` | `path`（设备绝对路径）、`dest?`（拉取目录下的相对子目录） | 操作 | files | 标准化后不得跳出拉取目录；同名自动改名；返回 Mac 绝对路径 |
| `install_app` | `path`（Mac 上的 `.apk`） | 操作 | apps | 返回包名与「安装成功」 |

- 操作类受「禁止 AI 操作」限制（`AI_LOCKED`）；`get_logs` 照常可用。
- Mac 路径：`push_file` / `install_app` 可读取任意本机绝对路径，文件须存在；`pull_file` 只写入拉取目录。
- AI 的传输同样进入 §3.1 的队列，界面可见进度。
- 调用超时：`push_file` / `install_app` 为 30 秒加每 10 MB 10 秒（按本地文件或文件夹总大小），最多 10 分钟；`pull_file` 为 10 分钟；`get_logs` 30 秒；`clear_app_data` / `uninstall_app` 为 40 秒（P3b 遗留项）。计算大小时累计到已达 600 秒所需的大小，或遍历满 20,000 项即停止，避免遍历超大目录耗时。
- 记录标题：`get_logs`（仅失败时记录）、`push_file a.jpg`、`pull_file /sdcard/x.log`、`install_app app-debug.apk`。

## 5. 错误处理

| 情况 | 结果 |
|---|---|
| adb server 连不上 | `adb start-server` 后重试一次；仍失败 `CONNECTION_FAILED`「无法连接 adb 服务」 |
| sync `FAIL` | 带上设备原因，如「推送失败：Permission denied」 |
| 设备或 Mac 空间不足 | 失败，删除半成品 |
| 安装失败 | 带上 `pm` 原始输出，常见错误码附中文建议（§2.5） |
| 本机路径不存在 / 不是 `.apk` / `pull_file` 目标越界 / 设备路径不是绝对路径或含换行 | `INVALID_ARGUMENT` |
| 日志：App 未运行且缓冲中无记录 | 空结果加说明，不算错误 |
| 传输中设备断开 | 当前项失败，其余项取消，记录写明「设备已断开」 |
| 媒体扫描失败 | 推送仍算成功，提示条附「未能加入相册」 |

## 6. 测试

**单元测试**

- `AdbSync`（内存流模拟 adb server）：请求长度前缀；`transport` 失败；features 决定 v1 / v2；LIST / LIS2、STAT / STA2 解析；SEND 按 64 KB 分块与 `DONE` 带 mtime；RECV 多块拼接；`FAIL` 原因透传；中途 EOF；取消关闭连接。
- 日志解析（真机输出为夹具）：threadtime 各级别；tag 含空格与冒号；多行堆栈（每行独立一条）；`beginning of` 行丢弃；`Start proc` 新旧两种写法。
- `logSnapshot`：pid 过滤、`grep` 子串、取最后 N 行、空集合 note；级别参数被单引号包裹。
- 安装：临时路径推送、`pm install` 成功与常见失败、失败时仍删除临时文件。
- `PasteFileResolver`：文本；文件 URL；首个非 TIFF 类型与扩展名；仅 TIFF 时转 PNG；文件名格式。
- 同名改名：`a.jpg`、`a (1).jpg` 已存在时得到 `a (2).jpg`；无扩展名文件。
- `TransferQueue`：FIFO、一次一项、取消当前项、断开时其余取消、记录标题。
- `pull_file` 路径：`..`、绝对路径、符号链接越界被拒；同名改名。
- `ToolRegistry`：新工具参数校验、锁定、超时计算。

**真机集成测试**（`TANDEM_TEST_SERIAL`；只做可逆操作，结束时清理）

- 推送一个小文件到 `/sdcard/Download/tandem_test_<uuid>`，`stat` 核对大小，拉回比对字节，删除。
- `listDirectory("/sdcard")` 含 `Download`。
- 安装测试夹具中的最小 APK 再卸载（夹具的生成方式写在实现计划中）。
- `logSnapshot` 能解析出至少一条记录。

**人工验收清单**：拖放（APK、普通文件、文件夹、混合）；⌘V 的三类剪贴板与确认框各选项；加入相册；「记住选择」与设置页改回；「文件」标签浏览、拉取、拖到 Finder、推送；日志窗口跟踪进程重启、历史补全、暂停、导出、断开重连；AI 端到端调用四个工具；锁定时的表现。
