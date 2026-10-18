# P1：基础框架 + Android 投屏控制 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能运行的 macOS App：菜单栏列出 USB / Wi-Fi 连接的 Android 设备，每台设备开独立窗口实时投屏，可用鼠标键盘（含中文输入）操控，支持扫码无线配对与一键转无线，国产 ROM 注入受限时给出引导。

**Architecture:** 核心逻辑放在本地 Swift Package `Packages/TandemCore`：`DeviceCore`（平台无关的设备 / 会话 / 输入 / 错误模型与 `DeviceManager`）和 `AndroidDriver`（adb 调用、scrcpy v5.0.1 协议客户端、VideoToolbox 解码、`AndroidSession`）。App target 只做 SwiftUI/AppKit 界面，通过 `DeviceManager` 和 `DeviceSession` 协议使用驱动。所有外部进程经 `ProcessRunner`、所有 socket 经 `ByteStream` 抽象，单元测试不需要真机。

**Tech Stack:** Swift 6（Xcode 27.1 / Swift 6.4）、SwiftUI + AppKit、VideoToolbox、Network.framework、CoreImage（二维码）、Swift Testing、XcodeGen、scrcpy-server v5.0.1、Android platform-tools r37.0.0。

**Spec:** `docs/superpowers/specs/2026-10-17-tandem-design.md`（本计划实现其 §2、§3 与 §9 的 P1）

## Global Constraints

- 最低系统 macOS 14；Swift 语言模式 6（严格并发）。
- scrcpy-server 锁定 **v5.0.1**（发布于 2026-10-08），sha256 `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`；启动参数中的版本号字符串必须是 `5.0.1`。
- 内置 adb 取自 `platform-tools_r37.0.0-darwin.zip`，sha256 `094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7`；仅在系统中找不到**可运行**的 adb 时使用。
- 第一版不传音频（`audio=false`）；视频固定 H.264。
- App 不开沙盒（需要启动 adb 子进程与本地 socket），本地签名 `CODE_SIGN_IDENTITY = "-"`。
- 错误统一用 `DeviceError {code, message, suggestion}`，code 取自 spec §7 并补充本期的 `ADB_NOT_FOUND`、`CONNECTION_FAILED`。
- 所有面向用户的文案为中文。
- 剪切板双向自动同步不在 P1；P1 只提供剪切板读写 API 与 ⌘V 粘贴文本。快捷面板、MCP、iOS 均不在 P1。
- 第三方二进制（adb、scrcpy-server）不提交进 git，由 `scripts/fetch-vendor.sh` 下载并校验。

## Review Focus

1. **PATH 里的 adb 无法运行**（本机 `/usr/local/bin/adb` 是 x86_64 版本，执行报 `bad CPU type`）：应跳过它，改用下一个能运行的 adb，而不是整个 App 报错。→ Task 2 `skipsBrokenCandidate`。
2. **投屏过程中设备旋转**：会收到新的 session 包和新的 SPS/PPS，此时窗口比例应更新、画面继续，不应卡住或花屏。→ Task 8 `rotationEmitsNewSizeAndResetsDecoder`。
3. **同一台手机同时通过 USB 和 Wi-Fi 连接**：菜单里只应显示一台设备，优先用 USB。→ Task 4 `dedupesSamePhonePreferringUSB`。
4. **长文本或中英混合文本**：超过 300 字节的 ASCII 应分段、按顺序完整到达；包含中文或 emoji 的文本整段走"设置剪切板并粘贴"。→ Task 8 `longAsciiIsChunked`、`nonAsciiUsesClipboardPaste`。
5. **点在黑边上，或会话没在运行时输入**：应直接忽略，不崩溃，也不缓存起来等重连后再触发；拖动划出画面时要夹到边缘，保证抬起事件能发出去。→ Task 9 `letterboxPointIsNil`、`dragClampsToEdge`；Task 8 `inputWhenNotRunningIsDropped`。

---

## 文件结构

```
project.yml                                  XcodeGen 工程定义
scripts/fetch-vendor.sh                      下载并校验 adb / scrcpy-server 到 App/Resources/Vendor
App/
  Info.plist
  TandemApp.swift                         @main：MenuBarExtra + 设备窗口 + 配对窗口 + Settings
  AppModel.swift                             @MainActor @Observable：设备列表、会话、自动开窗、自动重连
  MenuBar/DeviceMenuView.swift
  DeviceWindow/DeviceWindowView.swift        投屏 + 状态遮罩 + ROM 横幅 + 底部导航按钮
  DeviceWindow/VideoSurfaceView.swift        NSView：渲染帧、鼠标/滚轮/键盘/输入法 → InputAction
  DeviceWindow/ViewGeometry.swift            视图坐标 ↔ 归一化坐标（纯函数）
  DeviceWindow/KeyMapping.swift              Mac 按键 → KeyCommand（纯函数）
  DeviceWindow/RomBannerView.swift
  Pairing/PairingView.swift                  二维码配对 + 配对码配对 + 一键转无线
  Settings/SettingsView.swift
  Resources/Vendor/                          (gitignored) adb、scrcpy-server-v5.0.1、NOTICE
Packages/TandemCore/
  Package.swift
  Sources/DeviceCore/
    DeviceInfo.swift  Capability.swift  DeviceError.swift  InputAction.swift
    DeviceSession.swift  DeviceDriver.swift  DeviceManager.swift
  Sources/AndroidDriver/
    Process/ProcessRunner.swift              协议 + SystemProcessRunner
    Adb/AdbLocator.swift  Adb/AdbClient.swift  Adb/DeviceListParser.swift
    Adb/AndroidDriver.swift                  DeviceDriver 实现（track-devices → DeviceInfo）
    Adb/MdnsParser.swift  Adb/WirelessConnector.swift
    Scrcpy/ControlMessage.swift  Scrcpy/DeviceMessage.swift  Scrcpy/VideoHeader.swift
    Scrcpy/H264Parser.swift  Scrcpy/ByteStream.swift  Scrcpy/ScrcpyConnection.swift
    Scrcpy/ScrcpyServer.swift  Scrcpy/H264Decoder.swift
    AndroidSession.swift  RomGuide.swift
  Tests/DeviceCoreTests/…
  Tests/AndroidDriverTests/…  Support/FakeProcessRunner.swift  Support/InMemoryByteStream.swift
  Tests/AndroidDriverTests/Fixtures/         设备列表、mdns、ip addr 文本样例，testsrc-64x48.h264
```

命令约定：
- 包测试：`swift test --package-path Packages/TandemCore --filter <SuiteName>`
- App 构建：`xcodegen generate && xcodebuild -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' -quiet build`（退出码 0 即通过）

---

### Task 1: 工程骨架、DeviceCore 基础类型、第三方二进制获取

**Files:**
- Create: `project.yml`, `.gitignore`（追加 `App/Resources/Vendor/`、`*.xcodeproj`、`.build/`）, `scripts/fetch-vendor.sh`, `App/Info.plist`, `App/TandemApp.swift`
- Create: `Packages/TandemCore/Package.swift`, `Sources/DeviceCore/{DeviceInfo,Capability,DeviceError,InputAction}.swift`, `Sources/AndroidDriver/Placeholder.swift`（Task 2 删除）
- Test: `Packages/TandemCore/Tests/DeviceCoreTests/DeviceErrorTests.swift`

**Interfaces:**
- Produces（`DeviceCore`，全部 `public`、`Sendable`）：
  ```swift
  enum Platform: String { case android, ios }
  enum ConnectionKind: String { case usb, wifi }
  enum DeviceState: Equatable { case connected, unauthorized, offline }
  enum Capability: String { case mirror, touch, keys, text, clipboard }
  struct DeviceInfo: Identifiable, Equatable {
    var id: String            // adb serial
    var platform: Platform
    var name: String          // 展示名（model，下划线换空格）
    var state: DeviceState
    var connection: ConnectionKind
    var hardwareSerial: String?   // ro.serialno，用于去重
    var capabilities: Set<Capability>
  }
  struct DeviceError: Error, Equatable {
    enum Code: String { case DEVICE_NOT_FOUND, DEVICE_UNAUTHORIZED, INJECT_PERMISSION_DENIED, UNSUPPORTED,
                        AI_LOCKED, DEVICE_AMBIGUOUS, WDA_SIGN_EXPIRED, TIMEOUT, ADB_NOT_FOUND, CONNECTION_FAILED }
    var code: Code; var message: String; var suggestion: String?
    static func adbNotFound() -> DeviceError
    static func timeout(_ what: String) -> DeviceError
    static func connectionFailed(_ detail: String) -> DeviceError
  }
  struct NormalizedPoint: Equatable { var x: Double; var y: Double }   // 0...1，原点左上
  enum TouchPhase { case down, move, up }
  enum DeviceKey: String { case back, home, recents, volumeUp, volumeDown, power, enter, delete, forwardDelete, tab, up, down, left, right }
  enum InputAction: Equatable { case touch(TouchPhase, NormalizedPoint); case scroll(NormalizedPoint, dx: Double, dy: Double); case key(DeviceKey); case text(String) }
  ```

- [ ] **Step 1: 写 `scripts/fetch-vendor.sh`**
  下载 `https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip` 与 `https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1`，`shasum -a 256 -c` 校验（值见 Global Constraints），不匹配时 `exit 1`。解压 `platform-tools/adb` 与 `platform-tools/NOTICE.txt`，再下载 scrcpy 的 `LICENSE`（`https://raw.githubusercontent.com/Genymobile/scrcpy/v5.0.1/LICENSE`），都放到 `App/Resources/Vendor/`，并给 adb 加 `chmod +x`。已存在且校验通过时跳过下载。
  Run: `bash scripts/fetch-vendor.sh && App/Resources/Vendor/adb version`
  Expected: 输出包含 `Android Debug Bridge`

- [ ] **Step 2: 写失败测试 `DeviceErrorTests`**
  ```swift
  @Test func adbNotFoundHasInstallHint() {
    let e = DeviceError.adbNotFound()
    #expect(e.code == .ADB_NOT_FOUND)
    #expect(e.suggestion?.contains("brew install --cask android-platform-tools") == true)
  }
  @Test func codeRawValuesMatchSpec() { #expect(DeviceError.Code.INJECT_PERMISSION_DENIED.rawValue == "INJECT_PERMISSION_DENIED") }
  ```

- [ ] **Step 3: 写 `Package.swift`（tools 6.0，`.macOS(.v14)`，products `DeviceCore`、`AndroidDriver`，`AndroidDriver` 依赖 `DeviceCore`，`AndroidDriverTests` 资源 `.copy("Fixtures")`），并实现上面的类型**
  文案：`adbNotFound` → message "未找到可用的 adb"，suggestion "请安装 Android Platform Tools：brew install --cask android-platform-tools，或安装 Android Studio"。
  Run: `swift test --package-path Packages/TandemCore --filter DeviceErrorTests` → PASS

- [ ] **Step 4: 写 `project.yml` 与最小 App**
  `name: Tandem`，`options.deploymentTarget.macOS: "14.0"`，`packages.TandemCore.path: Packages/TandemCore`。target `Tandem`：`type: application`，`sources: [App]`；`App/Resources/Vendor` 作为 folder reference 资源；settings 为 `PRODUCT_BUNDLE_IDENTIFIER=dev.tandem.Tandem`、`SWIFT_VERSION=6.0`、`ENABLE_APP_SANDBOX=NO`、`ENABLE_HARDENED_RUNTIME=NO`、`CODE_SIGN_IDENTITY="-"`；依赖 `DeviceCore`、`AndroidDriver`。preBuildScript：缺少 `App/Resources/Vendor/adb` 或 `scrcpy-server-v5.0.1` 时输出 `error: 请先运行 scripts/fetch-vendor.sh` 并 `exit 1`。
  `Info.plist` 包含 `NSLocalNetworkUsageDescription` = "用于通过 Wi-Fi 发现并连接调试中的 Android 设备"，`NSBonjourServices` = `["_adb-tls-pairing._tcp", "_adb-tls-connect._tcp"]`。
  `TandemApp`：`MenuBarExtra("Tandem", systemImage: "iphone.gen3")`，内容暂时只有"暂无设备"和"退出"。
  Run: App 构建命令 → 退出码 0

- [ ] **Step 5: Commit** `git add -A && git commit -m "chore: scaffold Tandem app, TandemCore package and vendor fetch"`

---

### Task 2: ProcessRunner 与 AdbLocator（必须验证可运行）

**Files:**
- Create: `Sources/AndroidDriver/Process/ProcessRunner.swift`, `Sources/AndroidDriver/Adb/AdbLocator.swift`, `Sources/AndroidDriver/Adb/AdbClient.swift`
- Delete: `Sources/AndroidDriver/Placeholder.swift`
- Test: `Tests/AndroidDriverTests/AdbLocatorTests.swift`, `Tests/AndroidDriverTests/Support/FakeProcessRunner.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ProcessResult: Sendable { public var exitCode: Int32; public var stdout: Data; public var stderr: Data; public var stdoutString: String }
  public protocol RunningProcess: Sendable { var lines: AsyncStream<String> { get }  /* stdout+stderr 合并，按行 */ ; func terminate() }
  public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult   // 超时抛 DeviceError.timeout
    func stream(_ executable: URL, _ args: [String]) throws -> RunningProcess
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: RunningProcess)  // 给 track-devices 用
  }
  public struct SystemProcessRunner: ProcessRunner      // Foundation.Process；启动失败（如 bad CPU type）抛错而不是崩溃
  public struct Adb: Sendable, Equatable { public var url: URL; public var version: String }
  public struct AdbLocator: Sendable {
    public init(runner: any ProcessRunner, environment: [String: String], home: URL, bundled: URL?)
    public func candidates() async -> [URL]   // 顺序见下
    public func locate() async throws -> Adb  // 无可用时抛 DeviceError.adbNotFound()
  }
  public struct AdbClient: Sendable {
    public init(adb: Adb, runner: any ProcessRunner)
    public func run(_ args: [String], serial: String? = nil, timeout: Duration = .seconds(10)) async throws -> ProcessResult  // serial 非空时前置 ["-s", serial]
    public func shell(_ serial: String, _ command: String, timeout: Duration = .seconds(10)) async throws -> String
    public func getprop(_ serial: String, _ key: String) async throws -> String   // trim 后的值
  }
  ```
- 候选顺序（去重、只保留存在的文件）：① `/bin/zsh -lc 'command -v adb'` 的输出（即用户 PATH）；② `$ANDROID_HOME/platform-tools/adb`；③ `$ANDROID_SDK_ROOT/platform-tools/adb`；④ `~/Library/Android/sdk/platform-tools/adb`；⑤ `/opt/homebrew/bin/adb`；⑥ `/usr/local/bin/adb`；⑦ bundled。
- 验证：`run(candidate, ["version"], timeout: .seconds(3))` 退出码为 0，且 stdout 包含 `Android Debug Bridge`；版本号取 `Version (\S+)` 的匹配。抛错或不满足条件时尝试下一个。

- [ ] **Step 1: 写 `FakeProcessRunner`**：按 `(executable.path, args)` 预设返回 `ProcessResult`，或者预设抛错；记录全部调用；可预设 `stream` 和 `streamBytes` 的输出。

- [ ] **Step 2: 写失败测试**
  ```swift
  @Test func skipsBrokenCandidate() async throws {
    // PATH 里的 /usr/local/bin/adb 抛 "bad CPU type in executable"；SDK 里的 adb 返回正常版本
    let adb = try await locator.locate()
    #expect(adb.url.path == home + "/Library/Android/sdk/platform-tools/adb")
    #expect(adb.version == "33.0.3-8952118")
  }
  @Test func fallsBackToBundled() async throws { /* 系统候选都失败 → bundled */ }
  @Test func throwsAdbNotFoundWhenNothingRuns() async { await #expect(throws: DeviceError.adbNotFound()) { try await locator.locate() } }
  @Test func clientPrependsSerial() async throws { /* client.run(["get-state"], serial: "X") → 调用参数为 ["-s","X","get-state"] */ }
  ```
  其中 SDK adb 的 stdout fixture 为 `"Android Debug Bridge version 1.0.41\nVersion 33.0.3-8952118\n"`。
  Run: `swift test --package-path Packages/TandemCore --filter AdbLocatorTests` → FAIL（未定义）

- [ ] **Step 3: 实现 ProcessRunner、AdbLocator、AdbClient**；`SystemProcessRunner.run` 超时后先 `terminate()`，再抛 `DeviceError.timeout("adb …")`。

- [ ] **Step 4: 跑测试** → PASS；再在本机手动验证一次：写一个临时测试，或者在 `swift repl` 里调用 `AdbLocator(runner: SystemProcessRunner(), …).locate()`，结果应选中 `~/Library/Android/sdk/platform-tools/adb`

- [ ] **Step 5: Commit** `feat(android): locate a runnable adb and wrap process execution`

---

### Task 3: 设备列表解析与 AndroidDriver（track-devices）

**Files:**
- Create: `Sources/AndroidDriver/Adb/DeviceListParser.swift`, `Sources/AndroidDriver/Adb/AndroidDriver.swift`, `Sources/DeviceCore/DeviceDriver.swift`, `Sources/DeviceCore/DeviceSession.swift`（先只写协议）
- Test: `Tests/AndroidDriverTests/DeviceListParserTests.swift`, `Fixtures/devices-l.txt`

**Interfaces:**
- Produces（DeviceCore）：
  ```swift
  public struct VideoFrame: @unchecked Sendable { public let pixelBuffer: CVPixelBuffer }
  public enum SessionState: Sendable, Equatable { case idle, connecting, running(width: Int, height: Int), disconnected, failed(DeviceError) }
  public enum SessionEvent: Sendable, Equatable { case state(SessionState); case injectPermissionDenied }
  public protocol DeviceSession: AnyObject, Sendable {
    var events: AsyncStream<SessionEvent> { get }       // 单订阅者（AppModel）
    func start() async                                  // 可在 disconnected/failed/idle 后再次调用
    func stop() async
    func send(_ action: InputAction) async
    func getClipboard() async throws -> String
    func setClipboard(_ text: String, paste: Bool) async throws
    func latestFrame() -> VideoFrame?
    func setFrameHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void)
  }
  public protocol DeviceDriver: Sendable {
    func deviceSnapshots() -> AsyncStream<[DeviceInfo]>
    func makeSession(for device: DeviceInfo) -> any DeviceSession
  }
  ```
- Produces（AndroidDriver）：
  ```swift
  public struct AdbDeviceEntry: Equatable, Sendable { var serial: String; var state: String; var model: String?; var transportId: String? }
  public enum DeviceListParser {
    static func parseLong(_ text: String) -> [AdbDeviceEntry]          // `adb devices -l` 和 track-devices 的单个包体都用它
    static func connectionKind(serial: String) -> ConnectionKind       // 含 ":" 或 "._adb-tls-connect." → .wifi
    static func deviceState(_ raw: String) -> DeviceState              // device→connected；unauthorized/authorizing→unauthorized；其余→offline
  }
  public struct TrackDevicesDecoder: Sendable { public mutating func append(_ data: Data) -> [[AdbDeviceEntry]] }  // 4 位十六进制长度 + 包体；可跨 chunk 拼接
  public final class AndroidDriver: DeviceDriver { public init(adb: AdbClient, runner: any ProcessRunner, serverJar: URL) }  // makeSession 本任务先 fatalError("Task 8")，Task 8 替换为真实实现
  ```
- `AndroidDriver.deviceSnapshots()`：运行 `adb track-devices -l`，用 `TrackDevicesDecoder` 拆出快照。对首次以 `device` 状态出现的 serial 调用一次 `getprop ro.serialno` 并缓存（失败时为 nil）。`name` 取 `model`，下划线替换为空格，缺失时用 serial。capabilities 固定为 `[.mirror, .touch, .keys, .text, .clipboard]`。进程意外退出时，2 秒后重启。

- [ ] **Step 1: 写 fixture 和失败测试**
  `devices-l.txt` 包含以下几行：
  `R5CT1234567            device usb:1-1 product:shiba model:Pixel_8 device:shiba transport_id:3`
  `9b2c8f11               unauthorized usb:1-2 transport_id:4`
  `192.168.1.23:5555      device product:fuxi model:Xiaomi_14 device:fuxi transport_id:5`
  `adb-R5CT1234567-AbCdEf._adb-tls-connect._tcp device product:shiba model:Pixel_8 device:shiba transport_id:6`
  `emulator-5554          offline transport_id:7`
  ```swift
  @Test func parsesLongFormat() { let e = DeviceListParser.parseLong(fixture); #expect(e.count == 5); #expect(e[0].model == "Pixel_8"); #expect(e[1].state == "unauthorized") }
  @Test func classifiesWifiSerials() { #expect(DeviceListParser.connectionKind(serial: "192.168.1.23:5555") == .wifi); #expect(DeviceListParser.connectionKind(serial: "adb-R5CT1234567-AbCdEf._adb-tls-connect._tcp") == .wifi); #expect(DeviceListParser.connectionKind(serial: "R5CT1234567") == .usb) }
  @Test func decoderHandlesSplitChunksAndEmptyList() {
    var d = TrackDevicesDecoder()
    #expect(d.append(Data("0000".utf8)) == [[]])
    let body = "R5CT1234567\tdevice\n"; let framed = String(format: "%04x", body.utf8.count) + body
    #expect(d.append(Data(framed.prefix(6).utf8)) == [])
    #expect(d.append(Data(framed.dropFirst(6).utf8)).first?.first?.serial == "R5CT1234567")
  }
  ```
  Run: `--filter DeviceListParserTests` → FAIL

- [ ] **Step 2: 实现**，跑测试 → PASS
- [ ] **Step 3: Commit** `feat(android): parse adb device lists and stream device snapshots`

---

### Task 4: DeviceManager（合并、去重、会话复用）

**Files:**
- Create: `Sources/DeviceCore/DeviceManager.swift`
- Test: `Tests/DeviceCoreTests/DeviceManagerTests.swift`

**Interfaces:**
- Consumes: `DeviceDriver`、`DeviceInfo`（Task 1、3）
- Produces:
  ```swift
  public actor DeviceManager {
    public init(drivers: [any DeviceDriver])
    public func devices() -> AsyncStream<[DeviceInfo]>            // 合并后的列表，任一驱动更新时推送
    public func session(for id: String) -> (any DeviceSession)?   // 设备在当前列表中时，懒创建并缓存；同一 id 始终返回同一实例
    public static func merge(_ snapshots: [[DeviceInfo]]) -> [DeviceInfo]
  }
  ```
- `merge` 规则：`hardwareSerial` 相同的 `connected` 设备只保留一个，优先 `.usb`；结果按 `name`、再按 `id` 排序。

- [ ] **Step 1: 写失败测试**
  ```swift
  @Test func dedupesSamePhonePreferringUSB() {
    let usb = info(id: "R5CT1234567", conn: .usb, hw: "R5CT1234567"), wifi = info(id: "192.168.1.23:5555", conn: .wifi, hw: "R5CT1234567")
    #expect(DeviceManager.merge([[wifi, usb]]).map(\.id) == ["R5CT1234567"])
  }
  @Test func keepsDevicesWithoutHardwareSerial() { /* hw 为 nil 的两台都保留 */ }
  @Test func sessionIsReusedForSameId() async { /* FakeDriver；两次 session(for:) 返回同一实例（===） */ }
  ```
- [ ] **Step 2: 实现**，跑 `--filter DeviceManagerTests` → PASS
- [ ] **Step 3: Commit** `feat(core): merge device lists and reuse sessions`

---

### Task 5: scrcpy 控制消息与设备消息编解码

**Files:**
- Create: `Sources/AndroidDriver/Scrcpy/ControlMessage.swift`, `Sources/AndroidDriver/Scrcpy/DeviceMessage.swift`
- Test: `Tests/AndroidDriverTests/ControlMessageTests.swift`, `DeviceMessageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum AndroidKeyAction: UInt8 { case down = 0, up = 1 }
  enum AndroidMotionAction: UInt8 { case down = 0, up = 1, move = 2 }
  enum AndroidKeycode { static let home: UInt32 = 3, back = 4, dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22,
                        volumeUp = 24, volumeDown = 25, power = 26, tab = 61, enter = 66, del = 67, forwardDel = 112, appSwitch = 187 }
  enum PointerId { static let mouse: UInt64 = .max, genericFinger: UInt64 = .max - 1 }
  enum ControlMessage: Equatable, Sendable {
    case injectKeycode(action: AndroidKeyAction, keycode: UInt32, repeat: UInt32, metaState: UInt32)      // type 0，14 字节
    case injectText(String)                                                                              // type 1；u32 长度 + UTF-8，按 UTF-8 边界截断到 300 字节
    case injectTouch(action: AndroidMotionAction, pointerId: UInt64, x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16,
                     pressure: Float, actionButton: UInt32, buttons: UInt32)                             // type 2，32 字节
    case injectScroll(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hscroll: Float, vscroll: Float, buttons: UInt32) // type 3，21 字节
    case backOrScreenOn(AndroidKeyAction)                                                                // type 4
    case getClipboard(copyKey: UInt8)                                                                    // type 8
    case setClipboard(sequence: UInt64, text: String, paste: Bool)                                       // type 9
    func encoded() -> Data          // 大端序
  }
  enum DeviceMessage: Equatable, Sendable { case clipboard(String); case ackClipboard(sequence: UInt64) }
  struct DeviceMessageDecoder: Sendable { mutating func append(_ data: Data) throws -> [DeviceMessage] }   // 不完整时缓存等待；未知 type 抛 DeviceError.connectionFailed
  ```
- 定点数换算（与 scrcpy `binary.h` 一致）：pressure 为 `u16 = min(UInt32(f * 65536), 0xffff)`；scroll 先除以 16 并夹到 [-1, 1]，再 `i16 = min(Int32(f * 32768), 0x7fff)`。

- [ ] **Step 1: 写失败测试（字节向量来自 scrcpy v5.0.1 `app/tests/test_control_msg_serialize.c` 的同构用例）**
  ```swift
  @Test func touchEncoding() {
    let m = ControlMessage.injectTouch(action: .down, pointerId: 0x1234567887654321, x: 100, y: 200, screenWidth: 1080, screenHeight: 1920,
                                       pressure: 1.0, actionButton: 1, buttons: 1)
    #expect([UInt8](m.encoded()) == [0x02, 0x00, 0x12,0x34,0x56,0x78,0x87,0x65,0x43,0x21, 0,0,0,0x64, 0,0,0,0xc8, 0x04,0x38, 0x07,0x80,
                                     0xff,0xff, 0,0,0,0x01, 0,0,0,0x01])
  }
  @Test func scrollEncoding() {
    let m = ControlMessage.injectScroll(x: 260, y: 1026, screenWidth: 1080, screenHeight: 1920, hscroll: 16, vscroll: -16, buttons: 1)
    #expect([UInt8](m.encoded()) == [0x03, 0,0,0x01,0x04, 0,0,0x04,0x02, 0x04,0x38, 0x07,0x80, 0x7f,0xff, 0x80,0x00, 0,0,0,0x01])
  }
  @Test func keycodeEncoding() { #expect([UInt8](ControlMessage.injectKeycode(action: .up, keycode: 66, repeat: 5, metaState: 0x41).encoded())
                                         == [0x00, 0x01, 0,0,0,0x42, 0,0,0,0x05, 0,0,0,0x41]) }
  @Test func textEncodingTruncatesAtUtf8Boundary() { /* 299 个 "a" + "中"（3 字节）→ 长度字段为 299 */ }
  @Test func setClipboardEncoding() { #expect([UInt8](ControlMessage.setClipboard(sequence: 0x0102030405060708, text: "hello", paste: true).encoded())
                                              == [0x09, 1,2,3,4,5,6,7,8, 0x01, 0,0,0,0x05] + Array("hello".utf8)) }
  @Test func getClipboardAndBack() { #expect([UInt8](ControlMessage.getClipboard(copyKey: 0).encoded()) == [0x08, 0x00]); #expect([UInt8](ControlMessage.backOrScreenOn(.down).encoded()) == [0x04, 0x00]) }
  @Test func decodesClipboardAcrossChunks() throws { var d = DeviceMessageDecoder(); #expect(try d.append(Data([0x00, 0,0,0,5, 0x68])) == []); #expect(try d.append(Data("ello".utf8)) == [.clipboard("hello")]) }
  @Test func decodesAck() throws { var d = DeviceMessageDecoder(); #expect(try d.append(Data([0x01, 1,2,3,4,5,6,7,8])) == [.ackClipboard(sequence: 0x0102030405060708)]) }
  @Test func unknownTypeThrows() { var d = DeviceMessageDecoder(); #expect(throws: DeviceError.self) { try d.append(Data([0x7f])) } }
  ```
- [ ] **Step 2: 实现**，跑 `--filter ControlMessageTests` 和 `--filter DeviceMessageTests` → PASS
- [ ] **Step 3: Commit** `feat(scrcpy): encode control messages and decode device messages`

---

### Task 6: 视频流头解析与 H.264 码流工具

**Files:**
- Create: `Sources/AndroidDriver/Scrcpy/VideoHeader.swift`, `Sources/AndroidDriver/Scrcpy/H264Parser.swift`
- Test: `Tests/AndroidDriverTests/VideoHeaderTests.swift`, `H264ParserTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum VideoCodecId { static let h264: UInt32 = 0x68323634; static let disabled: UInt32 = 0; static let configError: UInt32 = 1 }
  enum VideoHeader: Equatable { case session(width: Int, height: Int); case media(config: Bool, keyFrame: Bool, pts: UInt64, size: Int)
    static func parse(_ header: Data) -> VideoHeader }   // header 必须为 12 字节；最高位为 1 表示 session 包
  enum H264Parser {
    static func nalUnits(annexB: Data) -> [Data]                       // 按 00 00 01 / 00 00 00 01 起始码切分，结果不含起始码
    static func nalType(_ nal: Data) -> UInt8                           // nal[0] & 0x1f
    static func parameterSets(annexB: Data) -> (sps: Data, pps: Data)?  // 类型 7 / 8
    static func avcc(fromAnnexB: Data) -> Data                          // 每个 NAL 前加 4 字节大端长度
  }
  ```
- 协议格式（scrcpy v5.0.1 `doc/develop.md`）：media 包第 0 字节 bit6 为 config，bit5 为 key frame，PTS 取低 61 位；第 8～11 字节为包长。session 包第 4～7 字节为宽，第 8～11 字节为高。

- [ ] **Step 1: 写失败测试**
  ```swift
  @Test func parsesSession() { #expect(VideoHeader.parse(Data([0x80,0,0,0, 0,0,0x04,0x38, 0,0,0x09,0x60])) == .session(width: 1080, height: 2400)) }
  @Test func parsesConfig() { #expect(VideoHeader.parse(Data([0x40,0,0,0,0,0,0,0, 0,0,0,0x1a])) == .media(config: true, keyFrame: false, pts: 0, size: 26)) }
  @Test func parsesKeyFrame() { #expect(VideoHeader.parse(Data([0x20,0,0,0,0,0,0x03,0xe8, 0,0,0x10,0])) == .media(config: false, keyFrame: true, pts: 1000, size: 4096)) }
  @Test func splitsMixedStartCodes() { #expect(H264Parser.nalUnits(annexB: Data([0,0,0,1,0x67,0xAA, 0,0,1,0x68,0xBB])) == [Data([0x67,0xAA]), Data([0x68,0xBB])]) }
  @Test func avccPrefixesLengths() { #expect([UInt8](H264Parser.avcc(fromAnnexB: Data([0,0,0,1,0x65,1,2]))) == [0,0,0,3,0x65,1,2]) }
  @Test func extractsParameterSets() { let p = H264Parser.parameterSets(annexB: Data([0,0,0,1,0x67,9, 0,0,0,1,0x68,8])); #expect(p?.sps == Data([0x67,9]) && p?.pps == Data([0x68,8])) }
  ```
- [ ] **Step 2: 实现**，跑测试 → PASS
- [ ] **Step 3: Commit** `feat(scrcpy): parse video headers and H.264 bitstreams`

---

### Task 7: H264Decoder（VideoToolbox）

**Files:**
- Create: `Sources/AndroidDriver/Scrcpy/H264Decoder.swift`
- Create fixture: `Tests/AndroidDriverTests/Fixtures/testsrc-64x48.h264`
- Test: `Tests/AndroidDriverTests/H264DecoderTests.swift`

**Interfaces:**
- Consumes: `H264Parser`（Task 6）、`VideoFrame`（Task 3）
- Produces:
  ```swift
  protocol VideoDecoding: AnyObject, Sendable {
    func decode(config annexB: Data)            // 用 SPS/PPS 建 CMVideoFormatDescription；与当前不同则重建 VTDecompressionSession
    func decode(frame annexB: Data, pts: UInt64)
    func reset()                                // 销毁 session，等待下一个 config
  }
  final class H264Decoder: VideoDecoding, @unchecked Sendable { init(onFrame: @escaping @Sendable (VideoFrame) -> Void) }
  ```
- 输出像素格式为 `kCVPixelFormatType_32BGRA`，并设置 `kCVPixelBufferIOSurfacePropertiesKey: [:]`，让窗口 layer 可以直接显示，P2 截图也能直接转换。没有 config 时收到的帧直接丢弃。解码错误只记录日志，不抛出。

- [ ] **Step 1: 生成 fixture**
  Run: `ffmpeg -f lavfi -i testsrc=size=64x48:rate=10 -frames:v 5 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -x264-params keyint=5 -bsf:v h264_mp4toannexb -f h264 Packages/TandemCore/Tests/AndroidDriverTests/Fixtures/testsrc-64x48.h264`
  Expected: 文件存在，几 KB 大小

- [ ] **Step 2: 写失败测试**
  ```swift
  @Test func decodesFixtureToBGRAFrames() async throws {
    // 用 H264Parser 切分 fixture：类型 7、8 拼成 config 包；类型 1、5 每个 NAL 作为一帧（重新加上 00 00 00 01）；其余类型跳过
    // decode(config:) 一次，再逐帧 decode(frame:pts:)；用 AsyncStream 收集 onFrame 的输出，最多等 2 秒
    #expect(frames.count >= 1)
    #expect(CVPixelBufferGetWidth(frames[0].pixelBuffer) == 64 && CVPixelBufferGetHeight(frames[0].pixelBuffer) == 48)
    #expect(CVPixelBufferGetPixelFormatType(frames[0].pixelBuffer) == kCVPixelFormatType_32BGRA)
    #expect(CVPixelBufferGetIOSurface(frames[0].pixelBuffer) != nil)
  }
  @Test func framesBeforeConfigAreDropped() async { /* 不先 decode(config:) 就 decode(frame:) → 0 帧，且不崩溃 */ }
  ```
- [ ] **Step 3: 实现**，跑 `--filter H264DecoderTests` → PASS
- [ ] **Step 4: Commit** `feat(scrcpy): hardware H.264 decoding via VideoToolbox`

---

### Task 8: scrcpy 连接、服务端启动与 AndroidSession

**Files:**
- Create: `Sources/AndroidDriver/Scrcpy/ByteStream.swift`, `ScrcpyConnection.swift`, `ScrcpyServer.swift`, `Sources/AndroidDriver/AndroidSession.swift`
- Modify: `Sources/AndroidDriver/Adb/AndroidDriver.swift`（`makeSession` 返回 `AndroidSession`）
- Test: `Tests/AndroidDriverTests/Support/InMemoryByteStream.swift`, `ScrcpyServerTests.swift`, `ScrcpyConnectionTests.swift`, `AndroidSessionTests.swift`

**Interfaces:**
- Consumes: `AdbClient`（Task 2）、`ControlMessage`/`DeviceMessageDecoder`（Task 5）、`VideoHeader`（Task 6）、`VideoDecoding`（Task 7）、`DeviceSession`（Task 3）
- Produces:
  ```swift
  public protocol ByteStream: Sendable { func readExactly(_ n: Int) async throws -> Data; func write(_ data: Data) async throws; func close() }  // EOF 时抛 ByteStreamError.closed
  public final class TCPByteStream: ByteStream { public static func connect(port: UInt16) async throws -> TCPByteStream }  // NWConnection 连接 127.0.0.1
  public struct ScrcpyLaunchOptions: Equatable, Sendable {
    var scid: UInt32; var maxSize: Int; var bitRate: Int; var maxFps: Int
    static func `for`(_ kind: ConnectionKind, scid: UInt32) -> Self   // .usb: 1920 / 8_000_000 / 60；.wifi: 1280 / 4_000_000 / 60
    var socketName: String                                           // String(format: "scrcpy_%08x", scid)
    func serverCommand() -> [String]
  }
  public struct LaunchedServer: Sendable { var connection: ScrcpyConnection; var logs: AsyncStream<String>; var stop: @Sendable () async -> Void }
  public protocol ScrcpyLauncher: Sendable { func launch(serial: String, options: ScrcpyLaunchOptions) async throws -> LaunchedServer }
  public struct AdbScrcpyLauncher: ScrcpyLauncher { public init(adb: AdbClient, runner: any ProcessRunner, serverJar: URL) }
  public struct ScrcpyConnection: Sendable {
    var deviceName: String; var video: any ByteStream; var control: any ByteStream
    static func open(port: UInt16, connect: @Sendable (UInt16) async throws -> any ByteStream,
                     retries: Int = 100, retryDelay: Duration = .milliseconds(100)) async throws -> ScrcpyConnection
  }
  enum ScrcpyLog { static func isInjectPermissionError(_ line: String) -> Bool }   // 行内包含 "INJECT_EVENTS"
  public actor AndroidSession: DeviceSession {
    public init(device: DeviceInfo, launcher: any ScrcpyLauncher, makeDecoder: @Sendable (@escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding)
  }
  ```
- `serverCommand()` 的值必须完全如下：`["CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1", "scid=<%08x>", "log_level=info", "audio=false", "video_codec=h264", "max_size=<n>", "video_bit_rate=<n>", "max_fps=60", "tunnel_forward=true", "clipboard_autosync=false"]`
- `AdbScrcpyLauncher.launch` 的步骤：
  1. `push <serverJar> /data/local/tmp/scrcpy-server.jar`，超时 30 秒；
  2. `forward tcp:0 localabstract:<socketName>`，stdout 即本地端口号；
  3. `runner.stream(adb, ["-s", serial, "shell"] + serverCommand())`；
  4. `ScrcpyConnection.open(port:connect: TCPByteStream.connect)`；
  5. 返回的 `stop` 依次执行：终止进程、关闭 socket、`forward --remove tcp:<port>`。
- `ScrcpyConnection.open` 握手（forward 隧道）：连接视频 socket，读 1 个 dummy byte；连接失败或读到 EOF 时关闭，等待 `retryDelay` 后重试，最多 `retries` 次，用完抛 `connectionFailed`。然后读 64 字节设备名（在第一个 NUL 处截断），最后连接控制 socket。
- `AndroidSession` 的行为：
  - **start**：发出 `.connecting`，scid 随机取 31 位；`launch` 失败时发出 `.failed(error)`。
  - **视频循环**：读 4 字节 codec id，不等于 h264 时报 `.failed(connectionFailed("视频编码不受支持"))`。之后循环读 12 字节头：
    - session 包：记录视频尺寸，`decoder.reset()`，发出 `.running(width:height:)`；
    - media 包：读 `size` 字节，config 包交给 `decode(config:)`，其他交给 `decode(frame:pts:)`。
    - 解码器回调里更新 `latestFrame`（用锁保护），并调用 frame handler。
  - **控制读循环**：用 `DeviceMessageDecoder` 解码，`.clipboard` 交给所有等待中的 `getClipboard`，`.ackClipboard` 按 sequence 交给对应的 `setClipboard`。
  - **日志循环**：每个会话里，第一次匹配 `isInjectPermissionError` 时发出 `.injectPermissionDenied`。
  - **断开**：视频 socket 读到 EOF 或出错时，执行 `stop` 清理，再发出 `.disconnected`。
  - **send**：会话不在 `running` 状态时直接返回（**不排队**）。映射规则：
    - `.touch`：pointerId 用 `genericFinger`；`x = clamp(Int32(p.x * w), 0, w-1)`，y 同理；screen 尺寸用当前视频尺寸；down、move 的 pressure 为 1.0，up 为 0；actionButton 和 buttons 都为 0。
    - `.scroll`：dx、dy 各夹到 [-16, 16]，buttons 为 0。
    - `.key(.back)`：依次发 `backOrScreenOn(.down)`、`backOrScreenOn(.up)`。
    - 其他按键：依次发 `injectKeycode` 的 down、up，repeat 为 0，meta 为 0。对照表：home 3、recents 187、volumeUp 24、volumeDown 25、power 26、enter 66、delete 67、forwardDelete 112、tab 61、up 19、down 20、left 21、right 22。
    - `.text`：全部字符为可打印 ASCII（0x20～0x7e）时，按 300 字节分段依次发 `injectText`；否则整段走 `setClipboard(text, paste: true)`。
  - **getClipboard**：发 `getClipboard(copyKey: 0)`，2 秒内没有回应抛 `.timeout("读取剪切板")`。
  - **setClipboard**：sequence 从 1 开始自增，等待对应的 ack，2 秒超时抛 `.timeout("写入剪切板")`。
  - **stop**：取消所有循环，调用 `launched.stop()`，发出 `.idle`。

- [ ] **Step 1: 写 `InMemoryByteStream`**：一对互通的流；测试端可以 `feed(Data)` 和 `finish()`，并读取会话写出的字节。

- [ ] **Step 2: 写 ScrcpyServer 和 ScrcpyConnection 的失败测试**
  ```swift
  @Test func serverCommandIsExact() { let o = ScrcpyLaunchOptions.for(.usb, scid: 0x0abc1234)
    #expect(o.serverCommand() == ["CLASSPATH=/data/local/tmp/scrcpy-server.jar","app_process","/","com.genymobile.scrcpy.Server","5.0.1","scid=0abc1234",
      "log_level=info","audio=false","video_codec=h264","max_size=1920","video_bit_rate=8000000","max_fps=60","tunnel_forward=true","clipboard_autosync=false"]) }
  @Test func wifiUsesLowerQuality() { #expect(ScrcpyLaunchOptions.for(.wifi, scid: 1).maxSize == 1280 && ScrcpyLaunchOptions.for(.wifi, scid: 1).bitRate == 4_000_000) }
  @Test func launcherPushesForwardsAndStarts() async throws { /* FakeProcessRunner：forward 返回 "27183\n"；断言调用顺序依次为 push、forward、stream(shell…)；connect 用注入的 InMemory */ }
  @Test func detectsInjectPermissionLine() { #expect(ScrcpyLog.isInjectPermissionError("java.lang.SecurityException: Injecting input events requires the caller (or the source of the instrumentation, if any) to have the INJECT_EVENTS permission.")) }
  @Test func handshakeRetriesUntilDummyByte() async throws { /* 第 1、2 次连接立即 EOF，第 3 次先发 0x00，再发 "Pixel 8" 补 NUL 到 64 字节 → deviceName == "Pixel 8"，共尝试 3 次 + 1 次控制 socket 连接 */ }
  ```
  为了能注入 connect 并测试启动流程，`AdbScrcpyLauncher` 增加一个内部构造参数 `connect: @Sendable (UInt16) async throws -> any ByteStream`，默认值为 `TCPByteStream.connect`。

- [ ] **Step 3: 写 AndroidSession 的失败测试**（FakeLauncher 返回 InMemory 流；FakeDecoder 记录调用）
  ```swift
  @Test func runningAfterSessionPacket() async { /* feed codec 0x68323634 和 session 1080x2400 → events 依次为 .connecting、.running(width:1080,height:2400) */ }
  @Test func rotationEmitsNewSizeAndResetsDecoder() async { /* 先 session 1080x2400，再 config，再 session 2400x1080 → 第二个 .running(2400,1080)，decoder.reset 调用 2 次，之后的 config 仍交给解码器 */ }
  @Test func tapMapsNormalizedToVideoPixels() async { /* running 1080x2400；send(.touch(.down, .init(x:0.5,y:0.25))) → 控制端收到 injectTouch(down, genericFinger, 540, 600, 1080, 2400, 1.0, 0, 0) 的编码 */ }
  @Test func longAsciiIsChunked() async { /* 650 个 "a" → 3 条 injectText，长度依次为 300、300、50 */ }
  @Test func nonAsciiUsesClipboardPaste() async { /* "你好 test" → 1 条 setClipboard(sequence:1, paste:true)；随后 feed ack(1) 让 send 返回 */ }
  @Test func backUsesBackOrScreenOn() async { /* → [0x04,0x00] 和 [0x04,0x01] */ }
  @Test func inputWhenNotRunningIsDropped() async { /* start 之前 send(.key(.home)) → 控制端没有收到字节；之后到 running 也不会补发 */ }
  @Test func getClipboardReturnsDeviceText() async throws { /* 控制端收到 [0x08,0x00] 后 feed clipboard "复制的内容" → 返回 "复制的内容" */ }
  @Test func getClipboardTimesOut() async { /* 不回应 → 抛 DeviceError.code == .TIMEOUT */ }
  @Test func videoEOFEmitsDisconnectedAndCallsStop() async { /* finish 视频流 → 发出 .disconnected，FakeLauncher 的 stop 调用 1 次；之后 start() 可以再次进入 .connecting */ }
  @Test func injectPermissionEventFiresOnce() async { /* logs 推两行 INJECT_EVENTS → 只发一次 .injectPermissionDenied */ }
  ```
- [ ] **Step 4: 实现** ByteStream / TCPByteStream / ScrcpyLaunchOptions / AdbScrcpyLauncher / ScrcpyConnection / AndroidSession；`AndroidDriver.makeSession` 改为返回 `AndroidSession(device:, launcher: AdbScrcpyLauncher(…), makeDecoder: { H264Decoder(onFrame: $0) })`，`serverJar` 由 App 通过 `AndroidDriver.init` 传入。`AndroidSession` 是 actor，协议里的 `events`、`latestFrame()`、`setFrameHandler` 需声明为 `nonisolated`（`events` 用 `nonisolated let` + `AsyncStream.makeStream()`，帧与 handler 用 `OSAllocatedUnfairLock` 保护）。
- [ ] **Step 5: 跑** `--filter ScrcpyServerTests`、`--filter ScrcpyConnectionTests`、`--filter AndroidSessionTests` → PASS；再跑全部包测试 → PASS
- [ ] **Step 6: Commit** `feat(android): scrcpy session with video, input and clipboard`

---

### Task 9: 设备窗口（渲染、鼠标、键盘、输入法、状态遮罩）

**Files:**
- Create: `App/DeviceWindow/ViewGeometry.swift`, `KeyMapping.swift`, `VideoSurfaceView.swift`, `DeviceWindowView.swift`
- Test: `AppTests/ViewGeometryTests.swift`、`AppTests/KeyMappingTests.swift`（project.yml 新增 unit-test target `TandemTests`，host 为 App）
- Modify: `project.yml`（新增测试 target 和 scheme 的 test action）

**Interfaces:**
- Consumes: `DeviceSession`、`InputAction`、`SessionState`
- Produces:
  ```swift
  enum ViewGeometry {
    static func videoRect(viewSize: CGSize, videoSize: CGSize) -> CGRect                   // 等比居中
    static func normalizedPoint(_ p: CGPoint, viewSize: CGSize, videoSize: CGSize, clamp: Bool) -> NormalizedPoint?   // p 以左上为原点；clamp=false 时落在黑边返回 nil
  }
  enum KeyCommand: Equatable { case input(InputAction); case pasteFromMac }
  enum KeyMapping { static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyCommand? }   // 返回 nil 表示交给输入法 / insertText
  final class VideoSurfaceView: NSView, NSTextInputClient { var onInput: ((InputAction) -> Void)?; var onPaste: (() -> Void)?; func show(_ frame: VideoFrame) }
  ```
- KeyMapping 对照表：
  - 无 ⌘ 时：Return(36) 对应 enter，Delete(51) 对应 delete，ForwardDelete(117) 对应 forwardDelete，Tab(48) 对应 tab，Escape(53) 对应 back，方向键 123/124/125/126 分别对应 left/right/down/up。
  - 带 ⌘ 时：H(4) 对应 home，S(1) 对应 recents，P(35) 对应 power，↑(126) 对应 volumeUp，↓(125) 对应 volumeDown，V(9) 对应 `.pasteFromMac`。
- VideoSurfaceView：
  - **渲染**：`wantsLayer`，背景黑色，`contentsGravity = .resizeAspect`；`show` 在主线程把 `layer.contents` 设为 `CVPixelBufferGetIOSurface` 的结果；`isFlipped = true`。
  - **鼠标**：mouseDown 时取 `clamp:false`，结果为 nil 就忽略整次拖动；mouseDragged 和 mouseUp 用 `clamp:true`。右键对应 `.key(.back)`。
  - **滚轮**：有精确增量（触控板）时用 delta / 10，否则用 delta，作为 `.scroll`。
  - **键盘**：`keyDown` 先查 KeyMapping，没有命中时调用 `interpretKeyEvents`。
  - **快捷键**：⌘ 组合在 `performKeyEquivalent` 中拦截，防止 ⌘H 隐藏 App。
  - **文本输入**：`insertText` 对应 `.text(string)`，中文输入法上屏的文字也走这里；`setMarkedText` 时只保存不发送。
  - `acceptsFirstResponder = true`。
- DeviceWindowView：
  - 用 `NSViewRepresentable` 包装 VideoSurfaceView；`onPaste` 读取 `NSPasteboard.general.string(forType: .string)`，有内容时调用 `setClipboard(text, paste: true)`。
  - **状态遮罩**：
    - `.connecting`：显示"正在连接…"和进度指示。
    - `.disconnected`：显示"已断开，设备重新连接后将自动恢复"。
    - `.failed(e)`：显示 `e.message`、`e.suggestion` 和「重试」按钮。
    - 设备为 unauthorized 时：显示"请在手机上允许 USB 调试"。
  - **底部按钮**：返回、主页、多任务三个图标按钮，各自设置 `aria` 等效的 `.help` 和 `accessibilityLabel`。
  - **窗口比例**：收到 `.running(w,h)` 时设置 `window.contentAspectRatio = NSSize(w,h)`。首次运行时把内容高度设为屏幕可见高度的 80%，宽度按比例计算。

- [ ] **Step 1: 写失败测试**
  ```swift
  @Test func videoRectLetterboxes() { #expect(ViewGeometry.videoRect(viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400)) == CGRect(x: 120, y: 0, width: 360, height: 800)) }
  @Test func letterboxPointIsNil() { #expect(ViewGeometry.normalizedPoint(.init(x: 50, y: 400), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: false) == nil) }
  @Test func centerMapsToHalf() { #expect(ViewGeometry.normalizedPoint(.init(x: 300, y: 400), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: false) == NormalizedPoint(x: 0.5, y: 0.5)) }
  @Test func dragClampsToEdge() { #expect(ViewGeometry.normalizedPoint(.init(x: 590, y: 900), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: true) == NormalizedPoint(x: 1, y: 1)) }
  @Test func cmdHIsHome() { #expect(KeyMapping.command(keyCode: 4, modifiers: .command) == .input(.key(.home))) }
  @Test func escapeIsBack() { #expect(KeyMapping.command(keyCode: 53, modifiers: []) == .input(.key(.back))) }
  @Test func cmdVIsPaste() { #expect(KeyMapping.command(keyCode: 9, modifiers: .command) == .pasteFromMac) }
  @Test func plainLetterGoesToIME() { #expect(KeyMapping.command(keyCode: 0, modifiers: []) == nil) }
  ```
  Run: `xcodegen generate && xcodebuild -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' -quiet test` → FAIL
- [ ] **Step 2: 实现**，再跑同一命令 → PASS
- [ ] **Step 3: Commit** `feat(app): device window with rendering and input mapping`

---

### Task 10: AppModel、菜单栏、自动开窗与重连、国产 ROM 横幅、设置

**Files:**
- Create: `App/AppModel.swift`, `App/MenuBar/DeviceMenuView.swift`, `App/DeviceWindow/RomBannerView.swift`, `App/Settings/SettingsView.swift`, `Sources/AndroidDriver/RomGuide.swift`
- Modify: `App/TandemApp.swift`, `App/DeviceWindow/DeviceWindowView.swift`
- Test: `Tests/AndroidDriverTests/RomGuideTests.swift`

**Interfaces:**
- Consumes: `DeviceManager`、`AndroidDriver`、`AdbLocator`、`DeviceSession`
- Produces:
  ```swift
  public struct RomGuide: Equatable, Sendable { public var brand: String; public var steps: [String]
    public static func forManufacturer(_ manufacturer: String) -> RomGuide }
  @MainActor @Observable final class AppModel {
    var devices: [DeviceInfo]; var sessionStates: [String: SessionState]; var injectDenied: Set<String>
    var adb: Adb?; var startupError: DeviceError?
    var autoOpenOnConnect: Bool       // UserDefaults 键 "autoOpenOnConnect"，默认 false
    var openWindowIDs: Set<String>    // 设备窗口 onAppear / onDisappear 时维护
    func start() async                // 定位 adb（找不到时设置 startupError）→ 建 DeviceManager → 订阅 devices
    func session(for id: String) -> (any DeviceSession)?
    func windowOpened(_ id: String) async; func windowClosed(_ id: String) async   // 开窗时 start，关窗时 stop
    var requestOpenWindow: ((String) -> Void)?   // 由 SwiftUI 注入 openWindow
  }
  ```
- RomGuide 的匹配（manufacturer 转小写后包含以下关键字）与文案：
  - xiaomi/redmi/poco → brand "小米"，steps：["设置 → 更多设置 → 开发者选项", "打开「USB 调试（安全设置）」（可能需要登录小米账号并插入 SIM 卡）"]
  - oppo/realme/oneplus → "OPPO / 一加 / realme"：["设置 → 其他设置 → 开发者选项", "关闭「禁止权限监控」"]
  - vivo/iqoo → "vivo / iQOO"：["设置 → 系统管理 → 开发者选项", "打开「USB 模拟点击」"]
  - 其他 → "该设备"：["打开开发者选项", "查找与「USB 调试（安全设置）」或「模拟点击」相关的开关并打开"]
  - 横幅标题固定为"无法注入点击：需要额外开启调试权限"，底部小字"以手机上的实际选项为准"，按钮「已打开，重新连接」点击后 stop + start。品牌通过 `getprop ro.product.manufacturer` 获取，在收到 `.injectPermissionDenied` 时查询。
- 自动重连：设备列表更新时，对 `openWindowIDs` 中的每个 id，如果设备为 `connected`，且会话状态为 `.disconnected`、`.idle` 或 `.failed`，就调用 `start()`。
- 自动开窗：`autoOpenOnConnect` 开启时，id 首次出现且状态为 `connected` 时调用 `requestOpenWindow`。
- 菜单（DeviceMenuView）：
  - 每行显示设备名、"USB" 或 "Wi-Fi"、状态文字（已连接 / 未授权 / 离线）。
  - 已连接的行可以点击，点击后打开窗口；未授权的行置灰，附提示"请在手机上允许 USB 调试"。
  - 分隔线下依次是「无线配对…」（打开 `WindowGroup(id: "pairing")`）、`SettingsLink`「设置…」、「退出」。
  - 有 `startupError` 时，菜单顶部显示错误信息和建议。
- SettingsView：「插上设备时自动打开窗口」开关；只读显示当前 adb 的路径和版本。
- TandemApp：`WindowGroup(id: "device", for: String.self)` 承载 DeviceWindowView；`Window("无线配对", id: "pairing")` 在 Task 11 填充内容；`Settings { SettingsView() }`。

- [ ] **Step 1: 写失败测试** `RomGuideTests`：`forManufacturer("Xiaomi").brand == "小米"`、`forManufacturer("OnePlus").brand == "OPPO / 一加 / realme"`、`forManufacturer("vivo").steps.last == "打开「USB 模拟点击」"`、`forManufacturer("Google").brand == "该设备"`
- [ ] **Step 2: 实现 RomGuide** → `--filter RomGuideTests` PASS
- [ ] **Step 3: 实现 AppModel、菜单、横幅、设置**；跑 App 构建命令，退出码 0
- [ ] **Step 4: 手动冒烟**（需要 USB 连一台 Android）：运行 App，菜单里出现设备 → 点开窗口能看到画面 → 点击、滑动有效 → 拔线后显示"已断开"→ 插回后自动恢复。如果当时没有设备，记录为"未验证"，留到 Task 12 一起做。
- [ ] **Step 5: Commit** `feat(app): menu bar device list, auto reconnect and ROM guidance`

---

### Task 11: 无线连接（扫码配对、配对码、一键转无线）

**Files:**
- Create: `Sources/AndroidDriver/Adb/MdnsParser.swift`, `Sources/AndroidDriver/Adb/WirelessConnector.swift`, `App/Pairing/PairingView.swift`
- Create fixtures: `Fixtures/mdns-services.txt`, `Fixtures/ip-addr-wlan0.txt`
- Modify: `App/TandemApp.swift`（pairing 窗口内容）
- Test: `Tests/AndroidDriverTests/WirelessTests.swift`

**Interfaces:**
- Consumes: `AdbClient`
- Produces:
  ```swift
  public struct MdnsService: Equatable, Sendable { public enum Kind: Sendable { case pairing, connect }; var instance: String; var kind: Kind; var host: String; var port: UInt16 }
  public enum MdnsParser { public static func parse(_ text: String) -> [MdnsService] }   // 跳过标题行；service type 可能带结尾的 "."
  public struct PairingCredentials: Equatable, Sendable {
    public var name: String; public var password: String
    public static func generate<G: RandomNumberGenerator>(using g: inout G) -> Self   // name = "studio-" + 10 位 [a-zA-Z0-9]；password = 12 位数字
    public var qrPayload: String                                                      // "WIFI:T:ADB;S:\(name);P:\(password);;"
  }
  public enum WirelessStep: Equatable, Sendable { case waitingForScan, pairing, connecting, connected(serial: String) }
  public actor WirelessConnector {
    public init(adb: AdbClient, pollInterval: Duration = .seconds(1))
    public func pairWithQR(_ creds: PairingCredentials, timeout: Duration = .seconds(120), progress: @Sendable (WirelessStep) -> Void) async throws -> String
    public func pairWithCode(hostPort: String, code: String, progress: @Sendable (WirelessStep) -> Void) async throws -> String
    public func switchToWireless(serial: String) async throws -> String
    public static func parseWlanIPv4(_ text: String) -> String?
  }
  ```
- pairWithQR 流程：
  1. 每隔 `pollInterval` 执行一次 `mdns services`，直到出现 `instance == creds.name` 的 `.pairing` 服务，或超过 `timeout` 抛 `.timeout("等待扫码")`；
  2. 执行 `pair host:port password`，stdout 包含 `Successfully paired` 才算成功，否则抛 `connectionFailed(stdout)`；
  3. 在 30 秒内轮询同一 host 的 `.connect` 服务，再执行 `connect host:port`。stdout 包含 `connected to`（包括 `already connected to`）时，返回 `"host:port"`。
- pairWithCode：直接执行 `pair hostPort code`，后面同第 3 步。
- switchToWireless：
  1. 执行 `shell ip -f inet addr show wlan0` 并用 `parseWlanIPv4` 解析；解析不到时抛 `connectionFailed("手机未连接 Wi-Fi")`；
  2. 执行 `tcpip 5555`，等待 1 秒；
  3. 执行 `connect <ip>:5555`，最多重试 3 次、每次间隔 1 秒；成功时返回 `"<ip>:5555"`。
- PairingView 分左右两栏：
  - **左栏**：
    - 用 `CIFilter.qrCodeGenerator` 生成的二维码，内容为 `qrPayload`，按整数倍放大，插值设为 none。
    - 步骤说明"手机打开 开发者选项 → 无线调试 → 使用二维码配对设备"。
    - 状态文字：等待扫码… / 正在配对… / 正在连接… / 已连接 <serial> / 失败原因。
    - 「手动输入配对码」表单，包含"IP 地址和端口"和"配对码"两个带 label 的输入框。
  - **右栏**："一键转无线"，列出 USB 连接中的设备，每台设备一个「转为无线」按钮。

- [ ] **Step 1: 写 fixture**：
  - `mdns-services.txt`：
    `List of discovered mdns services`
    `adb-R5CT1234567-AbCdEf\t_adb-tls-connect._tcp.\t192.168.1.23:41235`
    `studio-K8x2pQaB1c\t_adb-tls-pairing._tcp\t192.168.1.23:37099`
  - `ip-addr-wlan0.txt`：
    `30: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 3000`
    `    inet 192.168.1.23/24 brd 192.168.1.255 scope global wlan0`
- [ ] **Step 2: 写失败测试**
  ```swift
  @Test func parsesMdnsWithTrailingDot() { let s = MdnsParser.parse(fixture); #expect(s.count == 2); #expect(s[0] == MdnsService(instance: "adb-R5CT1234567-AbCdEf", kind: .connect, host: "192.168.1.23", port: 41235)) }
  @Test func qrPayloadFormat() { let c = PairingCredentials(name: "studio-abc", password: "123456"); #expect(c.qrPayload == "WIFI:T:ADB;S:studio-abc;P:123456;;") }
  @Test func generatedCredentialsShape() { /* 使用种子固定的 RNG：name 匹配 ^studio-[A-Za-z0-9]{10}$，password 匹配 ^[0-9]{12}$ */ }
  @Test func parsesWlanIP() { #expect(WirelessConnector.parseWlanIPv4(fixture) == "192.168.1.23"); #expect(WirelessConnector.parseWlanIPv4("") == nil) }
  @Test func qrFlowPairsThenConnects() async throws { /* Fake：第 1 次 mdns 只有 connect，第 2 次出现 pairing；pair → "Successfully paired to 192.168.1.23:37099"；connect → "connected to 192.168.1.23:41235" → 返回 "192.168.1.23:41235"；progress 依次为 waitingForScan、pairing、connecting、connected */ }
  @Test func pairFailureSurfacesAdbOutput() async { /* pair 返回 "Failed: Wrong password or connection was dropped." → DeviceError.code == .CONNECTION_FAILED，message 包含该输出 */ }
  @Test func switchToWirelessRunsTcpipThenConnect() async throws { /* 断言调用顺序依次为 shell ip…、tcpip 5555、connect 192.168.1.23:5555 */ }
  ```
  测试中 `pollInterval` 设为 `.milliseconds(1)`。
- [ ] **Step 3: 实现**，跑 `--filter WirelessTests` → PASS；跑 App 构建命令，退出码 0
- [ ] **Step 4: Commit** `feat(android): wireless pairing via QR code, pairing code and tcpip`

---

### Task 12: 真机集成测试与手动验收

**Files:**
- Create: `Tests/AndroidDriverTests/AndroidIntegrationTests.swift`, `docs/superpowers/qa/p1-manual-checklist.md`

**Interfaces:**
- Consumes: `AdbLocator`、`AndroidDriver`、`AndroidSession`

- [ ] **Step 1: 写集成测试**：只有设置环境变量 `TANDEM_TEST_SERIAL` 时才运行，通过 `@Suite(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_TEST_SERIAL"] != nil))` 控制。scrcpy-server 路径取环境变量 `TANDEM_SCRCPY_SERVER`，默认 `App/Resources/Vendor/scrcpy-server-v5.0.1`。
  ```swift
  @Test func endToEnd() async throws {
    // locate adb → 构造 AndroidSession → start
    // 10 秒内收到 .running；5 秒内 latestFrame() != nil
    try await session.setClipboard("tandem-测试", paste: false); #expect(try await session.getClipboard() == "tandem-测试")
    await session.send(.key(.home))   // 不抛错
    await session.stop()              // 之后 adb forward --list 不再包含该端口
  }
  ```
  Run: `TANDEM_TEST_SERIAL=<serial> swift test --package-path Packages/TandemCore --filter AndroidIntegrationTests` → PASS；未连接设备时，该 suite 显示为 skipped
- [ ] **Step 2: 写手动验收清单** `p1-manual-checklist.md`，每一项都标注预期结果：
  - USB 插入后菜单出现设备；
  - 打开窗口，1 秒内出现画面；
  - 点击、拖动、滚轮、右键返回、Esc、⌘H、⌘S、⌘↑、⌘↓、⌘P；
  - 用 Mac 中文输入法输入"你好世界"，手机上出现该文字；
  - ⌘V 粘贴 Mac 剪切板文本；
  - 旋转手机，窗口比例随之改变；
  - 拔线后显示"已断开"，插回后自动恢复；
  - 两台设备同时开窗口，互不干扰；
  - 扫码配对成功，Wi-Fi 设备可以投屏；
  - 对 USB 设备"一键转无线"后拔线，仍能继续操控；
  - 同一台手机同时 USB + Wi-Fi 时，菜单只显示一台；
  - 小米设备未开安全设置时，出现横幅；打开开关后点"已打开，重新连接"，可以正常点击；
  - 删除 Vendor 后构建，报"请先运行 scripts/fetch-vendor.sh"；
  - 系统中没有可用 adb 时，使用内置 adb。
- [ ] **Step 3: 在真机上执行清单**，逐项记录通过或未通过；没有对应设备的项（如小米）标注"未验证"
- [ ] **Step 4: Commit** `test: add device integration test and P1 manual checklist`
