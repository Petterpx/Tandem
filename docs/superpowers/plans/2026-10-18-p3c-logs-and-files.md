# P3c 日志窗口与文件传输 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 加入日志窗口、「文件」标签、拖放推送与 APK 安装、⌘V 粘贴文件，以及 `get_logs` / `push_file` / `pull_file` / `install_app` 四个 MCP 工具。

**Architecture:**
- **DeviceCore**：新增 `files`、`logs` 能力与文件、日志模型；`DeviceActions` 增加对应方法，协议扩展默认抛 `UNSUPPORTED`。
- **AndroidDriver**：
  - `AdbSync` 经 `ByteStream` 直连 adb server 走 sync 协议，负责列目录、STAT、SEND、RECV，提供精确进度；
  - `AndroidActions+Files/+Install/+Logs` 在其上实现推送、拉取、安装、日志；
  - 日志解析与 APK 清单解析写成纯函数，以真机输出和真实 APK 为夹具。
- **App**：
  - `TransferQueue` 按设备排队执行传输，并写操作记录；
  - `PasteFileResolver` 按总设计 §4.1 分流剪贴板；
  - `MirrorView` 接入拖放、⌘V 与进度栏，设备窗口与工作台共用；
  - 新增「文件」标签与日志窗口；
  - AI 侧在 `AICommands` 加四个命令，`ToolRegistry` 注册对应工具。

**Tech Stack:** Swift 6（严格并发）、SwiftUI、Swift Testing、XcodeGen、adb server sync 协议、Network.framework。

**Spec:** `docs/superpowers/specs/2026-10-18-p3c-logs-and-files-design.md`（总设计 `2026-10-17-tandem-design.md`；P3b 设计 `2026-10-18-p3b-quick-actions-design.md`）

## Global Constraints

- **工程**：最低系统 macOS 14；`SWIFT_VERSION: "6.0"`，严格并发；不引入第三方依赖；测试用 Swift Testing。
- **文件**：新增或删除 App / AppTests 下的文件后运行 `xcodegen generate`；`*.xcodeproj` 不提交。
- **测试命令**：
  - 包测试：`cd Packages/TandemCore && swift test`
  - App 测试：`xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' -derivedDataPath .build/xcode`
    - 必须用独立的 `-derivedDataPath`：用户的 Tandem 从默认 DerivedData 运行，共用路径会把它终止。
    - 测试宿主会另起一个 Tandem 实例，执行前先征得用户同意。
  - 真机测试：`PATH="$HOME/Library/Android/sdk/platform-tools:$PATH" TANDEM_TEST_SERIAL=R28M31LKJ1J swift test --filter AndroidIntegrationTests`，只做可逆操作，结束时清理。
- **索引与调用**：adb 调用一律用 `DeviceInfo.serial`；记录、设置、状态一律按逻辑 id。
- **执行路径**：
  - 面板操作只经 `DeviceCommands` → `ActionRunner`（传输经 `TransferQueue`，由它调用 `ActionRunner`）；
  - AI 操作只经 `AICommands` → `ActionRunner`（来源 `.ai`）；
  - 视图里不直接调用 adb 或 `DeviceActions`。
- **风格**：颜色只从 `Theme` 取；注释用中文，密度与现有代码一致；提交信息用英文 conventional commits，不加署名行。
- **路径规则**（spec §2.4）：
  - sync 协议传原始路径，不经 shell；
  - 设备路径须为绝对路径，且不含 NUL 与换行（`DevicePath.validate`）；
  - 凡经 shell 使用的设备路径一律 `ShellQuote.quote`。
- **照抄 spec 的值**：
  - sync 数据块 64 KB；
  - 日志窗口 50,000 条、历史补全 2000 行、pid 轮询 2 秒、界面批量提交 100 毫秒；
  - `get_logs` 默认 200 行，1–2000，64 KB 截断；
  - 最近目录 5 个；
  - 拉取目录默认 `~/Downloads`；推送默认 `/sdcard/Download`；
  - 安装临时路径 `/data/local/tmp/tandem_<uuid>.apk`；
  - 粘贴文件名 `paste_yyyyMMdd_HHmmss.<ext>`；
  - 同名改名 `a (1).jpg`；
  - 超时：`push_file` / `install_app` 为 30 秒加每 10 MB 10 秒，最多 10 分钟；`pull_file` 10 分钟；`get_logs` 30 秒。
- **文案**：错误、记录、提示文案照抄 spec §3、§4、§5。
- **工作分支**：`feat/p3c-logs-and-files`。

## Review Focus

1. **设备路径含 `'`、空格、中文、`$(...)`、换行**：sync 传原始路径照常工作；经 shell 的 `rm -f`、`mkdir -p`、`pm install`、媒体扫描不能拼出额外命令。由 Task 4 的 `shellPathsAreQuoted`、Task 6 的 `installTempPathQuoted` 固定。
2. **`pull_file` 写出拉取目录**：`..`、绝对路径、指向外部的符号链接都必须拒绝。由 Task 16 的 `pullDestinationCannotEscape` 固定。
3. **日志洪流**（`全部` 模式每秒数千行）：窗口不能卡死，内存有上限，暂停期间不丢数据。由 Task 14 的 `ringBufferDropsOldest`、`batchesAreCoalesced` 固定。
4. **传输中取消或设备断开**：设备与 Mac 上都不能留下半成品，队列其余项取消并写入记录。由 Task 3 的 `cancelClosesConnection`、Task 4 的 `cancelRemovesRemotePartial`、Task 9 的 `disconnectCancelsRest` 固定。
5. **边界文件**：0 字节文件、空文件夹、大于 4 GB 文件的大小。0 字节只发 `DONE`；空文件夹要建出来；v2 的 STAT 取 64 位大小。由 Task 3 的 `zeroByteFileSendsOnlyDone`、Task 2 的 `stat2ReportsLargeSize`、Task 4 的 `emptyFolderIsCreated` 固定。

---

### Task 1: DeviceCore 模型、能力与协议

**Files:**
- Create: `Packages/TandemCore/Sources/DeviceCore/FileTypes.swift`、`LogTypes.swift`
- Modify: `Packages/TandemCore/Sources/DeviceCore/Capability.swift`、`DeviceActions.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Adb/AndroidDriver.swift`（能力集合加 `files`、`logs`）、`App/Workspace/QuickActionsTab.swift`（`Capability.title`：文件、日志）
- Modify: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidDriverTests.swift`（期望能力集合）
- Test: `Packages/TandemCore/Tests/DeviceCoreTests/FileTypesTests.swift`

**Interfaces:**
- Produces（全部 `public`，带显式 `public init`）：
  - `Capability` 新增 `files, logs`
  - `struct RemoteFile: Equatable, Sendable { enum Kind: Sendable { case file, directory, symlink, other }; var name: String; var path: String; var kind: Kind; var size: UInt64; var modified: Date }`
  - `struct TransferProgress: Equatable, Sendable { var bytes: UInt64; var total: UInt64?; var fraction: Double? }`：fraction 在 total 为 nil 或 0 时为 nil
  - `typealias ProgressHandler = @Sendable (TransferProgress) -> Void`
  - `enum LogLevel: String, CaseIterable, Comparable, Sendable { case verbose = "V", debug = "D", info = "I", warn = "W", error = "E", fatal = "F" }`
  - `struct LogEntry: Equatable, Sendable { var time: String; var pid: Int; var tid: Int; var level: LogLevel; var tag: String; var message: String }`
  - `struct LogQuery: Equatable, Sendable { var package: String?; var minLevel: LogLevel = .verbose; var grep: String?; var lines: Int = 200 }`
  - `struct LogSnapshot: Equatable, Sendable { var entries: [LogEntry]; var pids: [Int]; var note: String? }`
  - `enum DevicePath { static func validate(_ s: String) throws -> String }`：不以 `/` 开头或含 `\0`、`\n`、`\r` 时，抛 `INVALID_ARGUMENT`「设备路径不合法：<s>」
  - `DeviceActions` 新增以下方法，默认实现均抛 `DeviceError.unsupported("该设备不支持此操作")`：
    - `listDirectory(_ path: String) async throws -> [RemoteFile]`
    - `stat(_ path: String) async throws -> RemoteFile?`
    - `push(_ local: URL, to remote: String, progress: @escaping ProgressHandler) async throws`
    - `pull(_ remote: String, to local: URL, progress: @escaping ProgressHandler) async throws`
    - `install(apk: URL, progress: @escaping ProgressHandler) async throws -> String?`：返回包名，读不到时为 nil
    - `mediaScan(_ remotePaths: [String]) async throws`
    - `pids(of package: String) async throws -> [Int]`
    - `logSnapshot(_ query: LogQuery) async throws -> LogSnapshot`
    - `logStream() throws -> AsyncThrowingStream<LogEntry, any Error>`

- [ ] **Step 1: 写失败测试**：
  - `devicePathValidation`：`/sdcard/a b'c.jpg` 通过；`sdcard/x`、`/a\nb`、`""` 抛 INVALID_ARGUMENT。
  - `logLevelOrdering`：`.warn > .info`，`LogLevel(rawValue: "E") == .error`。
  - `progressFraction`：`TransferProgress(bytes: 50, total: 200).fraction == 0.25`；total 为 nil 时 fraction 为 nil。
  - `newDefaultsAreUnsupported`：只实现 screenshot / uiTree 的替身调用 `listDirectory` 抛 UNSUPPORTED。
- [ ] **Step 2: 运行确认失败**：`cd Packages/TandemCore && swift test --filter FileTypesTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 包测试与 App 测试通过**（能力概览多出 2 行）。
- [ ] **Step 5: 提交** `feat(core): file and log models, capabilities and actions protocol`

### Task 2: AdbSync：连接、features、STAT 与 LIST

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/Adb/AdbSync.swift`
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AdbSyncTests.swift`（用 `Support/InMemoryByteStream`）

**Interfaces:**
- 协议以 AOSP `packages/modules/adb/file_sync_protocol.h` 与 `SERVICES.TXT` 为准：
  - host 请求为 4 位小写十六进制长度加内容，应答为 `OKAY` 或 `FAIL` 加 4 位十六进制长度与信息；
  - sync 包为 4 字节 id 加小端 `UInt32`。
- Produces（`AndroidDriver` 内 public）：
  - `enum AdbHost`：
    - `static func request(_ stream: any ByteStream, _ service: String) async throws`：发请求并读应答；`FAIL` 时抛 `CONNECTION_FAILED`，信息带原因。
    - `static func features(_ stream: any ByteStream, serial: String) async throws -> Set<String>`：`host-serial:<serial>:features`，应答为 4 位十六进制长度加逗号分隔列表。
  - `final class AdbSyncSession: @unchecked Sendable`：
    - `static func open(_ stream: any ByteStream, serial: String, features: Set<String>) async throws -> AdbSyncSession`：先 `host:transport:<serial>`，再 `sync:`。
    - `func stat(_ path: String) async throws -> RemoteFile?`：有 `stat_v2` 时用 `STA2`（64 位 size，error 非 0 视为不存在），否则用 `STAT`（mode 为 0 视为不存在）。
    - `func list(_ path: String) async throws -> [RemoteFile]`：有 `ls_v2` 时用 `LIS2`（`DNT2`），否则用 `LIST`（`DENT`）；去掉 `.` 与 `..`；`kind` 由 mode 的 `S_IFMT` 判定。
    - `func quit()`：发 `QUIT` 并关闭。
  - `RemoteFile.path` 为父路径与名称拼接，处理末尾 `/`。

- [ ] **Step 1: 写失败测试**：
  - `requestHasHexLengthPrefix`：`AdbHost.request(s, "host:transport:S")` 写出 `"0010host:transport:S"`。
  - `transportFailCarriesReason`：应答 `FAIL0012device 'S' not found` 时，抛 CONNECTION_FAILED，message 含 `device 'S' not found`。
  - `featuresParsed`：应答 `OKAY` + `001bshell_v2,stat_v2,ls_v2,cmd` 时，结果含 `ls_v2`。
  - `statV1`：`STAT` 应答 mode `0o100644`、size 10、mtime 1700000000，得到 `.file`、10、对应日期；mode 为 0 时返回 nil。
  - `stat2ReportsLargeSize`：`STA2` 应答 size `5_000_000_000`，得到 `size == 5_000_000_000`。
  - `listV1SkipsDots`：`DENT` 依次为 `.`、`..`、`a.txt`（file）、`DCIM`（dir），然后 `DONE`，结果只有两项，kind 正确。
  - `list2Parsed`：`DNT2` 同上。
- [ ] **Step 2: 运行确认失败**：`swift test --filter AdbSyncTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 包测试通过**。
- [ ] **Step 5: 提交** `feat(android): adb sync session with stat and list`

### Task 3: AdbSync：SEND 与 RECV

**Files:**
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Adb/AdbSync.swift`
- Test: `AdbSyncTests.swift`

**Interfaces:**
- Produces（`AdbSyncSession` 方法）：
  - `func send(_ path: String, mode: UInt32, mtime: Date, read: (Int) throws -> Data?, progress: (UInt64) -> Void) async throws`：
    - 发 `SEND` 加 `<path>,<mode 十进制>`；
    - 用 `read(65536)` 取块，逐块发 `DATA`，直到返回 nil；
    - 最后发 `DONE <mtime 秒>`，读 `OKAY` 或 `FAIL`（`FAIL` 抛 `CONNECTION_FAILED`「推送失败：<原因>」）；
    - 每发一块回调一次累计字节。
  - `func recv(_ path: String, write: (Data) throws -> Void, progress: (UInt64) -> Void) async throws`：
    - 发 `RECV`，逐个处理 `DATA` 直到 `DONE`；
    - `FAIL` 抛 `CONNECTION_FAILED`「拉取失败：<原因>」。
  - 任务取消时关闭流并抛 `CancellationError`。
  - 中途 EOF 抛 `CONNECTION_FAILED`「连接中断」。

- [ ] **Step 1: 写失败测试**：
  - `sendChunksAt64K`：150,000 字节分为 65536、65536、18928 三块 `DATA`，`DONE` 带 mtime，progress 依次为 65536、131072、150000。
  - `zeroByteFileSendsOnlyDone`：`read` 立即返回 nil 时，只写 `SEND` 与 `DONE`。
  - `sendFailCarriesReason`：`FAIL` 带 `Permission denied` 时，message 为「推送失败：Permission denied」。
  - `recvConcatenatesChunks`：两块 `DATA` 加 `DONE`，write 收到原样字节。
  - `recvFail`：「拉取失败：No such file or directory」。
  - `eofMidTransferFails`：「连接中断」。
  - `cancelClosesConnection`：取消发送任务后流被关闭，抛 CancellationError。
- [ ] **Step 2–4**：确认失败 → 实现 → 包测试通过。
- [ ] **Step 5: 提交** `feat(android): adb sync send and recv with progress`

### Task 4: AndroidActions 文件操作

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Files.swift`、`Packages/TandemCore/Sources/AndroidDriver/Adb/AdbServerEndpoint.swift`
- Modify: `AndroidActions.swift`：init 增加 `syncStream: (@Sendable () async throws -> any ByteStream)? = nil`，nil 时用 `TCPByteStream.connect(port: AdbServerEndpoint.port())`
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidFilesTests.swift`、`AndroidIntegrationTests.swift`

**Interfaces:**
- Consumes：Task 2–3 的 `AdbHost`、`AdbSyncSession`。
- Produces：
  - `enum AdbServerEndpoint { static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 }`：解析 `ADB_SERVER_SOCKET=tcp:<port>` 或 `tcp:localhost:<port>`，否则 5037。
  - 私有 `withSync<T>(_ body: (AdbSyncSession) async throws -> T)`：
    - 连接失败时执行一次 `adb start-server` 后重试；仍失败抛 `CONNECTION_FAILED`「无法连接 adb 服务」；
    - features 每个 AndroidActions 实例缓存一次。
  - `listDirectory`、`stat` 先经 `DevicePath.validate`。
  - `push(_ local: URL, to remote:, progress:)`：
    - `local` 为文件时，`remote` 即目标完整路径；
    - `local` 为文件夹时递归推送，`remote` 为目标文件夹：
      - 空文件夹用 shell `mkdir -p <quote(path)>` 建出；
      - progress 的 `total` 为全部文件之和；
    - mode 取本地 POSIX 权限，mtime 取本地修改时间。
  - 取消或失败时用 shell `rm -f <quote(当前文件)>` 删除设备半成品，尽力而为，然后重抛。
  - `pull(_ remote:, to local:, progress:)`：
    - 写入 `local` 加 `.part`，完成后原子改名为 `local`；
    - 失败或取消时删除 `.part`；
    - `total` 取 `stat` 的 size。

- [ ] **Step 1: 写失败测试**（用 InMemoryByteStream 做 `syncStream`，FakeProcessRunner 处理 shell）：
  - `endpointFromEnvironment`：`tcp:5038` → 5038；`tcp:localhost:5039` → 5039；无变量 → 5037。
  - `startServerRetriedOnce`：第一次连接抛错、第二次成功时，runner 收到 `start-server` 一次。
  - `pushFolderRecurses`：文件夹含 `a.txt` 和 `sub/b.txt`，依次 SEND `/sdcard/Download/f/a.txt`、`/sdcard/Download/f/sub/b.txt`。
  - `emptyFolderIsCreated`：空子文件夹 `e` 时，runner 收到 `mkdir -p '/sdcard/Download/f/e'`。
  - `cancelRemovesRemotePartial`：发送中取消，runner 收到 `rm -f '<当前路径>'`。
  - `shellPathsAreQuoted`：路径 `/sdcard/x'; reboot; echo '.jpg` 经 shell 时为单引号转义后的形式，sync 包里为原样路径。
  - `pullWritesPartThenRenames`：完成后只存在目标文件；RECV 失败时目标与 `.part` 都不存在。
- [ ] **Step 2–4**：确认失败 → 实现 → 包测试通过。
- [ ] **Step 5: 真机集成测试**（加入 `AndroidIntegrationTests`）：
  - `fileRoundTrip`：推送 1 KB 随机文件到 `/sdcard/Download/tandem_test_<uuid>.bin`，`stat` 大小一致，拉回字节一致，`defer` 中 `rm -f`。
  - `listSdcard`：`/sdcard` 含 `Download`。
  - 在 R28M31LKJ1J 上运行通过。
- [ ] **Step 6: 提交** `feat(android): file list, push and pull over adb sync`

### Task 5: APK 清单解析与测试 APK

**Files:**
- Create: `scripts/make-test-apk.sh`
- Create: `Packages/TandemCore/Tests/AndroidDriverTests/Fixtures/tandem-test.apk`（由脚本生成并提交）
- Create: `Packages/TandemCore/Sources/AndroidDriver/ApkManifest.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Adb/AdbClient.swift`（`runner` 改为 internal，供读取 APK）
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/ApkManifestTests.swift`

**Interfaces:**
- 脚本：
  - 用 `~/Library/Android/sdk/build-tools/34.0.0` 的 `aapt2` 与 `apksigner`，以及 `platforms/android-34/android.jar`；
  - 生成包名 `dev.tandem.testapp`、`android:hasCode="false"`、minSdk 21 的 APK；
  - 用 `keytool` 在临时目录生成签名密钥并签名，输出到夹具路径；
  - 可重复执行。
- Produces：
  - `enum ApkManifest`：
    - `static func packageName(_ axml: Data) -> String?`：解析二进制 XML，按字符串池定位第一个 `manifest` 起始元素的 `package` 属性；格式不符时返回 nil，不崩溃。
    - `static func packageName(apk: URL, runner: any ProcessRunner) async -> String?`：执行 `/usr/bin/unzip -p <apk> AndroidManifest.xml` 后调用上一个函数。

- [ ] **Step 1: 运行脚本生成夹具**，并确认 `~/Library/Android/sdk/build-tools/34.0.0/aapt2 dump packagename <apk>` 输出 `dev.tandem.testapp`。
- [ ] **Step 2: 写失败测试**：
  - `readsPackageFromFixture`：夹具 APK 得到 `dev.tandem.testapp`（用 SystemProcessRunner）。
  - `garbageReturnsNil`：随机 4 KB、空 Data、截断的清单都返回 nil。
- [ ] **Step 3–4**：实现 → 包测试通过。
- [ ] **Step 5: 提交** `feat(android): apk manifest package parser and test apk fixture`

### Task 6: 安装与媒体扫描

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Install.swift`
- Modify: `AndroidCommands.swift`（新增 `Install` 命名空间）
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidInstallTests.swift`、`AndroidIntegrationTests.swift`

**Interfaces:**
- Consumes：Task 4 的 `push`、Task 5 的 `ApkManifest`。
- Produces：
  - `AndroidCommands.Install.failureAdvice(_ output: String) -> String?`：
    - `INSTALL_FAILED_VERSION_DOWNGRADE` →「设备上已有更高版本」
    - `INSTALL_FAILED_UPDATE_INCOMPATIBLE` →「签名与已安装版本不一致，请先卸载」
    - `INSTALL_FAILED_INSUFFICIENT_STORAGE` →「设备存储空间不足」
    - `INSTALL_FAILED_NO_MATCHING_ABIS` →「APK 不支持该设备的 CPU 架构」
    - `INSTALL_PARSE_FAILED_` 前缀 →「不是有效的 APK」
  - `install(apk:progress:)`：
    1. 读包名；
    2. 推送到 `/data/local/tmp/tandem_<uuid>.apk`；
    3. 用 `shellChecked` 执行 `pm install -r -d <quote(临时路径)>`，超时 120 秒；
    4. 输出不含 `Success` 时抛 `CONNECTION_FAILED`「安装失败：<原始输出>」，suggestion 为 failureAdvice；
    5. 无论成败都 `rm -f <quote(临时路径)>`。
  - `mediaScan(_:)`：
    - 每个路径执行 `am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d <quote("file://" + path)>`；
    - 先经 `DevicePath.validate`。

- [ ] **Step 1: 写失败测试**：
  - `installPushesThenPmInstalls`：调用顺序为 SEND 临时路径 → `pm install -r -d '/data/local/tmp/tandem_….apk'` → `rm -f`。
  - `installFailureCarriesAdviceAndCleansUp`：输出 `Failure [INSTALL_FAILED_VERSION_DOWNGRADE]` 时，message 含原文，suggestion 为「设备上已有更高版本」，且仍执行 `rm -f`。
  - `installTempPathQuoted`：临时路径以单引号包裹。
  - `mediaScanQuotesURI`：路径 `/sdcard/Pictures/a b.jpg` 的命令为 `-d 'file:///sdcard/Pictures/a b.jpg'`。
- [ ] **Step 2–4**：确认失败 → 实现 → 包测试通过。
- [ ] **Step 5: 真机**：
  - `installAndUninstallTestApk`：安装夹具，返回 `dev.tandem.testapp`，`pm list packages` 含它，`defer` 中 `pm uninstall dev.tandem.testapp`。
  - **媒体扫描验证**（手动，结果写进报告）：
    1. 推送一张 PNG 到 `/sdcard/Pictures/tandem_scan_test.png`；
    2. 执行 mediaScan；
    3. 用 `content query --uri content://media/external/images/media --projection _data --where "_data LIKE '%tandem_scan_test%'"` 确认已入库；
    4. 未入库时改用 spec §2.5 的 `content call … scan_file` 并重新验证；
    5. 最后删除测试图片，再扫描一次以移出相册。
  - 把采用的命令写回 spec §2.5。
- [ ] **Step 6: 提交** `feat(android): apk install via temp push and media scan`

### Task 7: 日志解析

**Files:**
- Modify: `AndroidCommands.swift`（新增 `Logs` 命名空间）
- Create: `Packages/TandemCore/Tests/AndroidDriverTests/Fixtures/logcat-threadtime-samsung.txt`（从 R28M31LKJ1J 只读抓取 `logcat -d -v threadtime -t 300`，再加上若干 `Start proc` 行；去掉明显的个人信息）
- Test: `AndroidCommandsTests.swift`

**Interfaces:**
- Produces（internal）：
  - `AndroidCommands.Logs.parse(_ line: String) -> LogEntry?`：匹配 `^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*: (.*)$`，tag 取第 5 组去空白。
  - `AndroidCommands.Logs.startProcPids(_ entries: [LogEntry], package: String) -> [Int]`：
    - 只看 tag 为 `ActivityManager` 的消息；
    - 匹配 `Start proc (\d+):<包名>[/:]`，包名中的 `.` 需转义；
    - 去重并保持出现顺序。
  - `AndroidCommands.Logs.snapshotCommand(minLevel: LogLevel) -> String`：`"logcat -d -v threadtime " + ShellQuote.quote("*:\(minLevel.rawValue)")`。

- [ ] **Step 1: 写失败测试**：
  - `parsesThreadtime`：夹具中每条可解析行都得到非 nil；`--------- beginning of main` 返回 nil。
  - `tagWithSpacesAndColons`：`10-18 22:01:02.345  1234  1250 I Some Tag: a: b` 得到 tag `Some Tag`、message `a: b`。
  - `startProcBothForms`：`Start proc 4321:com.demo/u0a123 for activity {…}` 与 `Start proc 5555:com.demo:remote/u0a123 for service` 得到 `[4321, 5555]`；`com.demox` 不匹配。
  - `levelArgumentIsQuoted`：`snapshotCommand(minLevel: .warn) == "logcat -d -v threadtime '*:W'"`。
- [ ] **Step 2–4**：确认失败 → 实现 → 包测试通过。
- [ ] **Step 5: 提交** `feat(android): logcat threadtime parsing`

### Task 8: AndroidActions 日志

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Logs.swift`
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidLogsTests.swift`、`AndroidIntegrationTests.swift`

**Interfaces:**
- Consumes：Task 7。
- Produces：
  - `pids(of:)`：先 `PackageName.validate`，再执行 `pidof <pkg>`，输出为空格分隔的数字，空输出为 `[]`。
  - `logSnapshot(_ q:)`：
    - package 非 nil 时，pid 集合为 `pids(of:)` 与 `startProcPids` 的并集（按出现顺序去重）；
    - 集合为空时返回 `LogSnapshot(entries: [], pids: [], note: "缓冲中没有 <包名> 的记录")`；
    - 否则按 pid 过滤；
    - grep 做不区分大小写的子串匹配，在 message 与 tag 上进行；
    - 取最后 `q.lines` 条；
    - 用 `shellChecked` 执行，超时 20 秒，解析 stdout。
  - `logStream()`：经 `ProcessRunner.stream(adb.url, ["-s", serial, "logcat", "-v", "threadtime"])`，逐行 `parse`；流被取消时 `terminate()` 进程。

- [ ] **Step 1: 写失败测试**：
  - `snapshotFiltersByPids`：pidof 返回 `123`、缓冲含 `Start proc 99:com.demo/…` 时，只保留 pid 123 与 99 的条目，`pids == [123, 99]`。
  - `snapshotEmptyHasNote`：未运行且无 Start proc 时，note 为「缓冲中没有 com.demo 的记录」。
  - `grepIsCaseInsensitive`、`linesTakesLast`。
  - `allWhenPackageNil`：不执行 pidof。
  - `streamParsesAndTerminates`：stubStream 三行，得到 3 条；取消后进程 terminate。
- [ ] **Step 2–4**：确认失败 → 实现 → 包测试通过。
- [ ] **Step 5: 真机**：`logSnapshotReadable`，`LogQuery(package: nil, lines: 50)` 至少 1 条。
- [ ] **Step 6: 提交** `feat(android): log snapshot with pid recovery and log stream`

### Task 9: TransferQueue

**Files:**
- Create: `App/Transfers/TransferQueue.swift`、`App/Transfers/TransferNaming.swift`
- Create: `App/Actions/DeviceCommands+Transfers.swift`
- Modify: `App/AppServices.swift`（创建并持有 `transfers: TransferQueue`；设备移除时调用 `deviceDisconnected`）
- Modify: `AppTests/Support/RecordingActions.swift`：文件与日志方法可配置；push / pull / install 可挂起，可按块回调进度
- Test: `AppTests/TransferQueueTests.swift`、`AppTests/TransferNamingTests.swift`

**Interfaces:**
- Produces：
  - `enum ConflictPolicy: String, Codable { case overwrite, rename }`
  - `enum TransferNaming`：
    - `static func candidate(_ name: String, _ n: Int) -> String`：`a.jpg`, 1 → `a (1).jpg`；`README`, 2 → `README (2)`；`a.tar.gz`, 1 → `a.tar (1).gz`。
    - `static func uniqueLocal(in dir: URL, name: String) -> URL`：返回第一个不存在的候选。
  - `enum TransferKind: Equatable`：
    - `push(locals: [URL], dest: String, conflict: ConflictPolicy, mediaScan: Bool)`
    - `install(apk: URL)`
    - `pull(remote: String, to dir: URL)`
  - `enum TransferResult: Equatable`：`pushed([String])`（设备实际路径）、`installed(String?)`、`pulled(URL)`
  - `struct TransferJob: Identifiable`：`id: UUID`、`deviceID`、`kind`、`origin: ToastOrigin`、`source: ActivitySource`、`state: State`、`note: String?`
    - `State`：`waiting`、`running(TransferProgress, phase: String)`、`done(TransferResult)`、`failed(DeviceError)`、`cancelled`
    - phase 取值为「推送」「安装中」「拉取」
  - `@MainActor @Observable final class TransferQueue`：
    - `init(runner: ActionRunner, device: (String) -> DeviceInfo?, actions: (String) async -> (any DeviceActions)?, onFinished: (TransferJob) -> Void)`
    - `func enqueue(_ deviceID: String, _ kind: TransferKind, origin: ToastOrigin, source: ActivitySource = .user) -> UUID`
    - `func result(_ jobID: UUID) async -> Result<TransferResult, DeviceError>`：AI 用，等待完成
    - `func cancelCurrent(_ deviceID: String)`、`func deviceDisconnected(_ deviceID: String)`
    - `func jobs(_ deviceID: String) -> [TransferJob]`：未完成的，按顺序
    - 每台设备一次执行一项；进度节流到 100 毫秒更新一次
  - push 的目标路径：
    - `dest` 以 `/` 结尾时，目标为 `dest + 文件名`；
    - rename 策略下用 `stat` 与 `candidate` 找第一个不存在的名字；
    - mediaScan 只对图片、视频扩展名执行；失败时结果仍算成功，并在 `TransferJob` 上记录 `note: "未能加入相册"`。
  - pull 的目标为 `uniqueLocal(in: dir, name: 远端文件名)`。
  - 每项经 `runner.perform` 写一条记录，标题为：
    - `推送 a.jpg`；多个时为 `推送 3 个文件`；
    - `安装 app.apk`；
    - `拉取 x.log`。
  - `DeviceCommands+Transfers`：
    - `pushFiles(_ id:, _ urls: [URL], dest: String = "/sdcard/Download/", conflict: ConflictPolicy = .rename, mediaScan: Bool = false, origin:)`：APK 与普通文件分开入队，APK 走 `.install`；
    - `installAPK(_ id:, _ url:, origin:)`；
    - `pull(_ id:, _ remote:, origin:)`：dir 取 `FileTransferStore.pullDirectory`（Task 10），在 Task 10 前先用 `~/Downloads`；
    - `listDirectory(_ id:, _ path:) async -> Result<[RemoteFile], DeviceError>`：读取不记录。

- [ ] **Step 1: 写失败测试**：
  - `candidateNames`（上面三例）。
  - `uniqueLocalSkipsExisting`：临时目录已有 `a.jpg`、`a (1).jpg` 时，得到 `a (2).jpg`。
  - `runsOneAtATimeFIFO`：两项依次完成，第二项在第一项结束前保持 waiting。
  - `renameUsesStat`：`stat` 对 `a.jpg` 返回存在时，推送目标为 `/sdcard/Download/a (1).jpg`。
  - `apkGoesToInstall`：`pushFiles` 传入 `x.apk` 与 `y.txt`，得到 install 一项、push 一项。
  - `cancelCurrentOnlyCancelsRunning`。
  - `disconnectCancelsRest`：当前项失败「设备已断开」，其余项为 cancelled，记录中有失败条目。
  - `recordTitles`。
  - `resultAwaitsCompletion`。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): per-device transfer queue with naming and records`

### Task 10: 粘贴分流与传输设置

**Files:**
- Create: `App/Transfers/PasteFileResolver.swift`、`App/Transfers/FileTransferStore.swift`
- Modify: `App/Settings/SettingsView.swift`（「拉取目录」选择…；「粘贴文件时」每次询问 / 按上次的选择直接推送）、`App/AppServices.swift`（持有 `fileStore`）、`App/Actions/DeviceCommands+Transfers.swift`（pull 目录改取 `fileStore.pullDirectory`）
- Test: `AppTests/PasteFileResolverTests.swift`、`AppTests/FileTransferStoreTests.swift`

**Interfaces:**
- Produces：
  - `struct PasteChoice: Codable, Equatable { var dest: String; var installAPK: Bool; var mediaScan: Bool; var conflict: ConflictPolicy; var heicToJPEG: Bool }`
  - `@MainActor @Observable final class FileTransferStore`：`init(defaults:)`，状态如下：
    - `pullDirectory: URL`：默认 `~/Downloads`
    - `rememberedPaste: PasteChoice?`：nil 表示每次询问
    - `recentDirectories: [String]`：最多 5 个，`recordDirectory(_:)` 移到最前
    - UserDefaults 键：`transfers.pullDirectory`、`.rememberedPaste`（JSON）、`.recentDirectories`
  - `struct PasteFile: Equatable { var url: URL; var name: String; var size: UInt64; var format: String; var origin: Origin; var isTemporary: Bool }`
    - `enum Origin { case file, rawData, tiffConverted }`
    - `format` 为 UTType 的简短描述，如 `JPEG`、`PNG`、`HEIC`、`MPEG-4`，文件夹为 `文件夹`
  - `enum PasteContent: Equatable { case text(String), files([PasteFile]), none }`
  - `enum PasteFileResolver`：`static func resolve(_ pasteboard: NSPasteboard, tempDir: URL, now: Date) throws -> PasteContent`
    - 优先级：文件 URL → 图片 / 视频数据 → 文本。
    - 数据项按 `types` 顺序取第一个符合 `conforms(to: .image)` 或 `.movie` 且不是 `.tiff` 的类型，原样写出；扩展名取 `preferredFilenameExtension`。
    - 仅有 TIFF 时用 ImageIO 无损转 PNG，origin 为 `.tiffConverted`。
    - 文件名为 `paste_yyyyMMdd_HHmmss.<ext>`；同一次粘贴有多项时，从第 2 项起加 `_2`、`_3`。
  - `static func convertHEICToJPEG(_ file: PasteFile, tempDir: URL) throws -> PasteFile`：ImageIO，质量 0.9。

- [ ] **Step 1: 写失败测试**（用 `NSPasteboard(name: .init(UUID().uuidString))`）：
  - `textStaysText`。
  - `fileURLWins`：同时有文件 URL 与文本时，结果为 files，origin 为 `.file`，isTemporary 为 false。
  - `firstNonTIFFImageIsKeptRaw`：
    - 输入：一项依次声明 `public.tiff`、`public.jpeg`；
    - 期望：写出的字节等于 JPEG 数据，扩展名为 `jpg`，origin 为 `.rawData`。
  - `tiffOnlyBecomesPNG`：结果扩展名为 `png`，origin 为 `.tiffConverted`，文件以 PNG 签名开头。
  - `pasteFileName`：`now` 固定为 2026-10-18 22:01:02 时，文件名为 `paste_20261018_220102.jpg`。
  - `storeDefaultsAndRecents`：pullDirectory 默认 `~/Downloads`；recentDirectories 上限 5 且去重。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): paste file resolver and transfer settings`

### Task 11: 拖放、进度栏与通用提示条

**Files:**
- Modify: `App/Capture/ToastCenter.swift`：
  - `CaptureToast.item` 改为 `content: ToastContent`；
  - `enum ToastContent: Equatable { case capture(CaptureItem, note: String?), transfer(TransferNotice) }`；
  - 保留 `show(_ item:note:in:)` 以兼容 P3a 调用；
  - 新增 `show(_ notice: TransferNotice, in origin: ToastOrigin)`。
- Modify: `App/Workspace/CaptureToastView.swift`（渲染 transfer 提示：成功、失败标红、「在文件中查看」按钮）
- Create: `App/Transfers/TransferNotice.swift`：`struct TransferNotice: Equatable { var title: String; var detail: String?; var isError: Bool; var revealPath: (deviceID: String, path: String)? }`
- Create: `App/Transfers/TransferProgressBar.swift`、`App/Transfers/DropOverlay.swift`
- Modify: `App/DeviceWindow/MirrorView.swift`（接受拖放；底部叠加进度栏）、`App/DeviceWindow/DeviceWindowView.swift`、`App/Workspace/MirrorPane.swift`（传入 `transfers`、`commands`、origin）
- Modify: `App/AppServices.swift`（`onFinished` 把结果转为 `TransferNotice` 显示在 job.origin）
- Test: `AppTests/TransferNoticeTests.swift`

**Interfaces:**
- Consumes：Task 9。
- Produces：
  - `TransferNotice.from(_ job: TransferJob) -> TransferNotice?`：
    - push：「已推送到 <路径>」，多个文件时为「已推送 3 个文件到 <目录>」；带 revealPath。
    - install：「已安装 <包名>」；包名为 nil 时为「安装成功」。
    - pull：「已拉取到 <路径>」，同时在 Finder 中选中。
    - failed：标红，detail 为 message。
    - cancelled：返回 nil。
    - mediaScan 失败时 detail 为「未能加入相册」。
  - 「在文件中查看」通过 `AppModel` 选中该设备并切到「文件」标签、跳到该目录。Task 13 提供 `FilesModel.reveal(deviceID:path:)`，本任务先调用一个 `onReveal` 回调。
  - 拖放：
    - 用 `.onDrop(of: [.fileURL], isTargeted:)`；
    - 悬停时 `DropOverlay` 按内容显示「松开以安装」「松开以推送到 Download」或两者；
    - 放下后调用 `commands.pushFiles(id, urls, origin:)`；
    - 设备缺能力时不接受（spec §3.2）。
  - 进度栏：
    - 显示 `transfers.jobs(id)` 的首项：`推送 a.jpg · 45% · 还有 2 项`；安装时为 `安装 app.apk · 推送中 80%` / `安装中…`；
    - 带「取消」按钮，调用 `transfers.cancelCurrent`。

- [ ] **Step 1: 写失败测试**：`noticeFromJob`，覆盖上面各种结果的标题与 detail。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过（P3a 截图、录屏提示条相关测试仍通过）。
- [ ] **Step 5: 提交** `feat(app): drop to push or install, transfer progress bar and notices`

### Task 12: ⌘V 粘贴文件确认框

**Files:**
- Create: `App/Transfers/PasteFilesSheet.swift`、`App/Transfers/PasteFlow.swift`
- Modify: `App/DeviceWindow/MirrorView.swift`：`onPaste` 改为调用 `PasteFlow`；文本仍走现有 `.paste(text)`
- Test: `AppTests/PasteFlowTests.swift`

**Interfaces:**
- Consumes：Task 9、10、11。
- Produces：
  - `@MainActor @Observable final class PasteFlow`（每个 MirrorView 一个）：
    - `init(deviceID:, commands: DeviceCommands, store: FileTransferStore, pasteboard: NSPasteboard = .general, tempDir: URL)`
    - `func paste() -> PasteAction`：`enum PasteAction: Equatable { case text(String), confirm([PasteFile]), pushedDirectly, nothing }`
      - 有 `rememberedPaste` 时直接按它入队，返回 `.pushedDirectly`；
      - 否则返回 `.confirm`，由视图弹出 sheet。
    - `func confirm(_ files: [PasteFile], choice: PasteChoice, remember: Bool)`：
      - HEIC 勾选转换时先转换；
      - APK 在 `installAPK` 为 true 时走安装，否则推送；
      - 记录目录到 recents；remember 时保存 choice；
      - 临时文件在任务结束后删除（交给 `onFinished` 处理）。
  - sheet 内容照抄 spec §3.3：
    - 文件清单：名称、大小、`format · 来源`；
    - HEIC 提示与「转为 JPEG」，默认不勾；
    - APK 安装 / 仅推送；
    - 目标目录下拉：Download、Pictures、DCIM、Documents 加 recents；
    - 「图片和视频加入相册」：有图片或视频时显示，默认勾；
    - 同名：覆盖 / 自动改名（默认）；
    - 「记住选择，以后不再询问」。

- [ ] **Step 1: 写失败测试**：
  - `textPastesAsBefore`：剪贴板为文本时返回 `.text`。
  - `filesNeedConfirmation`。
  - `rememberedChoiceSkipsSheet`：返回 `.pushedDirectly`，并入队 push，dest 与 conflict 与记住的值一致。
  - `confirmRoutesAPK`：installAPK 为 true 时，apk 走 install、jpg 走 push。
  - `confirmRecordsRecentAndRemembers`。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): paste files with confirmation sheet`

### Task 13: 「文件」标签

**Files:**
- Create: `App/Files/FilesModel.swift`、`App/Files/FilesTab.swift`
- Modify: `App/Workspace/WorkspaceView.swift`（`Tab` 新增 `files`，位于 `quickActions` 之后，标签名「文件」，需要 `files` 能力）、`App/AppServices.swift`（持有 `filesModel`；接上 Task 11 的 `onReveal`）
- Test: `AppTests/FilesModelTests.swift`

**Interfaces:**
- Consumes：Task 9 的 `listDirectory`、`pull`、`pushFiles`；Task 10 的 `FileTransferStore`。
- Produces：
  - `@MainActor @Observable final class FilesModel`：
    - `init(commands: DeviceCommands)`
    - `path: [String: String]`：默认 `/sdcard/Download`
    - `listing: [String: Result<[RemoteFile], DeviceError>]`
    - `func open(_ id:, _ path:) async`：结果写入发起时的 id
    - `func up(_ id:) async`、`func refresh(_ id:) async`
    - `func reveal(deviceID:path:)`：打开文件所在目录
    - `static let shortcuts = ["/sdcard/Download", "/sdcard/DCIM", "/sdcard/Pictures", "/sdcard/Documents"]`
  - 传输完成后刷新：push 到当前目录完成时，自动 `refresh`。
  - 视图：
    - 路径栏（可编辑，回车跳转）、「上级」、常用目录按钮、「刷新」、「推送文件…」（`NSOpenPanel`，多选，可选文件夹）；
    - 列表为名称、大小（`ByteCountFormatter`）、修改时间，目录在前；双击目录进入；双击文件或点「拉取」执行 pull；
    - 读取失败时显示原因。
  - 拖到 Finder：
    - 文件行 `.onDrag` 返回 `NSItemProvider`，用 `registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all)` 懒拉取；
    - 拉取到临时目录后交给系统复制；
    - 这条路径直接调用 `commands.pullToTemporary(_ id:, _ remote:) async throws -> URL`（在 DeviceCommands+Transfers 中新增，经 runner 记录「拉取 <名>」），不进队列，以免和 Finder 的回调死锁。

- [ ] **Step 1: 写失败测试**：
  - `defaultPathIsDownload`。
  - `upStopsAtRoot`：`/` 的上级仍为 `/`。
  - `staleListingDoesNotOverwriteOtherDevice`。
  - `revealOpensParent`：`/sdcard/Download/a.jpg` 得到 path `/sdcard/Download`。
  - `pushCompletionRefreshesCurrentDir`。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): files tab with browse, pull, push and drag to finder`

### Task 14: 日志会话模型

**Files:**
- Create: `App/Logs/LogSession.swift`
- Test: `AppTests/LogSessionTests.swift`

**Interfaces:**
- Consumes：Task 1 的类型；Task 9 中扩展的 `RecordingActions`（`pids`、`logSnapshot`、`logStream` 可配置）。
- Produces：
  - `enum LogTarget: Hashable { case package(String), all }`
  - `enum LogLine: Equatable, Identifiable { case entry(LogEntry), separator(String) }`：id 为递增序号
  - `@MainActor @Observable final class LogSession`：
    - `init(deviceID:, actions: @escaping () async -> (any DeviceActions)?, capacity: Int = 50_000, pollInterval: Duration = .seconds(2), batchInterval: Duration = .milliseconds(100), sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`
    - `target: LogTarget`；`func setTarget(_:) async`：清空，用 `logSnapshot(lines: 2000)` 补历史，再接流
    - `func run() async`：读取流加 pid 轮询，直到取消。流结束（设备断开）时 `status = .disconnected`，按 pollInterval 重试连接
    - `status`：`.waitingForProcess`（「等待进程启动…」）/ `.streaming` / `.disconnected`（「设备已断开」）
    - `lines: [LogLine]`：容量上限，超出丢弃最早的
    - `minLevel`、`keyword`；`visible: [LogLine]` 为过滤后（分隔行总是保留）
    - `paused: Bool`；暂停时 `visible` 冻结，`pendingCount` 计数新增条目
    - `func clear()`；`func exportText() -> String`：每行 `time pid tid L tag: message`，分隔行原样
  - pid 跟踪：package 目标下按 pid 集合过滤流；pid 集合变化时追加 `separator("—— 进程重启（pid 1234 → 5678）——")`；集合为空时 status 为 waitingForProcess。
  - 流条目在后台累积，每 batchInterval 一次性 append 到 `lines`。

- [ ] **Step 1: 写失败测试**（`sleep` 注入为可控时钟）：
  - `ringBufferDropsOldest`：容量 5，追加 8 条后 lines 为后 5 条。
  - `batchesAreCoalesced`：流快速产出 1000 条，在一个 batchInterval 内只触发一次 `lines` 变更。
  - `filtersByPidSet`：目标 com.demo、pid `[10]` 时，pid 20 的条目不出现。
  - `pidChangeInsertsSeparator`：pids 从 `[10]` 变为 `[11]` 时，追加「—— 进程重启（pid 10 → 11）——」。
  - `notRunningWaits`：status 为 waitingForProcess。
  - `historyComesFirst`：快照 3 条排在流的条目之前。
  - `pauseFreezesVisible`、`levelAndKeywordFilter`、`exportFormat`。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): log session with pid following, ring buffer and filters`

### Task 15: 日志窗口

**Files:**
- Create: `App/Logs/LogWindowView.swift`
- Modify: `App/TandemApp.swift`（`WindowGroup(id: "logs", for: String.self)`，值为设备 id，标题「<设备名> 日志」）、`App/QuickActions/AppsSection.swift`（「日志」按钮：打开该设备日志窗口，初始目标为 `targetPackage`，nil 时为 `.all`；已打开则前置）、`App/AppServices.swift`（按设备 id 持有 `LogSession`，窗口关闭时取消其 `run`）

**Interfaces:**
- Consumes：Task 14。
- 视图（spec §3.6）：
  - 工具栏：目标下拉（「前台 App（<包名>）」选择时读取一次前台包名并固定；已固定包名；「全部」）、最低级别 V/D/I/W/E/F、关键字、暂停/继续、清空、导出（`NSSavePanel`，默认名 `<设备名>_<包名或all>_yyyyMMdd_HHmmss.txt`）。
  - 列表：等宽字体，时间、pid、级别（按级别着色，颜色取自 Theme，需要时新增 Theme token）、tag、内容；可选中复制。
  - 自动滚到最新；向上滚动后停止并显示「回到最新」。
  - 状态行：「等待进程启动…」「设备已断开」「已暂停 · 新增 N 条」。

- [ ] **Step 1: 实现**。
- [ ] **Step 2: 手动构建检查**：`xcodegen generate && xcodebuild build …` 成功，App 测试通过。
- [ ] **Step 3: 提交** `feat(app): device log window`

### Task 16: AICommands 文件与日志

**Files:**
- Create: `App/AI/AICommands+Files.swift`
- Modify: `App/AppServices.swift`（`AICommands` 拿到 `transfers` 与 `fileStore`）
- Test: `AppTests/AICommandsFilesTests.swift`

**Interfaces:**
- Consumes：Task 9 的 `TransferQueue.enqueue` / `result`、Task 10 的 `pullDirectory`；P3b 的 `act(_:_:needsSession: false, _:)`、`run`、64 KB 截断辅助函数（`AICommands+QuickActions.swift` 中的 shell 截断，提为共用）。
- Produces：
  - `getLogs(_ device:, app: String?, level: LogLevel, grep: String?, lines: Int) async throws -> String`：
    - 走 `run`（感知类）；
    - 首行 `# app=<包名|all> level=<字母> grep=<…|-> pids=<逗号分隔|-> lines=<n>`；
    - 有 note 时第二行为 `# <note>`；
    - 其后每行 `time pid tid L tag: message`；
    - 总长 64 KB 截断。
  - `pushFile(_ device:, path: String, dest: String?) async throws -> String`：
    - path 必须为绝对路径且存在，否则 INVALID_ARGUMENT「本机文件不存在：<path>」；
    - dest 默认 `/sdcard/Download/`；
    - 入队 `.push(conflict: .rename, mediaScan: false)`，origin 为设备当前所在窗口（无窗口时为 `.workspace`），source 为 `.ai`；
    - 返回「已推送到 <设备路径>」。
  - `pullFile(_ device:, path: String, dest: String?) async throws -> String`：
    - dest 为拉取目录下的相对子目录，不存在时创建；
    - 返回 Mac 绝对路径。
  - `installApp(_ device:, path: String) async throws -> String`：
    - 扩展名必须为 `.apk`，否则 INVALID_ARGUMENT「不是 APK 文件：<path>」；
    - 返回「安装成功：<包名>」或「安装成功」。
  - 拉取目录沙箱：`static func pullDestination(base: URL, relative: String?) throws -> URL`：
    - relative 为绝对路径、含 `..` 分段，或 `resolvingSymlinksInPath` 后不在 base 之下时，抛 INVALID_ARGUMENT「目标目录必须在拉取目录之内」。
  - 三个操作类都走 `act(..., needsSession: false)`：受锁定限制，在队列里排队，等待 `result`。
  - 记录标题：`push_file a.jpg`、`pull_file /sdcard/x.log`、`install_app app-debug.apk`；`get_logs` 只在失败时记录。

- [ ] **Step 1: 写失败测试**：
  - `getLogsFormat`：首行与条目行格式；note 行。
  - `getLogsTruncated`：70 KB 时结果 ≤ 64 KB，并含「已截断」。
  - `getLogsWorksWhenLocked`、`pushFileRejectedWhenLocked`。
  - `pullDestinationCannotEscape`：`../x`、`/tmp`、指向 base 之外的符号链接子目录都抛错；`sub/dir` 通过。
  - `installAppNeedsApk`、`pushFileMissingLocal`。
  - `aiTransfersUseQueue`：push_file 入队后，jobs 中可见 source 为 .ai 的项。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): ai file transfer and log commands`

### Task 17: ToolRegistry 新工具

**Files:**
- Create: `App/AI/ToolRegistry+Files.swift`
- Modify: `App/AI/ToolRegistry.swift`（工具表追加、`timeout(for:arguments:)`）
- Test: `AppTests/ToolRegistryFilesTests.swift`

**Interfaces:**
- Consumes：Task 16。
- Produces：
  - 工具追加在 P3b 的 `shell` 之后，顺序为 `get_logs, push_file, pull_file, install_app`。
  - 参数与能力照抄 spec §4 的表：
    - `get_logs`：`app` 为 string；`level` 为 enum V/D/I/W/E/F；`grep` 为 string；`lines` 为 integer，范围 1–2000。
    - `push_file`：`path` 必填；`dest` 可选。
    - `pull_file`：`path` 必填；`dest` 可选。
    - `install_app`：`path` 必填。
  - 描述用中文，写明默认值与限制。
  - 超时：
    - `push_file` / `install_app`：`min(30 + 10 × ceil(大小 / 10 MB), 600)` 秒；大小为本地文件或文件夹总大小，读不到时按 30 秒。
    - `pull_file`：600 秒。
    - `get_logs`：30 秒。

- [ ] **Step 1: 写失败测试**：
  - `fileToolsListedAfterShell`。
  - `logsArgumentsValidated`：`lines: 0`、`lines: 3000`、`level: "X"` 都返回 INVALID_ARGUMENT。
  - `transferTimeoutScalesWithSize`：25 MB 文件为 60 秒；10 GB 封顶 600 秒；不存在的路径为 30 秒。
  - `capabilitiesFilterTools`：设备没有 `files` 能力时，列表不含 push_file / pull_file。
- [ ] **Step 2–4**：确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): mcp tools for logs, file transfer and install`

### Task 18: 验收清单与最终验证

**Files:**
- Create: `docs/superpowers/qa/p3c-manual-checklist.md`
- Modify: `docs/superpowers/specs/2026-10-18-p3c-logs-and-files-design.md`（如 Task 6 的媒体扫描结论尚未写回，在此补上）

- [ ] **Step 1: 验收清单**：照抄 spec §6 的人工验收项，每条写明步骤、预期结果、状态（初始为「待验证」），并补充：
  - 拖放 APK / 普通文件 / 文件夹 / 混合；
  - 设备缺能力时拒绝拖放；
  - ⌘V 的文本、文件、仅图片数据、仅 TIFF、HEIC 转 JPEG；
  - 确认框各选项；加入相册在相册中可见；
  - 「记住选择」与设置页改回；
  - 进度栏与取消，取消后设备上无半成品；
  - 「文件」标签：浏览、路径栏、常用目录、拉取、拖到 Finder、推送文件…、读取失败提示；
  - 「在文件中查看」跳转；
  - 日志窗口：
    - 从「应用」分段打开；
    - 历史补全；
    - 「重启」App 后出现分隔行并继续；
    - 等待进程启动；
    - 「全部」模式的流量；
    - 级别、关键字、暂停计数、导出文件；
    - 断开重连；
  - 深色模式下的新界面；
  - AI 端到端调用四个工具，包括锁定、越界的 pull 目标、非 APK 文件。
- [ ] **Step 2: 最终验证**：
  - `cd Packages/TandemCore && swift test` 全部通过；
  - 真机：`PATH=… TANDEM_TEST_SERIAL=R28M31LKJ1J swift test --filter AndroidIntegrationTests` 全部通过，手机上无 `tandem_test_` 残留文件，未残留 `dev.tandem.testapp`；
  - 征得用户同意后执行 `xcodegen generate && xcodebuild test … -derivedDataPath .build/xcode`，全部通过；
  - `adb forward --list` 无本次新增的 `scrcpy_`。
- [ ] **Step 3: 提交** `docs: P3c manual QA checklist`
