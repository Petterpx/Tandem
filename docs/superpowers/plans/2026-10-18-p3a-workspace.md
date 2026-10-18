# P3a 工作台 + 截图录屏 + 剪贴板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Tandem 的主界面换成工作台窗口（设备列表 / 投屏 / 右栏 / 底部），并加入截图、固定画布录屏、提示条、最近截图、操作记录与剪贴板标签。

**Architecture:** 核心包新增按设备提供的 `DeviceActions`（不依赖投屏会话的操作，P3a 只有截图）、会话帧多订阅与剪贴板推送，以及与平台无关的 `MediaKit`（固定画布录屏器）。App 层的 `AppModel` 改用 `MirrorSet`（选中过就保持 + 弹出）决定哪些会话运行；`DeviceCommands` 是所有面板操作的唯一入口，经 `ActionRunner` 执行并写 `ActivityLog`，结果交给 `CaptureStore` / `ToastCenter` / `ClipboardService`。

**Tech Stack:** Swift 6（严格并发）、SwiftUI + AppKit、AVFoundation（AVAssetWriter）、VideoToolbox、CoreImage、Swift Testing、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-10-18-p3a-workspace-design.md`（总设计：`docs/superpowers/specs/2026-10-17-tandem-design.md`）

## Global Constraints

- 最低系统 macOS 14；`SWIFT_VERSION: "6.0"`、严格并发；不引入第三方依赖。
- 测试一律用 Swift Testing（`import Testing`、`@Test`、`#expect`）。
- 新增或删除 App / AppTests 下的文件后先运行 `xcodegen generate`；`*.xcodeproj` 不提交。
- 包测试：`cd Packages/TandemCore && swift test`；App 测试：`xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS'`。
- adb 调用一律使用 `DeviceInfo.serial`（当前传输）；窗口、会话、记录、设置一律按逻辑 id `DeviceInfo.id` 索引。
- 所有面板操作经 `DeviceCommands` → `ActionRunner`，不在视图里直接调用会话或 adb。
- 颜色只从 `Theme` 取，视图里不写颜色字面量；主色 `#2F6FED`，浅色为主，深色跟随系统。
- 注释用中文，密度与现有代码一致；提交信息用英文 conventional commits，不加署名行。
- 文案与路径照抄 spec：截图 `~/Pictures/Tandem/`、录屏 `~/Movies/Tandem/`；文件名 `<设备名>_yyyyMMdd_HHmmss.<ext>`；提示条 8 秒；最近截图 50 项；操作记录 500 条；剪贴板历史 10 条；Mac 剪贴板轮询 0.5 秒；录屏 8 Mbps。
- 工作分支：`feat/p3a-workspace`。

## Review Focus

1. **录屏中切换到别的设备或关掉投屏视图**：录屏必须继续，因为录屏有自己的帧订阅。由 Task 8 的 `recordingSurvivesViewObserverRemoval` 固定。
2. **保存目录不可写**（被删除、被替换成文件、没有权限）：截图或录屏要报清楚的错误并给出建议，不能崩溃，也不能悄悄丢掉。由 Task 5 的 `unwritableDirectoryThrowsReadableError` 固定。
3. **录屏中退出 App**：在 4 秒期限内把文件写完整。由 Task 8 的 `stopAllFinalizesEveryRecording` 固定。
4. **焦点在投屏画面上时按 ⌘⇧S / ⌘⇧R**：只能触发截图或录屏，不能当作按键发给手机。由 Task 12 的 `captureShortcutsAreNotDeviceCommands` 固定。
5. **两台设备都开启自动同步**：设备 A 推到 Mac 的内容不能回推给 A，也不能来回弹跳。由 Task 9 的 `ownMacWriteIsNotPushedToAnyDevice` 固定。

---

### Task 1: 帧多订阅与时间戳

**Files:**
- Modify: `Packages/TandemCore/Sources/DeviceCore/DeviceSession.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/AndroidSession.swift`（`FrameState.handler` → 订阅表；`setFrameHandler` 删除）
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Scrcpy/H264Decoder.swift`（输出回调带上 presentationTimeStamp）
- Modify: `Packages/TandemCore/Tests/DeviceCoreTests/Fakes.swift`
- Modify: `App/DeviceWindow/DeviceWindowView.swift`（`VideoSurface` 在 make 时订阅、`dismantleNSView` 时退订）
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidSessionTests.swift`、`H264DecoderTests.swift`

**Interfaces:**
- Produces:
  - `VideoFrame.init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime = .invalid)`，`VideoFrame.presentationTime: CMTime`
  - `public struct FrameObserverToken: Hashable, Sendable`
  - `DeviceSession.addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken`
  - `DeviceSession.removeFrameObserver(_ token: FrameObserverToken)`
  - `setFrameHandler` 从协议与实现中移除

- [ ] **Step 1: 写失败测试**（AndroidSessionTests，沿用文件里已有的 harness 与送帧方式；原 `setFrameHandler` 测试改用新 API）

```swift
@Test func everyObserverReceivesFrames() async throws {
    // 两个订阅者都收到同一帧；退订后的不再收到
    let a = Box<[VideoFrame]>([]), b = Box<[VideoFrame]>([])
    let ta = h.session.addFrameObserver { a.append($0) }
    _ = h.session.addFrameObserver { b.append($0) }
    deliverFrame()                      // 现有测试里的送帧辅助
    #expect(a.count == 1 && b.count == 1)
    h.session.removeFrameObserver(ta)
    deliverFrame()
    #expect(a.count == 1 && b.count == 2)
}
```

H264DecoderTests 增加 `framesCarryPresentationTime`：以 pts `0, 16_666, 33_333`（微秒）送入夹具帧，收到帧的 `presentationTime.seconds` 依次约等于 `0, 0.016666, 0.033333`（误差 1e-6）。

- [ ] **Step 2: 运行确认失败**：`cd Packages/TandemCore && swift test --filter 'AndroidSessionTests|H264DecoderTests'`，预期编译失败（`addFrameObserver` 不存在）。
- [ ] **Step 3: 实现**：`FrameState` 用 `[Int: @Sendable (VideoFrame) -> Void]` 加自增计数；`deliver` 在锁内取出订阅者快照，在锁外逐个回调。解码回调用 `VTDecompressionSessionDecodeFrame` 输出闭包的第 4 个参数（presentationTimeStamp）构造 `VideoFrame`。`VideoSurface` 用 Coordinator 保存 token，在 `static func dismantleNSView(_:coordinator:)` 里退订。
- [ ] **Step 4: 运行包测试与 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(core): fan out session frames to multiple observers with timestamps`

### Task 2: 剪贴板主动推送

**Files:**
- Modify: `Packages/TandemCore/Sources/DeviceCore/DeviceSession.swift`（`SessionEvent.clipboardChanged(String)`）
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Scrcpy/ScrcpyServer.swift`（`clipboard_autosync=true`）
- Modify: `Packages/TandemCore/Sources/AndroidDriver/AndroidSession.swift`（`handle(_:runID:)`）
- Test: `ScrcpyServerTests.swift`、`AndroidSessionTests.swift`

**Interfaces:**
- Produces: `SessionEvent.clipboardChanged(String)`：设备推来的剪贴板消息在没有等待中的 `getClipboard()` 时发出。

- [ ] **Step 1: 写失败测试**
  - `serverCommandIsExact`：期望列表最后一项改为 `"clipboard_autosync=true"`。
  - `unsolicitedClipboardBecomesEvent`：会话 running 后，控制流写入一条 clipboard 消息（type 0，内容 `"hi"`），事件流收到 `.clipboardChanged("hi")`。
  - `clipboardReplyResolvesPendingReadWithoutEvent`：先调用 `getClipboard()`，再写入 clipboard 消息 `"x"`；`getClipboard()` 返回 `"x"`，且之后 100ms 内事件流没有 `.clipboardChanged`。
- [ ] **Step 2: 运行确认失败**：`swift test --filter 'ScrcpyServerTests|AndroidSessionTests'`。
- [ ] **Step 3: 实现**：`.clipboard(text)` 分支：`clipboardWaiters` 非空时按原逻辑全部唤醒；为空时 `continuation.yield(.clipboardChanged(text))`。
- [ ] **Step 4: 运行包测试**，全部通过。App 侧的 `switch event` 补 `case .clipboardChanged: break`（Task 10 再接入），保证编译通过。
- [ ] **Step 5: 提交** `feat(core): emit device clipboard pushes as session events`

### Task 3: DeviceActions 与截图

**Files:**
- Create: `Packages/TandemCore/Sources/DeviceCore/DeviceActions.swift`
- Modify: `Packages/TandemCore/Sources/DeviceCore/Capability.swift`、`DeviceDriver.swift`、`DeviceManager.swift`
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Adb/AdbClient.swift`、`Adb/AndroidDriver.swift`（能力集合加 `.screenshot, .record`；实现 `makeActions`）
- Modify: `Packages/TandemCore/Tests/DeviceCoreTests/Fakes.swift`
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidActionsTests.swift`、`DeviceCoreTests/DeviceManagerTests.swift`、`AndroidIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `public protocol DeviceActions: Sendable { func screenshot() async throws -> Data }`：返回 PNG，设备原分辨率
  - `Capability` 新增 `screenshot`、`record`
  - `DeviceDriver.makeActions(for device: DeviceInfo) -> any DeviceActions`
  - `DeviceManager.actions(for id: String) -> (any DeviceActions)?`：每次按合并列表里该 id 当前的 `DeviceInfo` 新建，所以 USB / Wi-Fi 切换后使用新的 serial；id 不在列表或不是 connected 时返回 nil
  - `AdbClient.execOut(_ serial: String, _ args: [String], timeout: Duration = .seconds(15)) async throws -> Data`：运行 `adb -s <serial> exec-out <args…>`，非 0 退出码按 `checked` 抛错

- [ ] **Step 1: 写失败测试**

```swift
@Test func screenshotRunsScreencapOnCurrentSerial() async throws {
    let runner = FakeProcessRunner()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])
    runner.stubData(adbPath, ["-s", "192.168.1.5:5555", "exec-out", "screencap", "-p"], stdout: png)
    let actions = AndroidActions(serial: "192.168.1.5:5555", adb: client(runner))
    #expect(try await actions.screenshot() == png)
}
@Test func screenshotRejectsNonPNG() async {
    // stdout "error: closed" 且退出码 0 → 抛 DeviceError，message 含 "截图数据无效"
}
@Test func screenshotFailureSurfacesAdbError() async {
    // 退出码 1、stderr "device offline" → 抛 DeviceError.connectionFailed("device offline")
}
```

DeviceManagerTests 增加 `actionsUseCurrentDeviceInfo`：FakeDriver 先推送 USB serial `A`，再推送同一硬件序列号的 Wi-Fi serial `ip:5555`（USB 下线）；`actions(for:)` 返回的 FakeActions 记录的 serial 依次为 `A`、`ip:5555`。离线设备返回 nil。

AndroidIntegrationTests 增加 `screenshotIsDeviceResolutionPNG`：`screenshot()` 以 PNG 签名开头，`CGImageSource` 读出的尺寸与 `adb shell wm size` 的 Physical size 相同（允许宽高互换，因为可能是横屏）。
- [ ] **Step 2: 运行确认失败**：`swift test --filter 'AndroidActionsTests|DeviceManagerTests'`。
- [ ] **Step 3: 实现**：在 `FakeProcessRunner` 中加 `stubData(_:_:stdout: Data)`。PNG 签名为 `89 50 4E 47 0D 0A 1A 0A`，签名不符时抛 `DeviceError(code: .CONNECTION_FAILED, message: "截图数据无效", suggestion: "请确认设备已解锁后重试")`。
- [ ] **Step 4: 运行包测试**，全部通过。连着真机时再跑 `TANDEM_TEST_SERIAL=<serial> swift test --filter AndroidIntegrationTests`，也应通过。
- [ ] **Step 5: 提交** `feat(core): DeviceActions with lossless screenshot`

### Task 4: MediaKit 固定画布录屏器

**Files:**
- Modify: `Packages/TandemCore/Package.swift`：新增 product 与 target `MediaKit`（依赖 `DeviceCore`）、测试 target `MediaKitTests`；`AndroidDriverTests` 加依赖 `MediaKit`
- Create: `Packages/TandemCore/Sources/MediaKit/CanvasLayout.swift`、`CanvasRecorder.swift`
- Modify: `project.yml`：App target 依赖 `TandemCore` 的 product `MediaKit`
- Test: `Packages/TandemCore/Tests/MediaKitTests/CanvasLayoutTests.swift`、`CanvasRecorderTests.swift`；`AndroidIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `public enum CanvasLayout`
    - `static func canvasSize(for first: CGSize) -> CGSize`：宽、高各自向下取偶数
    - `static func fit(_ content: CGSize, in canvas: CGSize) -> CGRect`：等比缩放后居中，原点左下（与 CoreImage 一致）
  - `public struct RecordingSummary: Sendable, Equatable { url: URL; duration: Double; canvasSize: CGSize; fileSize: Int64; thumbnailPNG: Data? }`
  - `public enum RecordingError: Error, Equatable { case noFrames; case writerFailed(String) }`
  - `public final class CanvasRecorder: @unchecked Sendable`
    - `init(url: URL, bitRate: Int = 8_000_000)`
    - `func append(_ frame: VideoFrame)`：线程安全，可从解码线程调用
    - `func finish() async throws -> RecordingSummary`

- [ ] **Step 1: 写失败测试**

```swift
@Test func landscapeContentInPortraitCanvasIsCenteredAndScaled() {
    let r = CanvasLayout.fit(CGSize(width: 1920, height: 908), in: CGSize(width: 908, height: 1920))
    #expect(r.width == 908)
    #expect(abs(r.height - 908 * 908 / 1920) < 0.5)
    #expect(abs(r.midY - 960) < 0.5 && r.minX == 0)
}
@Test func sameSizeFillsCanvas() {
    #expect(CanvasLayout.fit(CGSize(width: 908, height: 1920), in: CGSize(width: 908, height: 1920))
            == CGRect(x: 0, y: 0, width: 908, height: 1920))
}
@Test func canvasSizeIsEven() {
    #expect(CanvasLayout.canvasSize(for: CGSize(width: 909, height: 1921)) == CGSize(width: 908, height: 1920))
}
@Test func recordsAcrossRotationIntoFirstFrameCanvas() async throws {
    // 30 帧 64×48 纯色 BGRA（pts 0…29/30 s），再 30 帧 48×64（pts 1…59/30 s）
    let summary = try await recorder.finish()
    let asset = AVURLAsset(url: summary.url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 48))
    #expect(abs(try await asset.load(.duration).seconds - 2.0) < 0.1)
    #expect(summary.canvasSize == CGSize(width: 64, height: 48) && summary.fileSize > 0 && summary.thumbnailPNG != nil)
}
@Test func finishWithoutFramesThrowsAndLeavesNoFile() async {
    await #expect(throws: RecordingError.noFrames) { try await recorder.finish() }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
@Test func framesWithoutTimestampUseArrivalTime() async throws {
    // 3 帧 presentationTime = .invalid，相隔 50ms 送入 → 时长 > 0
}
```

AndroidIntegrationTests 增加 `recordsTwoSecondsFromSession`：会话 running 后，用 `addFrameObserver` 把帧送进 `CanvasRecorder` 录 2 秒，再 `finish()`。用 AVURLAsset 读文件，时长在 1.5…2.5 秒之间。
- [ ] **Step 2: 运行确认失败**：`swift test --filter MediaKitTests`。
- [ ] **Step 3: 实现**：
  - 第一次 `append` 时创建 `AVAssetWriter`（`.mp4`），输入为 `AVVideoCodecType.h264`，宽高取 `canvasSize`，`AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate]`；配一个 BGRA 的 `AVAssetWriterInputPixelBufferAdaptor`。
  - 帧时间：取 `presentationTime - 首帧 presentationTime`；时间戳无效时改用 `CACurrentMediaTime()` 相对首帧的差值。时间不递增的帧丢弃；`isReadyForMoreMediaData` 为 false 时也丢弃。
  - 帧尺寸与画布相同时直接写入原 pixel buffer；不同时从 adaptor 的缓冲池取一块，先用 `CIContext` 填黑，再把 `CIImage` 缩放、平移到 `fit` 的矩形里渲染进去。
  - 所有写入都在一个内部串行 `DispatchQueue` 上进行。缩略图从首帧编码成 PNG。
  - `finish` 时如果一帧都没写过，取消 writer、删除文件，然后抛 `noFrames`。
- [ ] **Step 4: 运行包测试**，全部通过。
- [ ] **Step 5: 提交** `feat(media): fixed-canvas H.264 recorder`

### Task 5: Mac 剪贴板封装与截图文件存储

**Files:**
- Create: `App/Capture/MacPasteboard.swift`、`App/Capture/CaptureNaming.swift`、`App/Capture/CaptureStore.swift`
- Test: `AppTests/CaptureNamingTests.swift`、`AppTests/CaptureStoreTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class MacPasteboard`
    - `init(_ pasteboard: NSPasteboard = .general)`
    - `var changeCount: Int`、`func string() -> String?`
    - 写入：`func writeString(_ s: String)`、`func writeImage(png: Data, fileURL: URL)`（同时写入图片数据与文件 URL）、`func writeFileURL(_ url: URL)`
    - `func isOwnChange(_ changeCount: Int) -> Bool`：changeCount 是否来自 App 自己最近一次写入
  - `enum CaptureNaming { static func fileName(deviceName: String, date: Date, ext: String, timeZone: TimeZone = .current, isTaken: (String) -> Bool) -> String }`
  - `struct CaptureItem: Identifiable, Equatable`
    - 字段：`id: UUID`、`kind: Kind`（`enum Kind { case screenshot, recording }`）、`url: URL`、`deviceName: String`、`date: Date`、`duration: Double?`、`fileSize: Int64`、`thumbnailPNG: Data?`
  - `enum CaptureError: LocalizedError { case cannotWrite(URL) }`
    - `errorDescription`：「无法写入 <路径>」
    - `recoverySuggestion`：「请在设置中更换保存目录」
  - `@MainActor @Observable final class CaptureStore`
    - `init(pasteboard: MacPasteboard, defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping () -> Date = Date.init)`
    - `static let recentLimit = 50`
    - 目录：`var screenshotDirectory: URL`（UserDefaults 键 `screenshotDirectory`，默认 `~/Pictures/Tandem`）、`var recordingDirectory: URL`（键 `recordingDirectory`，默认 `~/Movies/Tandem`）
    - `private(set) var recent: [CaptureItem]`：最新在前
    - `func saveScreenshot(_ png: Data, deviceName: String) throws -> CaptureItem`：写文件、加入 recent、调用 `writeImage`
    - `func nextRecordingURL(deviceName: String) throws -> URL`：建目录并返回不重名的 `.mp4` 路径
    - `func addRecording(_ summary: RecordingSummary, deviceName: String) -> CaptureItem`
    - `func copy(_ item: CaptureItem)`：写文件 URL
    - `func reveal(_ item: CaptureItem)`：调用 `NSWorkspace.shared.activateFileViewerSelecting`
    - `func fileExists(_ item: CaptureItem) -> Bool`、`func clear()`

- [ ] **Step 1: 写失败测试**

```swift
@Test func nameUsesDeviceAndTimestamp() {
    let date = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09 08:53:20 UTC
    #expect(CaptureNaming.fileName(deviceName: "SM-G9730", date: date, ext: "png", timeZone: .gmt, isTaken: { _ in false })
            == "SM-G9730_20251009_085320.png")
}
@Test func illegalCharactersAreReplaced() {
    #expect(CaptureNaming.fileName(deviceName: "a/b:c", date: date, ext: "png", timeZone: .gmt, isTaken: { _ in false })
            .hasPrefix("a_b_c_"))
}
@Test func sameSecondGetsSuffix() {
    let taken: Set = ["P_20251009_085320.png", "P_20251009_085320-2.png"]
    #expect(CaptureNaming.fileName(deviceName: "P", date: date, ext: "png", timeZone: .gmt, isTaken: taken.contains)
            == "P_20251009_085320-3.png")
}
@Test func saveScreenshotWritesFileRecentsAndPasteboard() throws {
    // home = 临时目录；pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    let item = try store.saveScreenshot(pngData, deviceName: "P")
    #expect(FileManager.default.contents(atPath: item.url.path) == pngData)
    #expect(item.url.deletingLastPathComponent().path.hasSuffix("Pictures/Tandem"))
    #expect(store.recent.first == item)
    #expect(pb.isOwnChange(pb.changeCount))
}
@Test func recentIsCappedAtFifty() { /* 存 51 张 → recent.count == 50，最早的一张被移除 */ }
@Test func unwritableDirectoryThrowsReadableError() {
    // screenshotDirectory 指向一个已存在的普通文件 → 抛 CaptureError.cannotWrite，errorDescription 以 "无法写入" 开头
}
@Test func deletedFileIsReported() { /* 保存后删掉文件 → fileExists(item) == false */ }
@Test func clearKeepsFiles() { /* clear() 后 recent 为空，文件仍在 */ }
```
- [ ] **Step 2: 运行确认失败**：先 `xcodegen generate`，再 `xcodebuild test … -only-testing:TandemTests/CaptureNamingTests -only-testing:TandemTests/CaptureStoreTests`。
- [ ] **Step 3: 实现**：
  - 时间格式用 `DateFormatter`，`locale` 设为 `en_US_POSIX`，格式 `yyyyMMdd_HHmmss`。
  - 文件名中把 `/` 和 `:` 替换为 `_`；替换后为空时用 `Device`。
  - 同名时从 `-2` 开始依次递增。
- [ ] **Step 4: 运行 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(app): capture storage, naming and pasteboard wrapper`

### Task 6: 操作记录、统一执行器、提示条状态

**Files:**
- Create: `App/Actions/ActivityLog.swift`、`App/Actions/ActionRunner.swift`、`App/Capture/ToastCenter.swift`
- Test: `AppTests/ActionRunnerTests.swift`、`AppTests/ToastCenterTests.swift`

**Interfaces:**
- Produces:
  - `enum ActivitySource: Equatable { case user, ai }`
  - `struct ActivityEntry: Identifiable, Equatable { id: UUID; date: Date; source: ActivitySource; deviceName: String; title: String; failure: String? }`
  - `@MainActor @Observable final class ActivityLog`
    - `static let limit = 500`
    - `private(set) var entries: [ActivityEntry]`：最新在前
    - `func append(_ e: ActivityEntry)`、`func clear()`
  - `struct PanelError: Equatable { deviceID: String; message: String; suggestion: String? }`
  - `@MainActor @Observable final class ActionRunner`
    - `init(log: ActivityLog, now: @escaping () -> Date = Date.init)`
    - `private(set) var lastError: PanelError?`
    - `@discardableResult func perform<T>(_ title: String, device: DeviceInfo, source: ActivitySource = .user, _ body: () async throws -> T) async -> T?`
    - `func note(_ title: String, device: DeviceInfo, source: ActivitySource = .user, failure: String? = nil)`：只写记录，不执行任何操作
    - `func dismissError()`
  - `enum ToastOrigin: Hashable { case workspace; case popup(String) }`
  - `struct CaptureToast: Identifiable, Equatable { id: UUID; item: CaptureItem; note: String? }`
  - `@MainActor @Observable final class ToastCenter`
    - `private(set) var current: [ToastOrigin: CaptureToast]`
    - `func show(_ item: CaptureItem, note: String?, in origin: ToastOrigin)`：同一位置的新提示直接替换旧提示
    - `func dismiss(_ id: UUID, in origin: ToastOrigin)`：只在该位置当前的提示仍是这个 id 时才移除

- [ ] **Step 1: 写失败测试**

```swift
@Test func successIsLoggedWithSource() async {
    let v = await runner.perform("截图", device: dev, source: .ai) { 42 }
    #expect(v == 42)
    #expect(log.entries.first?.title == "截图" && log.entries.first?.source == .ai && log.entries.first?.failure == nil)
}
@Test func deviceErrorIsLoggedAndShown() async {
    let v: Int? = await runner.perform("读取剪贴板", device: dev) { throw DeviceError.connectionFailed("会话未运行") }
    #expect(v == nil)
    #expect(log.entries.first?.failure == "连接失败：会话未运行")
    #expect(runner.lastError == PanelError(deviceID: dev.id, message: "连接失败：会话未运行", suggestion: "请确认设备已开启调试并与电脑处于同一网络"))
}
@Test func localizedErrorUsesDescriptionAndSuggestion() async { /* CaptureError.cannotWrite → message 以 "无法写入" 开头，suggestion == "请在设置中更换保存目录" */ }
@Test func logIsCappedAt500() { /* 追加 501 条 → 共 500 条，最新在前 */ }
@Test func newerToastReplacesOlderAndStaleDismissIsIgnored() { /* show A，show B，dismiss(A.id) → current[.workspace] 仍是 B */ }
```
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**：
  - 错误换成文案时：`DeviceError` 用 `message` 和 `suggestion`；`LocalizedError` 用 `errorDescription` 和 `recoverySuggestion`；其他错误用 `String(describing:)`。
  - `perform` 执行成功时清掉同一设备的 `lastError`。
- [ ] **Step 4: 运行 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(app): activity log, action runner and toast state`

### Task 7: 会话规则（MirrorSet）与 AppModel 重构

**Files:**
- Create: `App/MirrorSet.swift`
- Modify: `App/AppPolicy.swift`：参数 `openWindowIDs` 改名为 `wanted`，`shouldAutoRetry(windowOpen:)` 改为 `wanted: Bool`
- Modify: `App/AppModel.swift`
- Modify: `App/TandemApp.swift`：测试宿主下不调用 `model.start()`，判断条件为 `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`
- Test: `AppTests/MirrorSetTests.swift`、`AppTests/AppPolicyTests.swift`

**Interfaces:**
- Consumes：Task 3 的 `DeviceManager.actions(for:)`。
- Produces:
  - `struct MirrorSet: Equatable`
    - 状态：`private(set) var kept: Set<String>`、`private(set) var popped: Set<String>`、`private(set) var workspaceOpen: Bool`
    - `var wanted: Set<String>`：等于 `(workspaceOpen ? kept : []) ∪ popped`
    - 操作：`mutating func select(_ id: String)`、`stopMirroring(_ id: String)`、`remove(_ id: String)`、`popOut(_ id: String)`、`popupClosed(_ id: String)`、`setWorkspaceOpen(_ open: Bool)`
  - `AppModel` 新增：
    - 状态：`private(set) var mirrors: MirrorSet`、`var selectedID: String?`
    - 操作：`func select(_ id: String) async`、`func stopMirroring(_ id: String) async`、`func remove(_ id: String) async`、`func popOut(_ id: String)`、`func popupOpened(_ id: String) async`、`func popupClosed(_ id: String) async`、`func workspaceAppeared() async`、`func workspaceDisappeared() async`
    - 查询：`var sidebarDevices: [DeviceInfo]`（当前列表加上 `kept` 里已断开设备的 lastKnown 信息，后者 `state` 设为 `.offline`），`func actions(for id: String) async -> (any DeviceActions)?`
    - 回调钩子：`var requestOpenWorkspace: (() -> Void)?`、`var requestOpenPopup: ((String) -> Void)?`、`var onSessionEnded: ((String, SessionEndReason) -> Void)?`、`var onDeviceClipboard: ((String, String) -> Void)?`
    - `enum SessionEndReason: Equatable { case disconnected, stopped, quit }`
  - 移除：`openWindowIDs`、`windowOpened`、`windowClosed`、`requestOpenWindow`

- [ ] **Step 1: 写失败测试**（每条对应 spec §3 表中的一行）

```swift
@Test func firstSelectKeepsDevice() { var m = MirrorSet(); m.setWorkspaceOpen(true); m.select("a"); #expect(m.wanted == ["a"]) }
@Test func switchingKeepsPrevious() { /* select a, select b → wanted == [a, b] */ }
@Test func popOutAddsAndClosingKeepsIfKept() { /* select a; popOut a; popupClosed a → wanted == [a]；只弹出不保持的 b：popupClosed b 后 b 不在 wanted */ }
@Test func stopMirroringDropsUnlessPopped() { /* select a, stopMirroring a → [] ；select b, popOut b, stopMirroring b → [b] */ }
@Test func removeDropsEverywhere() { /* select a, popOut a, remove a → [] */ }
@Test func closingWorkspaceStopsOnlyNonPopped() { /* select a, select b, popOut b, setWorkspaceOpen(false) → [b]；再 setWorkspaceOpen(true) → [a, b] */ }
```

AppPolicyTests 中原有用例跟着参数改名，另新增 `retryBudgetResetsWhenDeviceComesBack`：`AppPolicy.shouldResetRetries(previous: .offline, current: .connected) == true`；`(.connected, .connected)` 返回 false；`previous` 为 nil（首次出现）也返回 true。
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**：
  - AppModel 每次修改 `mirrors` 后都比较新旧 `wanted`：新增的 id 调用 `ensureSession` 后 `start()`；移除的 id 先执行 `onSessionEnded?(id, .stopped)`，再 `stop()`。
  - 原来所有 `openWindowIDs.contains` 的判断改为 `mirrors.wanted.contains`。
  - `devicesUpdated` 里，设备由非 connected 变为 connected 时调用 `resetRetry`；重连 Task 内部在 `start()` 前再检查一次 `canRun(id)`。
  - 会话状态变为 `.disconnected` 或 `.failed` 时调用 `onSessionEnded?(id, .disconnected)`；收到 `.clipboardChanged(text)` 时调用 `onDeviceClipboard?(id, text)`。
  - `stopAll()` 开头调用 `onSessionEnded?(id, .quit)`。
  - `select`：设置 `selectedID` 并执行 `mirrors.select`。「插上自动显示」改为调用 `requestOpenWorkspace` 加 `select`。
- [ ] **Step 4: 运行 App 测试**，全部通过。`TandemApp` 暂时把 `requestOpenWindow` 的用法换成 `requestOpenPopup`，保证编译，界面在 Task 11 再改。
- [ ] **Step 5: 提交** `feat(app): keep-alive mirror set replaces window-driven sessions`

### Task 8: RecordingService

**Files:**
- Create: `App/Capture/RecordingService.swift`
- Create: `AppTests/Support/FakeDeviceSession.swift`（可手动推帧、推事件、可设定剪贴板结果的 DeviceSession 替身，Task 9、10 共用）
- Test: `AppTests/RecordingServiceTests.swift`

**Interfaces:**
- Consumes：Task 4 的 `CanvasRecorder`、`RecordingSummary`；Task 5 的 `CaptureStore.nextRecordingURL`、`addRecording`；Task 1 的 `addFrameObserver`、`removeFrameObserver`
- Produces:
  - `struct ActiveRecording: Equatable { startedAt: Date; origin: ToastOrigin; deviceName: String }`
  - `@MainActor @Observable final class RecordingService`
    - `init(store: CaptureStore, now: @escaping () -> Date = Date.init, makeRecorder: @escaping (URL) -> CanvasRecorder = { CanvasRecorder(url: $0) })`
    - `private(set) var active: [String: ActiveRecording]`
    - `func isRecording(_ id: String) -> Bool`
    - `func start(_ id: String, deviceName: String, session: any DeviceSession, origin: ToastOrigin) throws`：已经在录时抛 `DeviceError(code: .UNSUPPORTED, message: "该设备正在录屏")`
    - `func stop(_ id: String) async throws -> CaptureItem`：没在录时抛同类错误，`message` 为 "该设备未在录屏"
    - `func stopAll() async -> [String: Result<CaptureItem, any Error>]`

- [ ] **Step 1: 写失败测试**

```swift
@Test func recordsFramesIntoStore() async throws {
    try service.start("a", deviceName: "P", session: fake, origin: .workspace)
    fake.pushFrames(count: 30, size: CGSize(width: 64, height: 48), fps: 30)
    let item = try await service.stop("a")
    #expect(item.kind == .recording && item.duration != nil && FileManager.default.fileExists(atPath: item.url.path))
    #expect(item.url.deletingLastPathComponent().path.hasSuffix("Movies/Tandem"))
    #expect(store.recent.first == item && !service.isRecording("a"))
}
@Test func stopWithoutFramesReportsNoFrames() async { /* 抛 RecordingError.noFrames，store.recent 为空 */ }
@Test func recordingSurvivesViewObserverRemoval() async throws {
    // 另加一个"视图"订阅后再退订，录屏仍然收到后续帧 → duration ≈ 帧跨度
}
@Test func stopAllFinalizesEveryRecording() async { /* 两台设备都在录 → stopAll 返回两个 .success，active 为空 */ }
@Test func doubleStartThrows() { /* 第二次 start 抛错，原录制不受影响 */ }
```
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**：
  - `start` 时用 `store.nextRecordingURL` 生成路径，`addFrameObserver` 把帧交给录屏器，同时记下 token。
  - `stop` 时先退订，再 `finish()`，然后 `store.addRecording`。
- [ ] **Step 4: 运行 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(app): per-device recording service`

### Task 9: ClipboardService

**Files:**
- Create: `App/Clipboard/ClipboardService.swift`、`App/Clipboard/ClipboardSyncGuard.swift`
- Test: `AppTests/ClipboardServiceTests.swift`

**Interfaces:**
- Consumes：Task 5 的 `MacPasteboard`；Task 8 的 `FakeDeviceSession`（测试）
- Produces:
  - 类型：`enum ClipboardDirection: Equatable { case read, write, sync }`，`struct ClipboardRecord: Identifiable, Equatable { id: UUID; direction: ClipboardDirection; text: String; date: Date }`，`enum WriteSource: Equatable { case input(String), macClipboard(String), unavailable }`
  - `struct ClipboardSyncGuard`：按设备记住最后一次同步的内容
    - `mutating func shouldSendToMac(_ id: String, _ text: String) -> Bool`
    - `mutating func shouldSendToDevice(_ id: String, _ text: String) -> Bool`
  - `@MainActor @Observable final class ClipboardService`
    - `static let historyLimit = 10`
    - `init(pasteboard: MacPasteboard, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init)`
    - 状态：`private(set) var history: [String: [ClipboardRecord]]`、`private(set) var preview: [String: String]`
    - 同步开关：`func isSyncEnabled(_ id: String) -> Bool`、`func setSyncEnabled(_ id: String, _ on: Bool)`（UserDefaults 键 `clipboardSync.<id>`），`var syncEnabledIDs: Set<String>`
    - `static func writeSource(input: String, macText: String?) -> WriteSource`
    - `func read(_ id: String, session: any DeviceSession) async throws -> String`：更新预览、写入 Mac 剪贴板、记一条 `.read`
    - `func write(_ id: String, text: String, paste: Bool, session: any DeviceSession) async throws`：记一条 `.write`
    - `func deviceClipboardChanged(_ id: String, text: String)`：同步关闭时忽略
    - `func pollMac(sessions: [String: any DeviceSession]) async`：执行一次 Mac→设备的检查
    - `func runSyncLoop(sessions: @escaping @MainActor () -> [String: any DeviceSession]) async`：只要有设备开启同步，就每 0.5 秒调用一次 `pollMac`，直到任务被取消

- [ ] **Step 1: 写失败测试**

```swift
@Test func writeSourcePrefersInput() {
    #expect(ClipboardService.writeSource(input: "abc", macText: "m") == .input("abc"))
    #expect(ClipboardService.writeSource(input: "", macText: "m") == .macClipboard("m"))
    #expect(ClipboardService.writeSource(input: "", macText: nil) == .unavailable)
}
@Test func readUpdatesPreviewMacAndHistory() async throws { /* fake 返回 "hi" → preview["a"]=="hi"，pb.string()=="hi"，history 第一条为 .read */ }
@Test func historyCappedAtTen() async throws { /* 写 11 次 → 10 条 */ }
@Test func devicePushIgnoredWhenSyncOff() { /* deviceClipboardChanged → Mac 剪贴板不变，history 为空 */ }
@Test func devicePushGoesToMacWhenSyncOn() { /* 开启后 → pb.string()=="x"，history 第一条为 .sync */ }
@Test func macChangePushedToSyncedDevicesOnly() async { /* 外部写 pb → pollMac → 只有开启同步的 fake 收到 setClipboard(paste:false) */ }
@Test func ownMacWriteIsNotPushedToAnyDevice() async {
    // a、b 都开启同步；a 推来 "x" → 写入 Mac；pollMac → a、b 都没有收到 setClipboard
}
@Test func sameTextIsNotResent() async { /* 外部写 "y" 两次（changeCount 变了，内容相同）→ 设备只收到一次 */ }
@Test func syncSettingPersists() { /* 用同一个 defaults 新建 service → isSyncEnabled 仍为 true */ }
```

测试用 `NSPasteboard(name: .init(UUID().uuidString))`；"外部写入"直接调用这个 NSPasteboard 的 `setString`。
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**：
  - `pollMac` 只在 `changeCount` 变化、这次变化不是 App 自己写的、内容是文本时，才写给每台开启同步且 `shouldSendToDevice` 为真的设备。
  - 写入失败只记日志，不中断循环。
- [ ] **Step 4: 运行 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(app): clipboard history and optional two-way sync`

### Task 10: DeviceCommands（面板操作入口）

**Files:**
- Create: `App/Actions/DeviceCommands.swift`
- Test: `AppTests/DeviceCommandsTests.swift`

**Interfaces:**
- Consumes：Task 5–9 的全部服务；Task 7 的 `SessionEndReason`
- Produces：`@MainActor @Observable final class DeviceCommands`
  - 初始化：`init(runner: ActionRunner, store: CaptureStore, recording: RecordingService, clipboard: ClipboardService, toasts: ToastCenter, device: @escaping (String) -> DeviceInfo?, session: @escaping (String) -> (any DeviceSession)?, actions: @escaping (String) async -> (any DeviceActions)?)`
  - 截图与录屏：
    - `func screenshot(_ id: String, origin: ToastOrigin) async`：操作记录标题「截图」；成功后弹提示条，note 为「已复制到剪贴板」
    - `func toggleRecording(_ id: String, origin: ToastOrigin) async`：标题「开始录屏」/「结束录屏」；结束后弹提示条
    - `func sessionEnded(_ id: String, reason: SessionEndReason) async`：该设备正在录屏时自动结束
      - `.disconnected`：提示条 note「设备已断开，已保存已录制部分」，操作记录标题「录屏已自动结束（设备已断开）」
      - `.stopped`：note「已停止投屏，已保存已录制部分」，标题「录屏已自动结束（已停止投屏）」
      - `.quit`：不弹提示条，只写记录「录屏已自动结束（退出）」
    - `func stopAllRecordings() async`
  - 剪贴板：
    - `func readClipboard(_ id: String) async`：标题「读取剪贴板」
    - `func writeClipboard(_ id: String, input: String, paste: Bool) async`：标题「写入剪贴板」/「写入并粘贴」；内容来源由 `ClipboardService.writeSource` 决定，为 `.unavailable` 时什么都不做
    - `func setClipboardSync(_ id: String, _ on: Bool)`：用 `runner.note` 记「开启剪贴板自动同步」/「关闭剪贴板自动同步」
  - 能力判断：`func can(_ capability: Capability, _ id: String) -> Bool`

- [ ] **Step 1: 写失败测试**（用 FakeDeviceSession，另写一个 FakeActions 返回固定 PNG）

```swift
@Test func screenshotSavesLogsAndToasts() async { /* recent 增加 1 项；log 第一条标题为 "截图"；toasts.current[.workspace]?.note == "已复制到剪贴板" */ }
@Test func screenshotFailureShowsError() async { /* FakeActions 抛 DeviceError → runner.lastError 非空；recent 不变；没有提示条 */ }
@Test func toggleRecordingTwiceProducesRecording() async { /* 第一次开始录，推帧，第二次结束 → recent 第一项为 .recording，log 依次为 "开始录屏"、"结束录屏" */ }
@Test func disconnectAutoStopsWithNote() async { /* 录制中调用 sessionEnded(.disconnected) → 提示条 note == "设备已断开，已保存已录制部分"，log 含 "录屏已自动结束（设备已断开）" */ }
@Test func unavailableWriteDoesNothing() async { /* input 为空且 Mac 剪贴板不是文本 → fake 没收到 setClipboard，log 为空 */ }
```
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**：每个方法都通过 `runner.perform(标题, device:)` 执行；`device(id)` 为 nil 时直接返回。
- [ ] **Step 4: 运行 App 测试**，全部通过。
- [ ] **Step 5: 提交** `feat(app): DeviceCommands as the single entry for panel actions`

### Task 11: 工作台窗口外壳、弹出、菜单栏、设置

**Files:**
- Create: `App/Theme.swift`
- Create: `App/Workspace/WorkspaceView.swift`、`DeviceSidebar.swift`、`MirrorPane.swift`
- Create: `App/DeviceWindow/MirrorView.swift`：从 `DeviceWindowView` 抽出"视频 + 遮罩 + ROM 横幅 + 输入泵"，供工作台和弹出窗口共用
- Modify: `App/DeviceWindow/DeviceWindowView.swift`（改用 MirrorView）、`App/TandemApp.swift`、`App/AppDelegate.swift`、`App/MenuBar/DeviceMenuView.swift`、`App/Settings/SettingsView.swift`

**Interfaces:**
- Consumes：Task 7 的 AppModel 新 API；Task 10 的 `DeviceCommands`
- Produces：
  - `enum Theme`：静态颜色 `sidebar`、`panel`、`canvas`、`canvasDot`、`accent`（#2F6FED）、`textPrimary`、`textSecondary`、`separator`、`danger`。用 `NSColor(name:dynamicProvider:)` 提供浅色值并派生深色值。
  - 场景 id：`"workspace"`（`Window`，标题 "Tandem"）、`"device"`（弹出窗口，沿用 `WindowGroup(for: String.self)`）、`"pairing"`。
  - `FocusedValues.captureTarget: CaptureTarget?`，其中 `struct CaptureTarget: Equatable { deviceID: String; origin: ToastOrigin }`。

- [ ] **Step 1: 场景与生命周期**
  - `Window("Tandem", id: "workspace")` 放在 `body` 的第一个场景，启动时就会打开。
  - `WorkspaceView` 在 `.onAppear` / `.onDisappear` 时调用 `workspaceAppeared` / `workspaceDisappeared`。
  - `AppDelegate.applicationShouldHandleReopen` 在没有可见窗口时调用 `model.requestOpenWorkspace`。
  - `DeviceWindowHost` 在 `.task` 中调用 `popupOpened`，在 `.onDisappear` 中调用 `popupClosed`。
  - `requestOpenPopup` 绑定到 `openWindow(id: "device", value:)`。
  - 「收回」按钮调用 `dismissWindow(id: "device", value: id)`。
  - 在 `MenuBarLabel` 的 `.task` 里创建 `DeviceCommands`，并把 `onSessionEnded` / `onDeviceClipboard` 接到它上面；同时启动 `clipboard.runSyncLoop`。
- [ ] **Step 2: 工作台布局**（spec §2.1）
  - 三栏用 `HSplitView`：左栏约 220pt，`Theme.sidebar`；中间是 `Theme.canvas` 加点阵；右栏约 300pt，`Theme.panel`。底部区域高约 150pt。
  - 左栏的设备行：名称、USB / Wi-Fi、状态点；正在录屏时显示红点。右键菜单：「弹出为独立窗口」「停止投屏」「移除」（只对 `state != .connected` 的设备可用）。底部放「无线配对…」和 `SettingsLink`「设置」。
  - 中间投屏区按设备 id 显示 `MirrorView` 并加 `.id(deviceID)`，确保切换设备时重建视频视图与帧订阅。设备已弹出时显示「已在独立窗口中显示」和「收回」；没有选中设备时显示「从左侧选择一台设备」。
  - 投屏区上方：设备名、`Android · 宽×高 · USB/Wi-Fi`、状态徽标、「弹出为独立窗口」按钮。
  - 投屏区下方：返回 / 主页 / 多任务按钮；截图 / 录屏按钮先占位，Task 12 再接入。
- [ ] **Step 3: 菜单栏与设置**
  - 菜单栏新增「打开工作台」。点设备改为 `requestOpenWorkspace` 加 `select`。
  - 设置中开关文案改为「插上设备时自动显示」，沿用原来的 `autoOpenOnConnect` 键。
  - 设置新增「截图目录」「录屏目录」两行，显示当前路径并带「选择…」按钮（`NSOpenPanel`，`canChooseDirectories = true`），写回 `CaptureStore`。
- [ ] **Step 4: 构建并运行全部测试**：`xcodegen generate && xcodebuild test …`，全部通过。手动启动 App 检查：启动后出现工作台；选中设备开始投屏；弹出与收回正常；关闭工作台后再从菜单栏打开，之前保持的设备恢复投屏。
- [ ] **Step 5: 提交** `feat(app): workspace window shell with pop-out devices`

### Task 12: 截图录屏界面、快捷键、提示条、最近截图、操作记录

**Files:**
- Create: `App/Workspace/CaptureToastView.swift`、`RecentCapturesStrip.swift`、`ActivityLogView.swift`
- Modify: `App/Workspace/MirrorPane.swift`、`App/DeviceWindow/DeviceWindowView.swift`（弹出窗口底栏加截图 / 录屏按钮）、`App/TandemApp.swift`（菜单命令）
- Test: `AppTests/KeyMappingTests.swift`

**Interfaces:**
- Consumes：Task 10 的 `DeviceCommands`；Task 6 的 `ToastCenter`、`ActivityLog`；Task 5 的 `CaptureStore`；Task 11 的 `FocusedValues.captureTarget`

- [ ] **Step 1: 写失败测试**（`KeyMappingTests`）

```swift
@Test func captureShortcutsAreNotDeviceCommands() {
    #expect(KeyMapping.command(keyCode: 1 /* S */, modifiers: [.command, .shift]) == nil)
    #expect(KeyMapping.command(keyCode: 15 /* R */, modifiers: [.command, .shift]) == nil)
}
```
- [ ] **Step 2: 运行**。如果直接通过，就把它作为回归测试保留；如果失败，修改 `KeyMapping`，让带 Shift 的这两个组合不被当作设备命令。
- [ ] **Step 3: 按钮与快捷键**
  - 投屏区和弹出窗口底栏都加「截图」「录屏」按钮。录屏中按钮变红，并显示 `mm:ss` 时长（`TimelineView(.periodic(from:by: 1))`）。
  - 会话不在 running 时录屏按钮禁用，`.help("投屏未运行，无法录屏")`；设备不具备相应能力时按钮也禁用。
  - 新增 `CommandMenu("设备")`：「截图」⌘⇧S、「开始/结束录屏」⌘⇧R，作用于 `@FocusedValue(\.captureTarget)`。工作台用 `.focusedSceneValue` 提供当前选中设备和 `.workspace`；弹出窗口提供自己的 id 和 `.popup(id)`。
- [ ] **Step 4: 提示条**（`CaptureToastView`）
  - 显示位置：窗口底部，读取 `toasts.current[origin]`。
  - 截图提示条：缩略图、"已复制到剪贴板"、「在 Finder 中显示」。
  - 录屏提示条：缩略图、时长、大小、文件名、「拷贝」、「在 Finder 中显示」。有 note 时显示在第一行。
  - 停留时间：`.task(id: toast.id)` 等待 8 秒后，若鼠标没有悬停（`onHover`）就 `dismiss`；悬停中则等鼠标移开后重新计时 8 秒。
- [ ] **Step 5: 底部两栏**
  - **最近截图**（`RecentCapturesStrip`）：
    - 横向滚动的缩略图，最新在左。
    - 悬停时出现「拷贝」「在 Finder 中显示」。
    - `.onDrag { NSItemProvider(contentsOf: item.url)! }`，可以把文件拖到别的 App。
    - `fileExists == false` 时显示"文件已删除"，按钮禁用。
    - 标题栏右侧有「清空」。
  - **操作记录**（`ActivityLogView`）：
    - 每行显示时间 `HH:mm:ss`、来源标签「你」/「AI」、设备名、标题。失败的行用 `Theme.danger`，并显示失败原因。
    - 标题栏右侧有「清空」。
  - **错误提示**：`runner.lastError` 显示在右栏顶部，可以关闭，内容包括错误信息和建议。
- [ ] **Step 6: 构建并运行全部测试**，全部通过。手动检查：
  - ⌘⇧S 截图后出现提示条和缩略图，Mac 剪贴板里是图片；
  - ⌘⇧R 录 5 秒，期间旋转一次手机，结束后得到一个完整文件，旋转后画面位于黑底中间；
  - 拔线时自动保存，提示条显示原因。
- [ ] **Step 7: 提交** `feat(app): capture controls, toasts, recent captures and activity log`

### Task 13: 剪贴板标签、能力概览、验收清单

**Files:**
- Create: `App/Workspace/ClipboardTab.swift`、`App/Workspace/QuickActionsTab.swift`
- Modify: `App/Workspace/WorkspaceView.swift`（右栏 `TabView` 或分段控件：「快捷操作 / 剪贴板」）
- Modify: `Packages/TandemCore/Sources/DeviceCore/Capability.swift`（`CaseIterable`）
- Create: `docs/superpowers/qa/p3a-manual-checklist.md`

**Interfaces:**
- Consumes：Task 9 的 `ClipboardService`；Task 10 的 `DeviceCommands`

- [ ] **Step 1: 剪贴板标签**（spec §7，自上而下）
  1. **预览区**：`ScrollView` 里放可选择的文本。
  2. **按钮行**：「读取」「写入」「写入并粘贴」。
  3. **多行输入框**：「写入」「写入并粘贴」按钮的文案随 `writeSource` 变化，显示「（输入框）」或「（Mac 剪贴板）」；为 `.unavailable` 时两个按钮禁用，并 `.help("Mac 剪贴板中没有文本")`。Mac 剪贴板状态在标签出现时读取，此后每 0.5 秒刷新一次。
  4. **历史**：每行显示方向标签（读 / 写 / 同步）、`HH:mm:ss`、首行预览，带「再次写入」「复制到 Mac」。
  5. **开关**：「双向自动同步」，调用 `commands.setClipboardSync`。

  设备没有 `.clipboard` 能力时，整个标签置灰，显示「该设备不支持剪贴板」。
- [ ] **Step 2: 能力概览**：「快捷操作」标签列出 `Capability.allCases`，每项显示中文名和 ✓ / —。为此在 `Packages/TandemCore/Sources/DeviceCore/Capability.swift` 中让 `Capability` 遵循 `CaseIterable`。中文名：投屏、触控、按键、文本输入、剪贴板、截图、录屏。
- [ ] **Step 3: 写验收清单** `docs/superpowers/qa/p3a-manual-checklist.md`
  - 逐条照抄 spec §11 的人工验收清单，再加上 Task 11、12 里的手动检查项。
  - 每条包括步骤、预期结果、状态（初始为「待验证」）。
- [ ] **Step 4: 最终验证**：
  - `cd Packages/TandemCore && swift test`：全部通过；
  - 真机：`TANDEM_TEST_SERIAL=<serial> swift test --filter AndroidIntegrationTests` 通过；
  - `xcodegen generate && xcodebuild test …`：全部通过；
  - `adb forward --list` 没有残留的 `scrcpy_`。
- [ ] **Step 5: 提交** `feat(app): clipboard tab, capability overview and P3a QA checklist`
