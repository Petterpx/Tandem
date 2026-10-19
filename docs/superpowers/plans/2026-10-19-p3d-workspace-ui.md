# P3d 工作台界面对齐与截图提速 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 工作台截图改为默认取投屏最新帧（另有无损「高清截图」、防连点、编码与写盘移出主线程），并把工作台主窗口的视觉按 `Workspace.dc.html` 对齐。

**Architecture:**
- **截图**：
  - MediaKit 的 `ScreenshotEncoder` 增加原尺寸帧 → PNG、长边 256 缩略图、读 PNG 尺寸三个纯函数；
  - `CaptureStore.saveScreenshot` 改为 async，编码、建目录、命名、写盘、缩略图在一个 `Task.detached` 里完成；用「临时文件 + 硬链接」命名，并发保存也不会互相覆盖；
  - `DeviceCommands.screenshot(quality:)` 选来源（投屏帧 / screencap），按设备防连点，并拼出提示条副标题。
- **样式层**：
  - `Theme` 按 spec §3.1 改值、补 token；新建 `App/Style/`，放字号、尺寸常量与共用组件；
  - 工作台各区域改用这些组件；展示用视图拆成只收值类型的子视图，供 `ImageRenderer` 快照测试渲染。
- **投屏区**：`MirrorView` 增加 `.bezel` 外观（外框在 `VideoSurface` 之外，输入坐标仍按 `VideoSurfaceView` 自身 bounds 映射）、可关闭的内置进度栏和 ROM 横幅关闭回调；弹出窗口继续用 `.plain`，保持现状（P3e 再改）。

**Tech Stack:** Swift 6（严格并发）、SwiftUI（macOS 14：`Layout`、`onKeyPress`、`focusable`、`ImageRenderer`）、Swift Testing、XcodeGen、ImageIO / CoreImage。

**Spec:** `docs/superpowers/specs/2026-10-19-p3d-workspace-ui-design.md`（附录差异清单 `2026-10-19-p3d-ui-gap-inventory.md`；设计稿 `docs/superpowers/design/mockups/Workspace.dc.html`、`RomBanner.dc.html`；总设计 `2026-10-17-tandem-design.md`）

## Global Constraints

- **工程**：
  - 最低系统 macOS 14；`SWIFT_VERSION: "6.0"`，严格并发；
  - 不引入第三方依赖；测试用 Swift Testing。
- **依赖**：不改 `project.yml` 的 target 依赖。`MCPBridge`、`ControlProtocol` 必须保留为 Tandem App target 的依赖，App 包内的 `tandem-mcp` 运行时要从 `Contents/Frameworks` 加载它们。
- **文件登记**：
  - `project.yml` 中 Tandem target 以 `path: App` 收录整个目录，TandemTests 以 `path: AppTests` 收录整个目录；
  - 新建的 `App/Style/`、`AppTests/Snapshots/` 不用登记，但新增、删除、改名文件后都要运行 `xcodegen generate`；
  - `*.xcodeproj` 不提交。
- **测试命令**：
  - 包测试：`cd Packages/TandemCore && swift test`，可加 `--filter <Suite>`；
  - App 测试（下文写作「App 测试」）：`xcodegen generate && xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tandem-p3c-tests"`，可加 `-only-testing:TandemTests/<Suite>`；
  - 只能用这个 `-derivedDataPath`：用户的 Tandem 从默认 DerivedData 运行；`.build/xcode` 在 ~/Documents 下，每次运行都会弹出访问「文稿」的授权框。
  - 若 xcodebuild 报已删除或改名文件找不到、模块不一致，只删 `$HOME/Library/Developer/Xcode/DerivedData/Tandem-p3c-tests/Build/Intermediates.noindex` 后重试，不删整个 DerivedData。
- **安全**：
  - 不用 `open` 启动 App，不退出用户正在运行的 Tandem；
  - App 测试会另起一个 Tandem 测试宿主，本会话第一次执行前先告知用户；
  - 不需要真机，不碰 adb。
- **颜色**：只从 `Theme` 取；每个新颜色同时给浅色与深色值。
- **样式**：
  - 工作台主窗口的视图只用 `App/Style` 组件，包括 `WorkspaceView`、`DeviceSidebar`、`MirrorPane`、右栏四个标签、`QuickActions/*`、底部两栏、提示条、ROM 横幅、进度条、拖放遮罩；
  - 不再用 `.bordered` / `.borderless` / `.borderedProminent` / `.plain` 按钮样式，也不再用 `.switch` / `.checkbox` / `.segmented` / `.roundedBorder` 和 `List`；
  - 允许保留的系统控件：
    - `Menu`、`Picker(.menu)` 下拉；
    - 套 `TandemFieldStyle` 的 `TextField`；
    - `ProgressView` 小转圈；
    - `contextMenu`、`alert`、`confirmationDialog`、`sheet`、`SettingsLink`（套 `TandemButtonStyle`）；
    - 自定义命令「编辑」模式里可拖动排序的 `List`。
  - 不用 `.caption` / `.callout` / `.headline` / `.subheadline` 这类语义字号，一律用 `TextRole`（Task 3）。
- **范围**：
  - 弹出窗口、设置、配对、日志窗口、粘贴弹窗、文件页内容、菜单栏属于 P3e；
  - 这些地方只做保持编译和可用所需的最小改动，例如参数改名、`Theme.separator` → `Theme.border`。
- **快照测试**（spec §5）：
  - `ImageRenderer` 不渲染 AppKit 支撑的视图：`VideoSurface`（NSViewRepresentable）、`ScrollView`、`List`、`TextField`、`Menu`、系统样式的 `Button` / `Toggle`；
  - 快照只渲染这些容器里面的内容视图，`VideoSurface` 用 `Theme.videoBackground` 色块代替；
  - `.task`、`.onHover` 在渲染时不会运行，模型要在渲染前填好假数据；
  - 快照不比较像素，只断言图像尺寸；评审者对照任务里列出的设计稿区域与数值目视检查。
- **文案**：照抄 spec 与本计划。
- **风格**：注释用中文，密度与现有代码一致；提交信息用英文 conventional commits，不加署名行。
- **工作分支**：`feat/p3d-workspace-ui`。

## Review Focus

1. **连点「截图」或按住 ⌘⇧S 自动重复**：同一设备同时只截一次，其余调用直接忽略，不排队，也不重复保存。由 Task 2 的 `concurrentScreenshotsAreIgnored` 固定。
2. **两台同名设备在同一秒截图**：保存移出主线程后，命名检查不再天然串行，两张都要保存成功且互不覆盖，目录里不留临时文件。由 Task 1 的 `simultaneousSavesDoNotOverwrite` 固定。
3. **截图失败**（screencap 超时、保存目录不可写）：写一条失败记录，不出提示条，「截图」按钮不能一直转圈或保持禁用。由 Task 2 的 `failedScreenshotClearsInFlight` 固定。
4. **侧栏 ↑ / ↓ 的边界情况**：
   - 在首行或末行时不越界；
   - 未选中时，↓ 选第一台、↑ 选最后一台；
   - 选中的设备已不在列表里时，从第一台开始。
   由 Task 10 的 `adjacentSelection` 固定。
5. **「恢复默认网络」部分可执行或中途失败**：
   - 读不到的项和已是默认值的项跳过；
   - 第一步失败就停下；
   - 只写一条记录，最后重读真实状态。
   由 Task 6 的 `resetNetworkSteps`、`resetNetworkStopsAtFirstFailure` 固定。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `Packages/TandemCore/Sources/MediaKit/ScreenshotEncoder.swift`（改） | 新增 `encodeFramePNG`、`thumbnailPNG`、`pixelSize(ofPNG:)` |
| `App/Capture/CaptureStore.swift`（改） | `ScreenshotPayload`、`SavedScreenshot`、`PreparedScreenshot`；async 保存；临时文件 + 硬链接命名 |
| `App/Capture/ScreenshotTypes.swift`（新） | `ScreenshotQuality`、`ScreenshotSource`、`ScreenshotText` |
| `App/Actions/DeviceCommands.swift`（改） | 来源选择、按设备防连点、提示条副标题 |
| `App/Theme.swift`（改） | spec §3.1 的 token 与深色值；去掉 `separator`、`bannerBackground`、`bannerText` |
| `App/Style/Typography.swift`、`Metrics.swift`（新） | `TextRole` 字号表、圆角 / 高度 / 布局常量 |
| `App/Style/Buttons.swift`、`Switch.swift`、`Card.swift`、`SectionHeader.swift`、`Chip.swift`、`Field.swift`、`UnderlineTabs.swift`、`FlowLayout.swift`、`DotGrid.swift`、`PhoneBezel.swift`、`ToolbarPill.swift`、`ProgressTrack.swift`（新） | spec §3.3 的共用组件 |
| `App/Workspace/RightPanelHeader.swift`（新） | 右栏「设备控制」标题行 + 下划线标签 |
| `App/Workspace/WorkspaceText.swift`（新） | 窗口标题、设备头部元信息等纯文案函数 |
| `App/QuickActions/ApkDropZone.swift`（新） | 应用卡片下方的拖放 / 点击选择文件区 |
| `App/DeviceWindow/RomStepsSheet.swift`（新） | ROM 步骤 sheet |
| `App/Workspace/*`、`App/QuickActions/*`、`App/DeviceWindow/MirrorView.swift`、`RomBannerView.swift`、`DeviceWindowView.swift`、`App/Transfers/TransferProgressBar.swift`、`DropOverlay.swift`、`App/AppModel.swift`、`App/AppPolicy.swift`、`App/TandemApp.swift`（改） | 各区域改样式与新增行为 |
| `AppTests/Support/SnapshotRenderer.swift`、`ColorProbe.swift`、`QuickEnv.swift`（新） | 快照渲染、颜色解析、快捷操作测试环境 |
| `AppTests/Snapshots/*SnapshotTests.swift`（新） | 各区域快照画廊 |
| `docs/superpowers/qa/p3d-manual-checklist.md`（新） | 手动验收清单 |

---

### Task 1: 截图编码、缩略图与主线程外保存

**Files:**
- Modify: `Packages/TandemCore/Sources/MediaKit/ScreenshotEncoder.swift`
- Modify: `App/Capture/CaptureStore.swift`
- Modify: `App/Actions/DeviceCommands.swift:52-61`（只适配新签名，Task 2 再改写）
- Modify: `App/Workspace/RecentCapturesStrip.swift:4-37`（`CaptureThumbnail`）
- Test: `Packages/TandemCore/Tests/MediaKitTests/ScreenshotEncoderTests.swift`、`AppTests/CaptureStoreTests.swift`

**Interfaces:**
- Produces（MediaKit，`public`）：
  - `ScreenshotEncoder.encodeFramePNG(_ pixelBuffer: CVPixelBuffer) throws -> Output`：原尺寸，`mimeType == "image/png"`。
  - `ScreenshotEncoder.thumbnailPNG(_ png: Data, maxSide: Int = 256) -> Data?`：数据无效时返回 nil，不放大。
  - `ScreenshotEncoder.pixelSize(ofPNG png: Data) -> (width: Int, height: Int)?`
- Produces（App）：
  - `enum ScreenshotPayload: Sendable { case frame(VideoFrame), png(Data) }`
  - `struct SavedScreenshot: Equatable { let item: CaptureItem; let width: Int?; let height: Int? }`
  - `struct PreparedScreenshot: Sendable { let url: URL; let png: Data; let thumbnailPNG: Data?; let width: Int?; let height: Int? }`
  - `CaptureStore.init(pasteboard:defaults:home:now:onPrepare: @escaping @Sendable () -> Void = {})`：`onPrepare` 是测试探针，在 detached 任务里、准备开始前调用。
  - `CaptureStore.saveScreenshot(_ payload: ScreenshotPayload, deviceName: String) async throws -> SavedScreenshot`：替换同步版本。
  - `nonisolated static func prepareScreenshot(_ payload: ScreenshotPayload, in dir: URL, deviceName: String, date: Date) throws -> PreparedScreenshot`
  - `freshURL` 改为 `nonisolated static`，`nextRecordingURL` 照旧同步调用它。

- [ ] **Step 1: 写失败测试（MediaKit）**：在 `ScreenshotEncoderTests` 里把 `pngIsScaledDown` 中造 PNG 的代码提成 `private func png(width: Int, height: Int) throws -> Data`，然后新增：

```swift
@Test func framePNGKeepsNativeSize() throws {
    let out = try ScreenshotEncoder.encodeFramePNG(try solidBuffer(width: 64, height: 48))
    #expect(out.mimeType == "image/png" && out.width == 64 && out.height == 48)
    let (w, h) = try size(of: out.data)
    #expect(w == 64 && h == 48)
}
@Test func thumbnailFitsLongEdge() throws {
    let thumb = try #require(ScreenshotEncoder.thumbnailPNG(try png(width: 1080, height: 2400)))
    let (w, h) = try size(of: thumb)
    #expect(h == 256 && (115...116).contains(w))
}
@Test func thumbnailDoesNotUpscale() throws {
    let thumb = try #require(ScreenshotEncoder.thumbnailPNG(try png(width: 64, height: 48)))
    let (w, h) = try size(of: thumb)
    #expect(w == 64 && h == 48)
}
@Test func invalidDataHasNoThumbnailOrSize() {
    #expect(ScreenshotEncoder.thumbnailPNG(Data([1, 2, 3])) == nil)
    #expect(ScreenshotEncoder.pixelSize(ofPNG: Data([1, 2, 3])) == nil)
}
@Test func pixelSizeReadsHeader() throws {
    #expect(ScreenshotEncoder.pixelSize(ofPNG: try png(width: 1080, height: 2400)).map { [$0.width, $0.height] } == [1080, 2400])
}
```

- [ ] **Step 2: 运行确认失败**：`cd Packages/TandemCore && swift test --filter ScreenshotEncoderTests`，预期编译失败：`encodeFramePNG` 未定义。
- [ ] **Step 3: 实现 MediaKit 三个函数**：
  - `encodeFramePNG` 复用共享的 `context` 生成 CGImage，再用 `CGImageDestination` 按原尺寸写 PNG；
  - `thumbnailPNG` 用 `CGImageSourceCreateThumbnailAtIndex`，选项为 `kCGImageSourceCreateThumbnailFromImageAlways: true`、`kCGImageSourceCreateThumbnailWithTransform: true`、`kCGImageSourceThumbnailMaxPixelSize: maxSide`，结果再编码成 PNG；
  - `pixelSize` 读 `CGImageSourceCopyPropertiesAtIndex` 的 `kCGImagePropertyPixelWidth` / `kCGImagePropertyPixelHeight`。
- [ ] **Step 4: 包测试通过**：`swift test --filter ScreenshotEncoderTests`。
- [ ] **Step 5: 写失败测试（App）**：
  - 改写 `CaptureStoreTests`（文件头加 `import os`）：
    - 每处 `store.saveScreenshot(png, deviceName: "P")` 改为 `try await store.saveScreenshot(.png(png), deviceName: "P").item`，对应测试改为 `async throws`；
    - `makeStore` 增加参数 `now: (() -> Date)? = nil` 与 `onPrepare: @escaping @Sendable () -> Void = {}`。
  - 新增：

```swift
@Test func framePayloadIsSavedAtNativeSizeWithThumbnail() async throws {
    let (store, _, _) = makeStore()
    let saved = try await store.saveScreenshot(.frame(FakeDeviceSession.makeFrame(size: CGSize(width: 64, height: 48), pts: .zero)), deviceName: "P")
    #expect(saved.width == 64 && saved.height == 48)
    let file = try #require(FileManager.default.contents(atPath: saved.item.url.path))
    #expect(ScreenshotEncoder.pixelSize(ofPNG: file).map { [$0.width, $0.height] } == [64, 48])
    #expect(saved.item.thumbnailPNG != nil)
}
@Test func pngPayloadGetsLongEdge256Thumbnail() async throws {
    let (store, _, _) = makeStore()
    let saved = try await store.saveScreenshot(.png(AIEnv.png(width: 1080, height: 2400)), deviceName: "P")
    let thumb = try #require(saved.item.thumbnailPNG)
    #expect(ScreenshotEncoder.pixelSize(ofPNG: thumb)?.height == 256)
    #expect(saved.width == 1080 && saved.height == 2400)
}
@Test func invalidPNGIsSavedWithoutThumbnail() async throws {
    let (store, _, _) = makeStore()
    let saved = try await store.saveScreenshot(.png(png), deviceName: "P")  // png 为文件头部 7 字节
    #expect(saved.item.thumbnailPNG == nil && saved.width == nil)
}
@Test func preparationRunsOffMain() async throws {
    let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let (store, _, _) = makeStore(onPrepare: { onMain.withLock { $0 = Thread.isMainThread } })
    _ = try await store.saveScreenshot(.png(png), deviceName: "P")
    #expect(onMain.withLock { $0 } == false)
}
@Test func simultaneousSavesDoNotOverwrite() async throws {
    let fixed = Date(timeIntervalSince1970: 1_760_000_000)
    let (store, _, _) = makeStore(now: { fixed })
    let a = AIEnv.png(width: 10, height: 10), b = AIEnv.png(width: 20, height: 20)
    async let x = store.saveScreenshot(.png(a), deviceName: "P")
    async let y = store.saveScreenshot(.png(b), deviceName: "P")
    let (sx, sy) = try await (x, y)
    #expect(sx.item.url != sy.item.url)
    #expect(Set([FileManager.default.contents(atPath: sx.item.url.path), FileManager.default.contents(atPath: sy.item.url.path)]) == Set([a, b]))
    let names = try FileManager.default.contentsOfDirectory(atPath: store.screenshotDirectory.path)
    #expect(names.filter { $0.hasPrefix(".") }.isEmpty)
}
```

- [ ] **Step 6: 运行确认失败**：App 测试 `-only-testing:TandemTests/CaptureStoreTests`，预期编译失败：`ScreenshotPayload` 未定义。
- [ ] **Step 7: 实现 `CaptureStore` 与 `prepareScreenshot`**：
  - 主线程上只读出 `screenshotDirectory`、`now()` 与 `onPrepare`，然后启动 `Task.detached { probe(); return try Self.prepareScreenshot(...) }`；
  - 回到主线程后：
    - 用 `deviceName`、`date`、`fileSize: Int64(png.count)`、`thumbnailPNG` 建 `CaptureItem`，`kind` 为 `.screenshot`；
    - `append` 到最近记录；
    - `pasteboard.writeImage(png:fileURL:)`；
  - 任一步失败都映射为 `CaptureError.cannotWrite`，并且不改 `recent`、不写剪贴板。帧编码失败时照常抛 `ScreenshotEncoder` 的 DeviceError。
  - `prepareScreenshot` 依次：
    1. `.frame` 用 `encodeFramePNG` 编码，`.png` 原样使用；
    2. `pixelSize`；
    3. `thumbnailPNG`；
    4. 用 `freshURL` 的检查与建目录；
    5. 按下面的算法写入：

```swift
// 先写同目录的隐藏临时文件，再用 link() 占名：目标已存在时 link 原子失败（EEXIST），换下一个候选名。
// 不用 moveItem：它先检查后 rename，并发时会覆盖。
let temp = dir.appendingPathComponent(".tandem-\(UUID().uuidString).png")
try png.write(to: temp, options: .atomic)
defer { try? fm.removeItem(at: temp) }
var tried: Set<String> = []
while true {
    let name = CaptureNaming.fileName(deviceName: deviceName, date: date, ext: "png") {
        tried.contains($0) || fm.fileExists(atPath: dir.appendingPathComponent($0).path)
    }
    let url = dir.appendingPathComponent(name)
    do { try fm.linkItem(at: temp, to: url); return … }
    catch CocoaError.fileWriteFileExists { tried.insert(name) }   // 若实测抛的是 POSIX EEXIST，同样按占名失败处理
}
```

- [ ] **Step 8: 适配调用方**：
  - `DeviceCommands.screenshot` 暂时改为 `try await store.saveScreenshot(.png(try await actions.screenshot()), deviceName: dev.name).item`；
  - `CaptureThumbnail.load` 只用 `item.thumbnailPNG`，删掉从文件解码整图的分支（spec §2.2）；没有缩略图时显示现有占位图标。
- [ ] **Step 9: App 测试全部通过**（含 `DeviceCommandsTests`、`AppServicesTests`）。
- [ ] **Step 10: 提交**

```bash
git add Packages/TandemCore/Sources/MediaKit/ScreenshotEncoder.swift Packages/TandemCore/Tests/MediaKitTests/ScreenshotEncoderTests.swift App/Capture/CaptureStore.swift App/Actions/DeviceCommands.swift App/Workspace/RecentCapturesStrip.swift AppTests/CaptureStoreTests.swift
git commit -m "perf(capture): encode, name and save screenshots off the main actor with thumbnails"
```

### Task 2: 截图来源、高清档与防连点

**Files:**
- Create: `App/Capture/ScreenshotTypes.swift`
- Modify: `App/Actions/DeviceCommands.swift`、`App/TandemApp.swift:83-109`（`CaptureCommands`）、`App/Workspace/CaptureButtons.swift:17-26`
- Test: `AppTests/DeviceCommandsTests.swift`、`AppTests/ScreenshotTypesTests.swift`

**Interfaces:**
- Consumes：Task 1 的 `saveScreenshot(_:deviceName:) -> SavedScreenshot`、`ScreenshotPayload`。
- Produces：
  - `enum ScreenshotQuality: Equatable, Sendable { case standard, lossless }`
    - `init(modifiers: NSEvent.ModifierFlags)`：含 `.option` 为 `.lossless`；
    - `var logTitle: String`：「截图」/「高清截图」。
  - `enum ScreenshotSource: Equatable, Sendable { case mirrorFrame, screencap }`：`var label: String` 为「投屏画质」/「无损」。
  - `enum ScreenshotText { static func note(width: Int?, height: Int?, source: ScreenshotSource) -> String }`：格式为 `"<w>×<h> · <label> · 已复制到剪贴板"`，尺寸未知时省去第一段。
  - `DeviceCommands`：
    - `private(set) var screenshotsInFlight: [String: ScreenshotSource]`（参与观察）；
    - `func screenshotInFlight(_ id: String) -> ScreenshotSource?`；
    - `func screenshot(_ id: String, quality: ScreenshotQuality = .standard, origin: ToastOrigin) async`。

- [ ] **Step 1: 写失败测试**：
  - `ScreenshotTypesTests`：

```swift
#expect(ScreenshotQuality(modifiers: [.option]) == .lossless)
#expect(ScreenshotQuality(modifiers: [.option, .shift]) == .lossless)
#expect(ScreenshotQuality(modifiers: []) == .standard)
#expect(ScreenshotQuality.lossless.logTitle == "高清截图" && ScreenshotQuality.standard.logTitle == "截图")
#expect(ScreenshotText.note(width: 1080, height: 2400, source: .mirrorFrame) == "1080×2400 · 投屏画质 · 已复制到剪贴板")
#expect(ScreenshotText.note(width: nil, height: nil, source: .screencap) == "无损 · 已复制到剪贴板")
```

  - `DeviceCommandsTests`（文件头加 `import os`）：
    - 改 `screenshotSavesLogsAndToasts` 的期望：`FakeActions` 默认数据不是有效 PNG，所以 note 为 `"无损 · 已复制到剪贴板"`；
    - 新增以下测试。截图调用次数用 `OSAllocatedUnfairLock<Int>` 计数，挂起用 `TransferGate`，PNG 用 `AIEnv.png`。

```swift
@Test func standardUsesLatestFrame() async {
    // 推 1 帧 64×48；screenshotProvider 计数
    await e.commands.screenshot("HW1", origin: .workspace)
    #expect(calls == 0)
    #expect(e.toasts.current[.workspace]?.note == "64×48 · 投屏画质 · 已复制到剪贴板")
    #expect(e.log.entries.first?.title == "截图")
}
@Test func standardWithoutSessionFallsBackToScreencap() async {   // make(hasSession: false)，返回 1080×2400 PNG
    #expect(calls == 1 && e.toasts.current[.workspace]?.note == "1080×2400 · 无损 · 已复制到剪贴板")
    #expect(e.log.entries.first?.title == "截图")
}
@Test func losslessIgnoresFrame() async {   // 有帧，quality: .lossless
    #expect(calls == 1 && e.log.entries.first?.title == "高清截图")
}
@Test func concurrentScreenshotsAreIgnored() async {
    let first = Task { await e.commands.screenshot("HW1", quality: .lossless, origin: .workspace) }
    while e.commands.screenshotInFlight("HW1") == nil { await Task.yield() }
    #expect(e.commands.screenshotInFlight("HW1") == .screencap)
    await e.commands.screenshot("HW1", origin: .workspace)          // 立即返回
    gate.release(); await first.value
    #expect(calls == 1 && e.store.recent.count == 1 && e.log.entries.count == 1)
    #expect(e.commands.screenshotInFlight("HW1") == nil)
}
@Test func failedScreenshotClearsInFlight() async {   // result: .failure(TIMEOUT)
    await e.commands.screenshot("HW1", origin: .workspace)
    #expect(e.commands.screenshotInFlight("HW1") == nil && e.toasts.current.isEmpty)
    await e.commands.screenshot("HW1", origin: .workspace)
    #expect(e.log.entries.count == 2 && e.log.entries.allSatisfy { $0.failure != nil })
}
```

- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/DeviceCommandsTests -only-testing:TandemTests/ScreenshotTypesTests`，预期编译失败。
- [ ] **Step 3: 实现**：`screenshot(_:quality:origin:)` 按以下顺序执行（检查与登记之间不能有挂起点）：
  1. 取 `device(id)`；
  2. `guard screenshotsInFlight[id] == nil`；
  3. `quality == .standard` 时取 `session(id)?.latestFrame()`；`session` 闭包在 `AppServices` 里只返回 running 的会话，失败或断开后残留的旧帧不会被用到；
  4. 有帧时来源为 `.mirrorFrame`，否则为 `.screencap`，登记到 `screenshotsInFlight[id]`，并用 `defer` 移除；
  5. `runner.perform(quality.logTitle, device:)`：有帧用 `.frame`，否则用 `.png(try await actions.screenshot())`，然后 `saveScreenshot`；
  6. 成功时 `toasts.show(saved.item, note: ScreenshotText.note(...), in: origin)`。
- [ ] **Step 4: 接入界面**：
  - `CaptureCommands` 在「截图」后加 `Button("高清截图")`，`.keyboardShortcut("s", modifiers: [.command, .shift, .option])`，禁用条件与「截图」相同；
  - `CaptureButtons` 的截图按钮动作改为 `commands.screenshot(deviceID, quality: ScreenshotQuality(modifiers: NSEvent.modifierFlags), origin: origin)`；
  - `screenshotInFlight(deviceID) == .screencap` 时，图标换成 `ProgressView().controlSize(.small)` 并禁用；
  - help 改为 `"截图 (⌘⇧S)，按住 ⌥ 为高清截图"`。
- [ ] **Step 5: App 测试全部通过**。
- [ ] **Step 6: 提交**

```bash
git add App/Capture/ScreenshotTypes.swift App/Actions/DeviceCommands.swift App/TandemApp.swift App/Workspace/CaptureButtons.swift AppTests/DeviceCommandsTests.swift AppTests/ScreenshotTypesTests.swift
git commit -m "feat(capture): screenshot from the latest mirror frame with lossless option and in-flight guard"
```

### Task 3: Theme token、字号与尺寸常量

**Files:**
- Modify: `App/Theme.swift`
- Modify：所有用到 `Theme.separator` 的文件，`grep -rl "Theme.separator" App` 共 8 个，统一改为 `Theme.border`；`App/DeviceWindow/RomBannerView.swift` 改用 `warnTint` / `warnText`。
- Create: `App/Style/Typography.swift`、`App/Style/Metrics.swift`
- Test: `AppTests/ThemeTests.swift`、`AppTests/Support/ColorProbe.swift`

**Interfaces:**
- Produces：
  - `Theme.dynamic` 增加 `darkAlpha: CGFloat? = nil`，nil 表示与 `alpha` 相同。
  - 改值与新增 token 见下表，格式为「浅色 / 深色」，带 @ 的是透明度。

    | Token | 浅色 / 深色 |
    |---|---|
    | windowBackground | FFFFFF / 1E1F22 |
    | titleBar | F6F6F8 / 2A2B2F |
    | card | FFFFFF / 2C2E33 |
    | sidebar | F4F4F6 / 1F2125 |
    | panel | FBFBFC / 26282C |
    | canvas | EEF0F3 / 18191C |
    | canvasDot | 000000@0.05 / FFFFFF@0.06 |
    | border | E5E5EA / 35383D |
    | cardBorder | E8E8ED / 3A3B40 |
    | controlBorder | D8D8DD / 48494F |
    | rowDivider | F0F0F3 / 2E2F33 |
    | hover | 000000@0.04 / FFFFFF@0.06 |
    | controlHover | F2F2F5 / 34353A |
    | textPrimary | 1D1D1F / ECEDEF |
    | textSecondary | 6E6E73 / 9BA1AB |
    | textTertiary | 3A3A3C / C7C7CC |
    | accent | 2F6FED / 5A8DF2 |
    | accentStrong | 2459C9 / 7FA6F5 |
    | accentTint | EEF2FF / 1E2A44 |
    | accentTintBorder | D9E3FB / 2C3D63 |
    | aiTint | F3EEFF / 2D2545 |
    | aiText | 6B4FD8 / A894F0 |
    | chipNeutral | EDEDF0 / 34353A |
    | chipCount | E5E5EA / 3A3B40 |
    | success | 1F9D55 / 3DC47E |
    | successTint | E8F5EE / 17301F |
    | successText | 146C3B / 6FD69C |
    | danger | D93025 / F26B60 |
    | dotOff | AEAEB2 / 636366 |
    | toggleOff | D1D1D6 / 4A4B50 |
    | toggleDisabled | E5E5EA / 34353A |
    | warnTint | FFF6E0 / 3A2F12 |
    | warnBorder | F1E0B0 / 5C4A1C |
    | warnText | 7A5200 / F5C76B |
    | bezel | 1C1C1E / 0A0A0B |
    | dashed | C7C7CC / 55565B |
    | knob | FFFFFF / F2F2F5 |
    | codeDark | 1D1D1F / 111113 |
    | codeDarkText | F2F2F5 / F2F2F5 |
    | shadow | 000000 / 000000 |
    | shadowDeep | 101828 / 101828 |

  - `dropOverlay` 的 alpha 改为 0.12。删除 `separator`、`bannerBackground`、`bannerText`，其余现有 token 不动。
  - `enum TextRole { case headerTitle, sectionTitle, body, button, meta, chip, mono, monoMeta }`，属性为 `size: CGFloat`、`weight: Font.Weight`、`tracking: CGFloat`、`monospaced: Bool`：

    | 角色 | 字号 | 字重 | 其他 |
    |---|---|---|---|
    | headerTitle | 14 | bold | |
    | sectionTitle | 11 | semibold | tracking 0.44 |
    | body | 13 | regular | |
    | button | 12 | regular | |
    | meta | 11 | regular | |
    | chip | 10 | regular | |
    | mono | 12 | regular | 等宽 |
    | monoMeta | 11 | regular | 等宽 |

    另有 `extension Font { static func tandem(_ role: TextRole) -> Font }`、`extension View { func tandemText(_ role: TextRole) -> some View }`（设置字体与字距）。
  - `enum Metrics`（CGFloat）：
    - 圆角：`cardRadius = 10`、`buttonRadius = 8`、`rowRadius = 9`、`chipRadius = 8`、`pillRadius = 12`；
    - 高度：`buttonHeight = 30`、`cardRowMinHeight = 34`、`deviceHeaderHeight = 48`；
    - 布局：`sidebarWidth = 232`、`panelWidth = 372`、`bottomHeight = 168`、`mirrorMinWidth = 360`；
    - 间距：`sectionSpacing = 20`、`headerToCard = 8`；
    - 开关：`switchSize = CGSize(width: 36, height: 20)`、`knobSize = 16`；
    - 卡片内边距：`cardPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)`。
- `ColorProbe.rgba(_ color: Color, dark: Bool) -> (hex: UInt32, alpha: CGFloat)`：在 `NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance` 内把 `NSColor(color)` 转成 sRGB 后读取。

- [ ] **Step 1: 写失败测试**：
  - `lightValuesMatchSpec`：对 spec §3.1 表中每个 token 断言 `ColorProbe.rgba(token, dark: false)` 等于上表浅色值，alpha 误差 < 0.005。
  - `everyTokenHasDarkVariant`：上表除 `shadow`、`shadowDeep`、`codeDarkText` 外的每个 token，深色的 hex 或 alpha 与浅色不同。
  - `typeScale`：`TextRole.sectionTitle.size == 11 && .weight == .semibold && .tracking == 0.44`；`body 13`、`button 12`、`meta 11`、`chip 10`、`mono 12 && monospaced`、`headerTitle 14 bold`。
  - `layoutMetrics`：`Metrics.sidebarWidth == 232 && panelWidth == 372 && bottomHeight == 168 && deviceHeaderHeight == 48 && buttonHeight == 30`。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/ThemeTests`，预期编译失败：`Theme.windowBackground` 未定义。
- [ ] **Step 3: 实现** Theme 改值、新增 token、`darkAlpha`、`TextRole`、`Metrics`，并做 `separator` → `border` 的全局替换。
- [ ] **Step 4: App 测试全部通过**。
- [ ] **Step 5: 提交**

```bash
git add App AppTests
git commit -m "feat(style): workspace color tokens, type scale and layout metrics"
```

### Task 4: App/Style 共用组件与快照画廊

**Files:**
- Create: `App/Style/Buttons.swift`、`Switch.swift`、`Card.swift`、`SectionHeader.swift`、`Chip.swift`、`Field.swift`、`UnderlineTabs.swift`、`FlowLayout.swift`、`DotGrid.swift`、`PhoneBezel.swift`、`ToolbarPill.swift`
- Modify: `App/Workspace/MirrorPane.swift:218-239`（删掉私有 `DotGrid`，改用 Style 版）
- Create: `AppTests/Support/SnapshotRenderer.swift`
- Test: `AppTests/StyleTests.swift`、`AppTests/Snapshots/StyleGallerySnapshotTests.swift`

**Interfaces:**
- Consumes：Task 3 的 `Theme`、`TextRole`、`Metrics`。
- Produces：
  - `struct TandemButtonStyle: ButtonStyle`：
    - `enum Kind { case secondary, primary, icon, link }`；`init(_ kind: Kind, height: CGFloat = Metrics.buttonHeight, tint: Color? = nil)`；`tint` 只对 link 生效，覆盖文字色；
    - `static func colors(_ kind: Kind, hovered: Bool, pressed: Bool) -> (fill: Color, stroke: Color, text: Color)`；
    - 尺寸：secondary 与 primary 左右内边距 12，icon 为 height×height，圆角 8，文字 `.button`；link 无底无框，12 pt，`accentStrong`；
    - 禁用时不透明度 0.45；悬停由 `makeBody` 返回的内部视图用 `@State` 加 `onHover` 实现。
  - `struct TandemSwitchStyle: ToggleStyle`：
    - `static func trackColor(isOn: Bool, isEnabled: Bool) -> Color`；
    - 只画轨道：36×20、圆角 10、内边距 2；滑块 16，颜色 `knob`，阴影 `shadow` 0.2 / radius 1 / y 1；
    - 用 `.accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }` 保留辅助功能。
  - `extension View { func tandemCard(padding: EdgeInsets = Metrics.cardPadding) -> some View }`：底色 `card`，1 px `cardBorder`，圆角 10，阴影为 `shadow` 透明度 0.04、radius 1、y 1。
  - `struct CardRow<Trailing: View>: View { init(_ label: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) }`：最小高度 34，标签 `.body`，副标题 `.meta` 配 `textSecondary`。
  - `struct CardDivider: View`：1 px `rowDivider`。
  - `struct SectionHeader<Trailing: View>: View { init(_ title: String, badge: Chip? = nil, @ViewBuilder trailing: () -> Trailing) }`：
    - 另有 `Trailing == EmptyView` 的便捷 init；
    - 标题 `.sectionTitle` 配 `textSecondary`，徽标在标题后 8 pt，尾部内容靠右。
  - `enum ChipTone { case accent, neutral, ai, success, danger, count }` 与 `struct Chip: View { init(_ text: String, tone: ChipTone, dot: Bool = false) }`：
    - 默认：10 pt，内边距 1 / 6，圆角 8；
    - `dot == true` 或 `.count`：11 pt，内边距 2 / 8（count 为 0 / 7），圆角 9；`dot` 为 6 px 圆点；
    - 底色 / 文字色：

      | tone | 底色 / 文字色 |
      |---|---|
      | accent | accentTint / accentStrong |
      | neutral | chipNeutral / textTertiary |
      | ai | aiTint / aiText |
      | success | successTint / successText（圆点 success） |
      | danger | danger@0.12 / danger |
      | count | chipCount / textTertiary |
  - `struct StatusDot: View { init(size: CGFloat = 6, filled: Bool = true, color: Color = Theme.success) }`：空心时为 1.5 px `dotOff` 描边。
  - `struct TandemFieldStyle: ViewModifier { init(mono: Bool = false, multiline: Bool = false) }` 与 `View.tandemField(mono:multiline:)`：
    - 套 `.textFieldStyle(.plain)`，左右内边距 10，高 30（`multiline` 时为最小高 30、上下内边距 6）；
    - 圆角 8，底色 `card`，1 px `controlBorder`；字体 `.button`，mono 时为 `.mono`。
  - `struct UnderlineTabs<Tab: Hashable>: View { init(_ tabs: [(tab: Tab, title: String)], selection: Binding<Tab>) }`：
    - 间距 18、高 32、13 pt；
    - 选中项字重 600、`textPrimary`，加 2 px `accent` 下划线；未选中项 400、`textSecondary`。
  - `struct FlowLayout: Layout { var spacing: CGFloat = 6; var lineSpacing: CGFloat = 6; static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] }`：贪心换行；比 `maxWidth` 还宽的项独占一行。
  - `struct DotGrid: View { var spacing: CGFloat = 20; var radius: CGFloat = 1 }`：颜色 `canvasDot`。
  - `enum BezelGeometry { static let frame: CGFloat = 7; static func outerRadius(width: CGFloat) -> CGFloat /* width * 40 / 260 */; static func innerRadius(screenWidth: CGFloat) -> CGFloat /* max(0, outerRadius(screenWidth + 2*frame) - frame) */ }`
  - `struct BezelScreenShape: Shape`：按自身 rect 宽度取 `innerRadius` 的圆角矩形。
  - `extension View { func phoneBezel() -> some View }`：
    - 内边距 7；
    - 背景为 `RoundedRectangle(cornerRadius: BezelGeometry.outerRadius(width: rect.width))` 填 `bezel`，用 Shape 在 path 中取 rect，不用 GeometryReader 或 State；
    - 阴影为 `shadowDeep` 透明度 0.12、radius 20、y 20。
  - `struct ToolbarPill<Content: View>: View { init(@ViewBuilder content: () -> Content) }`：内边距 6，圆角 12，`card` 透明度 0.85，1 px `cardBorder`，卡片阴影，内容间距 6。
  - `@MainActor enum SnapshotRenderer`：
    - `static let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tandem-snapshots")`；
    - `@discardableResult static func render<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) throws -> CGImage`：
      - 视图套 `.frame(width:height:)`，背景为 `Theme.windowBackground`；
      - `ImageRenderer` 的 `scale = 2`；
      - 浅色写 `<name>.png`；在 `performAsCurrentDrawingAppearance(.darkAqua)` 中加 `.environment(\.colorScheme, .dark)` 再渲染一次，写 `<name>-dark.png`；
      - 返回浅色图像，渲染失败时抛错。

- [ ] **Step 1: 写失败测试**：
  - `StyleTests`：

```swift
#expect(FlowLayout.rows(widths: [50, 50, 50], maxWidth: 120, spacing: 6) == [[0, 1], [2]])
#expect(FlowLayout.rows(widths: [200, 30], maxWidth: 120, spacing: 6) == [[0], [1]])
#expect(FlowLayout.rows(widths: [], maxWidth: 120, spacing: 6) == [])
#expect(FlowLayout.rows(widths: [40, 40], maxWidth: .infinity, spacing: 6) == [[0, 1]])
#expect(BezelGeometry.outerRadius(width: 260) == 40)
#expect(BezelGeometry.innerRadius(screenWidth: 246) == 33)
#expect(BezelGeometry.innerRadius(screenWidth: 0) == 0)
#expect(TandemButtonStyle.colors(.primary, hovered: false, pressed: false).fill == Theme.accent)
#expect(TandemButtonStyle.colors(.primary, hovered: true, pressed: false).fill == Theme.accentStrong)
#expect(TandemButtonStyle.colors(.secondary, hovered: false, pressed: false) == (Theme.card, Theme.controlBorder, Theme.textPrimary))
#expect(TandemButtonStyle.colors(.secondary, hovered: true, pressed: false).fill == Theme.controlHover)
#expect(TandemButtonStyle.colors(.link, hovered: false, pressed: false).text == Theme.accentStrong)
#expect(TandemSwitchStyle.trackColor(isOn: true, isEnabled: true) == Theme.accent)
#expect(TandemSwitchStyle.trackColor(isOn: false, isEnabled: true) == Theme.toggleOff)
#expect(TandemSwitchStyle.trackColor(isOn: true, isEnabled: false) == Theme.toggleDisabled)
```

  元组比较可拆成三条 `#expect`。

  - `StyleGallerySnapshotTests.primitives`：
    - 渲染测试内的 `StyleGallery` 视图（420×720），内容依次为：
      - 四种按钮各一个，外加一个禁用按钮；
      - 开关 on / off / disabled；
      - 六种 Chip 和一个带点的「实时」；
      - 实心与空心 StatusDot；
      - `SectionHeader("网络", badge: Chip("该设备不支持", tone: .neutral))`；
      - 一张 `tandemCard`，含两行 `CardRow` 与 `CardDivider`；
      - `Text("https://").tandemField(mono: true)`，代替 TextField 展示字段样式；
      - `UnderlineTabs`；
      - 一个装 6 个 Chip 的 `FlowLayout`，宽 200；
      - 200×120 的 `DotGrid`；
      - `Theme.videoBackground.frame(width: 120, height: 240).clipShape(BezelScreenShape()).phoneBezel()`；
      - 装 3 个 icon 按钮的 `ToolbarPill`。
    - 断言 `image.width == 840 && image.height == 1440`。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/StyleTests -only-testing:TandemTests/StyleGallerySnapshotTests`，预期编译失败。
- [ ] **Step 3: 实现**上述组件与 `SnapshotRenderer`。
- [ ] **Step 4: App 测试通过**，然后打开 `$TMPDIR/tandem-snapshots/style-primitives.png` 与 `-dark.png`，对照 `Workspace.dc.html` 第 15–30 行的 `.ws-btn` / `.ws-pri` / `.ws-ico` 样式、第 204 行的芯片、第 345 行的开关，检查：
  - 按钮高 30、圆角 8；主按钮 #2F6FED；
  - 开关 36×20；
  - 芯片 10 pt；卡片圆角 10、描边 #E8E8ED；
  - 区块标题 11 pt semibold 加字距；
  - 下划线 2 px；点阵间距 20；
  - 外框 7 pt；工具条圆角 12；
  - 深色版没有不可读的组合。
  - 若深色 PNG 与浅色完全相同（动态 NSColor 没有按外观解析），把渲染改为在 `NSHostingView` 上设置 `appearance` 后 `cacheDisplay`，仍写同名文件。
- [ ] **Step 5: 提交**

```bash
git add App/Style App/Workspace/MirrorPane.swift AppTests/Support/SnapshotRenderer.swift AppTests/StyleTests.swift AppTests/Snapshots
git commit -m "feat(style): shared workspace components and snapshot gallery"
```

### Task 5: 右栏外壳、分段容器与能力概览

**Files:**
- Create: `App/Workspace/RightPanelHeader.swift`、`AppTests/Support/QuickEnv.swift`（从 `QuickActionsModelTests.make` 提出，`QuickActionsModelTests` 改为调用它）
- Modify: `App/Workspace/WorkspaceView.swift:50-106`（`RightTab`、`RightColumn`）、`App/QuickActions/QuickSection.swift`、`App/Workspace/QuickActionsTab.swift`、`App/Workspace/CaptureButtons.swift:80-114`（`PanelErrorBanner`）
- Test: `AppTests/RightPanelTests.swift`、`AppTests/Snapshots/RightPanelSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 4 的组件。
- Produces：
  - `RightTab`：
    - `var title: String`：快捷操作 / 文件 / 剪贴板 / AI；
    - `static func visible(hasFiles: Bool) -> [RightTab]`：顺序为 quickActions、files（`hasFiles` 时才有）、clipboard、ai。
  - `struct RightPanelHeader: View { init(deviceName: String?, tabs: [RightTab], selection: Binding<RightTab>) }`：
    - 内边距 14 / 16 / 0；
    - 「设备控制」用 13 semibold，设备名用 12 `textSecondary`；
    - 下方 `UnderlineTabs`，底部 1 px `border`。
  - `QuickSectionID.allCases` 的顺序改为 `.network, .apps, .openURL, .system, .devOptions, .custom`（rawValue 不变，折叠状态照旧）。
  - `struct QuickSectionChrome<Content: View>: View { init(title: String, unsupported: Bool, collapsed: Bool, onToggle: @escaping () -> Void, onRefresh: (() -> Void)?, @ViewBuilder content: () -> Content) }`：
    - 标题行：`SectionHeader`，不支持时徽标为 `Chip("该设备不支持", tone: .neutral)`；尾部依次为刷新图标（`arrow.clockwise`，11 pt，`textSecondary`，`.icon` 按钮高 22）和折叠箭头；
    - 内容与标题相距 8；不支持时内容不透明度 0.45 并禁用。
  - `QuickSection` 只负责从模型取值，然后交给 `QuickSectionChrome`。
  - `struct CapabilityOverviewCard: View { init(deviceName: String, rows: [(title: String, supported: Bool)]) }` 与 `static func title(deviceName: String) -> String`，格式为 `"能力概览 · <name>"`：
    - 行内边距 7 / 12，12 pt；
    - 7 px `StatusDot`：支持时实心 `success`，不支持时空心；
    - 尾部文字「支持」/「不支持」，后者用 `textSecondary`。
  - `QuickActionsTab`：内边距 14 / 16 / 20，各块间距 20，不再画分隔线；按 `QuickSectionID.allCases` 的顺序排列，最后是能力概览。
  - `PanelErrorBanner`：改为 `tandemCard`，描边为 `danger` 透明度 0.5，底色 `danger` 透明度 0.06；文字 `.body` / `.meta`；关闭按钮用 `.icon` 样式。

- [ ] **Step 1: 写失败测试**：

```swift
#expect(QuickSectionID.allCases == [.network, .apps, .openURL, .system, .devOptions, .custom])
#expect(RightTab.visible(hasFiles: true) == [.quickActions, .files, .clipboard, .ai])
#expect(RightTab.visible(hasFiles: false) == [.quickActions, .clipboard, .ai])
#expect(RightTab.quickActions.title == "快捷操作" && RightTab.ai.title == "AI")
#expect(CapabilityOverviewCard.title(deviceName: "Pixel 8") == "能力概览 · Pixel 8")
```

  另写 `RightPanelSnapshotTests.shell`，渲染 372×520：
  - `RightPanelHeader(deviceName: "Pixel 8", tabs: RightTab.visible(hasFiles: true), selection: .constant(.quickActions))`；
  - 一个 `unsupported: true` 的 `QuickSectionChrome` 和一个 `unsupported: false` 的，内容为一行 `CardRow`；
  - 一张 3 行的 `CapabilityOverviewCard`，含两种状态；
  - 断言尺寸为 744×1040。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/RightPanelTests -only-testing:TandemTests/RightPanelSnapshotTests`。
- [ ] **Step 3: 实现**：
  - `RightColumn` 的 `Picker(.segmented)` 换成 `RightPanelHeader`；
  - 「未选择设备」改用 `.body` 字号；
  - 重排 `QuickSectionID`，改写 `QuickSection`、`QuickActionsTab`、`CapabilityOverview`、`PanelErrorBanner`。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 186–212 行（右栏头部、网络块标题）与第 308–318 行（能力概览）检查快照：
  - 标签间距 18、选中下划线；
  - 标题字距；
  - 芯片 #EDEDF0；
  - 卡片阴影很淡；
  - 能力行之间有 #F0F0F3 分隔线。
- [ ] **Step 5: 提交**

```bash
git add App/Workspace App/QuickActions/QuickSection.swift AppTests/Support/QuickEnv.swift AppTests/QuickActionsModelTests.swift AppTests/RightPanelTests.swift AppTests/Snapshots/RightPanelSnapshotTests.swift
git commit -m "feat(workspace): right panel header, underline tabs and card sections in design order"
```

### Task 6: 网络与应用分段（恢复默认网络、拖放区）

**Files:**
- Create: `App/QuickActions/ApkDropZone.swift`
- Modify: `App/Actions/DeviceCommands+QuickActions.swift`、`App/QuickActions/QuickActionsModel.swift`、`App/QuickActions/NetworkSection.swift`、`App/QuickActions/AppsSection.swift`、`App/Transfers/DropOverlay.swift`（`DropPlan`）、`App/DeviceWindow/MirrorView.swift:225-243`（改用 `DropPlan.urls(from:)`）
- Test: `AppTests/QuickActionsModelTests.swift`、`AppTests/DeviceCommandsQuickTests.swift`、`AppTests/TransferNoticeTests.swift`、`AppTests/Snapshots/QuickSectionsSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 5 的 `QuickSectionChrome`、`QuickEnv`；P3c 的 `DeviceCommands.pushFiles(_:_:origin:)`、`DropPlan.accepted`、`FileDropDelegate`。
- Produces：
  - `struct NetworkStep: Equatable { let kind: NetworkKind; let on: Bool }`
  - `DeviceCommands.resetNetworkSteps(_ state: NetworkState?) -> [NetworkStep]`（static）：
    - 目标依次为飞行模式关、Wi-Fi 开、移动数据开；
    - 只保留 `state[kind]` 非 nil 且不等于目标值的项；`state` 为 nil 时返回空。
  - `DeviceCommands.resetNetwork(_ id: String, steps: [NetworkStep]) async -> NetworkState?`：
    - 在一次 `mutate(id, "恢复默认网络")` 里依次调用 `setNetwork`，第一步失败就抛出；
    - 返回最后一次回读的状态。
  - `QuickActionsModel.resetNetwork(_ id: String) async`：
    - 在 `whileBusy(id, .network)` 里执行；
    - 步骤取自当前的 `network[id]` 成功值，没有步骤时直接返回；
    - 执行完无论成败都 `network[id] = await commands.readNetwork(id)`。
  - `DropPlan.urls(from providers: [NSItemProvider]) async -> [URL]`：保持顺序，读不出的跳过。逻辑从 `MirrorView.fileURL` 移过来。
  - `struct ApkDropZone: View { init(canInstall: Bool, canPush: Bool, onFiles: @escaping ([URL]) -> Void) }`：
    - 尺寸：高 74，圆角 10，1.5 px 虚线（`dash: [4, 3]`）`dashed`，底色 `card`；
    - 内容：18 pt `square.and.arrow.up` 图标，12 pt 文案「拖入 APK 安装 / 其他文件推送到 /sdcard/Download」；
    - 点击时弹 `NSOpenPanel`：可多选，可选文件和文件夹；
    - 拖入时用 `FileDropDelegate`，悬停期间虚线改为 `accent`；
    - 两种来源都经 `DropPlan.accepted` 过滤，非空才调用 `onFiles`。
- 网络卡片：
  - 每种 `NetworkKind` 一行 `CardRow`，尾部为 `Toggle` 套 `TandemSwitchStyle`，或现有的 `UnreadableMark`，忙时加小转圈；
  - 卡片下方是 `Button("恢复默认网络")`，样式 `.secondary`，靠左；步骤为空或忙时禁用；
  - Wi-Fi 确认框逻辑不变。
- 应用卡片（内边距 10 / 12，间距 8）：
  - 「目标」行保留 `Menu`；
  - 「当前前台」标签用 `.meta`；包名用 13 pt 等宽，后接版本号（`.meta`）和 `Button("固定")`（`.link` 样式），去掉 📌；
  - 五个操作按钮用 `LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6)` 排列，`.secondary` 样式，宽度撑满；
  - 卡片下方：`can(.apps) || can(.files)` 时显示 `ApkDropZone`，`onFiles` 接 `{ model.commands.pushFiles(deviceID, $0, origin: .workspace) }`；
  - 最下方是 `Button("查看日志")`（`.link` 样式），行为与原「日志」按钮相同。

- [ ] **Step 1: 写失败测试**：

```swift
// DeviceCommandsQuickTests
#expect(DeviceCommands.resetNetworkSteps(nil) == [])
#expect(DeviceCommands.resetNetworkSteps(NetworkState(wifi: false, data: false, airplane: true))
        == [NetworkStep(kind: .airplane, on: false), NetworkStep(kind: .wifi, on: true), NetworkStep(kind: .data, on: true)])
#expect(DeviceCommands.resetNetworkSteps(NetworkState(wifi: true, data: nil, airplane: false)) == [])
#expect(DeviceCommands.resetNetworkSteps(NetworkState(wifi: false, data: true, airplane: false)) == [NetworkStep(kind: .wifi, on: true)])
// QuickActionsModelTests：resetNetworkRunsStepsLogsOnceAndRereads
// networkStateResult = (wifi: false, data: false, airplane: true)；先 refresh(.network)，再 resetNetwork
#expect(actions.calls.suffix(4) == ["setNetwork airplane false", "setNetwork wifi true", "setNetwork data true", "networkState"])
#expect(env.log.entries.map(\.title) == ["恢复默认网络"])
// resetNetworkStopsAtFirstFailure：errors["setNetwork"] = DeviceError(code: .TIMEOUT, message: "超时")
#expect(actions.calls.filter { $0.hasPrefix("setNetwork") } == ["setNetwork airplane false"])
#expect(env.log.entries.count == 1 && env.log.entries[0].failure == "超时")
#expect(actions.calls.last == "networkState")
// TransferNoticeTests：urlsFromProvidersKeepOrder
let urls = [URL(fileURLWithPath: "/tmp/a.apk"), URL(fileURLWithPath: "/tmp/b.jpg")]
#expect(await DropPlan.urls(from: urls.map { NSItemProvider(object: $0 as NSURL) }) == urls)
```

  另写 `QuickSectionsSnapshotTests.networkAndApps`：
  - 用 `QuickEnv` 建一台设备并 `await model.refreshAll(id)`；
  - 渲染 372×640：`QuickSection(.network) { NetworkSection }` 加 `QuickSection(.apps) { AppsSection }`，放在 `VStack(spacing: 20)` 里，内边距 14 / 16；
  - 断言尺寸为 744×1280。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/DeviceCommandsQuickTests -only-testing:TandemTests/QuickActionsModelTests -only-testing:TandemTests/TransferNoticeTests -only-testing:TandemTests/QuickSectionsSnapshotTests`。
- [ ] **Step 3: 实现**上述接口与两张卡片；`MirrorView.handleDrop` 改为 `await DropPlan.urls(from: providers)`。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 202–232 行检查快照：
  - 开关行高 34；
  - 「恢复默认网络」靠左；
  - 包名等宽 13 pt；
  - 等宽按钮网格；
  - 虚线框高 74、#C7C7CC；
  - 「查看日志」为链接色 #2459C9。
- [ ] **Step 5: 提交**

```bash
git add App/QuickActions App/Actions/DeviceCommands+QuickActions.swift App/Transfers/DropOverlay.swift App/DeviceWindow/MirrorView.swift AppTests
git commit -m "feat(quick-actions): network and apps cards with reset-network and file drop zone"
```

### Task 7: 打开链接、系统、开发者、自定义命令分段

**Files:**
- Modify: `App/QuickActions/OpenURLSection.swift`、`App/QuickActions/SystemSection.swift`、`App/QuickActions/DevOptionsSection.swift`（含 `SettingToggleRow`、`SettingChoiceRow`）、`App/QuickActions/CustomCommandsSection.swift`
- Test: `AppTests/Snapshots/QuickSectionsSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 4 的 `FlowLayout`、`tandemField`、`TandemButtonStyle`、`CardRow`、`TandemSwitchStyle`；Task 5 的 `QuickEnv`。
- 打开链接：
  - `TextField("https:// 或 scheme://", text:).tandemField(mono: true)` 加 `Button("打开")`（`.primary` 样式）；
  - 历史放进 `FlowLayout`，每条是一个按钮：高 24、圆角 12、1 px `border`、11 pt 等宽、`textTertiary`、`truncationMode(.middle)`、最大宽 300；点击即打开；
  - 删除改用 `contextMenu { Button("删除") }`，去掉悬停 ✕。
- 系统、开发者：
  - `SettingToggleRow` 改为 `CardRow` 加 `TandemSwitchStyle`；`SettingChoiceRow` 改为 `CardRow` 加 `Menu`（`.menuStyle(.borderlessButton)`、`.button` 字号）；
  - 行之间放 `CardDivider`，整块套 `tandemCard()`；
  - 系统卡片下方是 `Button("打开系统语言设置")`（`.secondary` 样式）。
- 自定义命令：
  - `FlowLayout` 里每条命令一个 `.secondary` 按钮；执行中的按钮在标题前显示小转圈并禁用；help 照旧；
  - 末尾依次是 `Button("+ 添加")`（`.secondary`），以及有命令时的 `Button(editing ? "完成" : "编辑")`（`.link`）；
  - 编辑模式的 `List` 保留；
  - 输出框 `OutputBox`：底色 `controlHover`，圆角 8，内边距 10 / 12，正文 12 等宽；标题行用 `.meta`，失败时 `danger`；「拷贝」用 `.link` 样式。

- [ ] **Step 1: 写快照测试** `QuickSectionsSnapshotTests.linksSystemDevCustom`：
  - 准备数据：`QuickEnv` 的 store 里有 3 条 URL 历史、2 条自定义命令，其中一条有输出（先 `await model.runCustom`），然后 `refreshAll`；
  - 渲染 372×900：openURL、system、devOptions、custom 四个 `QuickSection`；
  - 断言尺寸为 744×1800。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/QuickSectionsSnapshotTests`。在改样式之前快照也能渲染，所以这一步的「失败」检查的是：快照里出现 TextField / Toggle / 按钮的占位块。记下占位块的位置。
- [ ] **Step 3: 实现**上述样式。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 233–307 行检查快照：
  - 链接芯片可换行、等宽 11 pt；
  - 「打开」为蓝底主按钮；
  - 系统 / 开发者为卡片行加开关；
  - 自定义命令按钮可换行；输出框为 #F2F2F5 底。
  - 除 TextField 与 Menu 外不应再有占位块。
- [ ] **Step 5: 提交**

```bash
git add App/QuickActions AppTests/Snapshots/QuickSectionsSnapshotTests.swift
git commit -m "feat(quick-actions): restyle open-link, system, developer and custom command sections"
```

### Task 8: 剪贴板与 AI 标签

**Files:**
- Modify: `App/Workspace/ClipboardTab.swift`、`App/Workspace/AITab.swift`
- Test: `AppTests/WorkspaceTabsTests.swift`、`AppTests/Snapshots/TabsSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 4 的组件。
- Produces：
  - `ClipboardTab.syncSubtitle(on: Bool) -> String`（static）：开为「已开启：Mac 与手机剪贴板实时同步」，关为「默认关闭，需要时手动读取或写入」。
  - `ClipboardDirection`：
    - `var chipTitle: String`：读 / 写 / 同步；
    - `var chipTone: ChipTone`：read 为 `.accent`，write 与 sync 为 `.neutral`。
  - `AITab.lockSubtitle(locked: Bool) -> String`（static）：锁定时为「已锁定：操作类工具返回 AI_LOCKED」，否则为「锁定后截图、UI 树、日志仍可用」。
  - `ClipboardTabContent`、`AITabContent`：原 body 里 `ScrollView` 内的部分，供快照渲染。
- 剪贴板页（外层 `ScrollView`，内边距 14 / 16 / 20，块间距 20）：
  - 「读取」：`SectionHeader` 下放 `Button("读取手机剪贴板")`（`.secondary`）。`preview` 非空时显示信息卡：底色 `accentTint`，1 px `accentTintBorder`，圆角 10，内边距 9 / 11；标签「手机剪贴板内容（已复制到 Mac）」11 pt `accentStrong`；正文 12 等宽，可选择。
  - 「写入（默认填入 Mac 剪贴板内容）」：
    - `TextField("", text: $input, axis: .vertical).lineLimit(1...4).tandemField(multiline: true)`，提示文字为 Mac 剪贴板首行，没有时为「输入要写入的文本」；
    - 下方两个等宽按钮「写入」（`.secondary`）与「写入并粘贴」（`.primary`），去掉「（输入框）」后缀；可写来源为空时禁用，并显示原有提示。
  - 「最近记录（点击再次写入）」：
    - `.meta` 标签下是一张卡片，每行高 32，依次为方向芯片和单行省略的首行文本；
    - 悬停底色 `hover`；点击为再次写入；`contextMenu { Button("复制到 Mac") }`。
  - 「双向自动同步」：`CardRow` 加 `syncSubtitle`，开关用 `TandemSwitchStyle`。
  - 「文件」：说明文字「在投屏上按 ⌘V 时，按 Mac 剪贴板里的文件推送到设备」，12 pt `textSecondary`。
- AI 页：
  - 连接卡片（`tandemCard(padding: 12)`，间距 10）：
    - 8 px `StatusDot`，颜色沿用 `statusColor`，后接 13 semibold 的 `statusText`；
    - 下一行是 11 pt 等宽的 `clientsText`；
    - 有 mcpPath 时显示 `Button("复制接入命令")`（`.secondary`），复制 `ClaudeSetup.addCommand`。
  - 「接入」：`SectionHeader` 下是 `Button("添加到 Claude Code")`（`.primary`），然后是结果文字；命令片段用深色代码块（`codeDark` 底，`codeDarkText` 字，圆角 8，内边距 10 / 12，12 等宽），JSON 片段用 `controlHover` 底；「拷贝」用 `.link`。
  - 「当前设备」：`CardRow("禁止 AI 操作", subtitle: lockSubtitle)` 加 `TandemSwitchStyle`，下方是原有的 `aiIdleHint`，用 `.meta`。

- [ ] **Step 1: 写失败测试**：

```swift
#expect(ClipboardTab.syncSubtitle(on: true) == "已开启：Mac 与手机剪贴板实时同步")
#expect(ClipboardTab.syncSubtitle(on: false) == "默认关闭，需要时手动读取或写入")
#expect(ClipboardDirection.read.chipTone == .accent && ClipboardDirection.write.chipTone == .neutral)
#expect(ClipboardDirection.sync.chipTitle == "同步")
#expect(AITab.lockSubtitle(locked: true) == "已锁定：操作类工具返回 AI_LOCKED")
#expect(AITab.lockSubtitle(locked: false) == "锁定后截图、UI 树、日志仍可用")
```

  另写 `TabsSnapshotTests.clipboardAndAI`：
  - 按 `AppServicesTests.make` 的方式建 `AppServices`，设备带 `.clipboard` 能力；
  - 用 `services.clipboard` 的测试入口写入一条读记录和一条写记录（`ClipboardServiceTests` 中已有写法）；
  - 分别渲染 `ClipboardTabContent` 与 `AITabContent`，尺寸各 372×760；
  - 断言尺寸均为 744×1520。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/WorkspaceTabsTests -only-testing:TandemTests/TabsSnapshotTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 323–388 行检查快照：
  - 信息卡 #EEF2FF；
  - 两个等宽按钮，右边为蓝底；
  - 记录芯片：读为蓝、写为灰；
  - 开关行带副标题；
  - AI 状态卡加深色命令块。
- [ ] **Step 5: 提交**

```bash
git add App/Workspace/ClipboardTab.swift App/Workspace/AITab.swift AppTests/WorkspaceTabsTests.swift AppTests/Snapshots/TabsSnapshotTests.swift
git commit -m "feat(workspace): card layout and switches for clipboard and AI tabs"
```

### Task 9: 投屏区：设备头部、画布、手机外框、浮动工具条

**Files:**
- Create: `App/Workspace/WorkspaceText.swift`
- Modify: `App/Workspace/MirrorPane.swift`、`App/DeviceWindow/MirrorView.swift:97-213`、`App/Workspace/CaptureButtons.swift`、`App/DeviceWindow/DeviceWindowView.swift:42-44`
- Test: `AppTests/MirrorPaneTests.swift`、`AppTests/Snapshots/MirrorPaneSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 2 的 `screenshotInFlight`；Task 4 的 `phoneBezel`、`BezelScreenShape`、`ToolbarPill`、`DotGrid`、`Chip`。
- Produces：
  - `enum WorkspaceText`：
    - `static func deviceMeta(platform: Platform, runningSize: CGSize?, connection: ConnectionKind) -> String`：例如 `"Android · 1080×2400 · USB"`，缺哪项省哪项；`DeviceInfo` 没有系统版本，P3d 不新增设备能力，所以版本不显示；
    - `static func popToggleTitle(popped: Bool) -> String`：「弹出为独立窗口」/「收回独立窗口」。
  - `enum MirrorStatus: Equatable { case running, connecting, popped, stopped, unauthorized, offline, failed }`（原私有的 `StatusBadge.Status`）：
    - `var title: String`：running 为「实时」，其余沿用原文案；
    - `var tone: ChipTone`：running 为 `.success`，failed 为 `.danger`，其余为 `.neutral`；
    - `static func resolve(isPresent: Bool, deviceState: DeviceState, popped: Bool, wanted: Bool, session: SessionState) -> MirrorStatus`：判断顺序同 `MirrorPane.swift:130-142`。
  - `struct MirrorHeaderBar: View { init(name: String, meta: String, status: MirrorStatus, popped: Bool, onTogglePop: @escaping () -> Void) }`：
    - 高 48，底色 `windowBackground`，底部 1 px `border`，左右内边距 16，元素间距 10；
    - 名称用 `.headerTitle`，元信息 12 `textSecondary`；
    - 状态为 `Chip(status.title, tone: status.tone, dot: status == .running)`；
    - 右侧 `.secondary` 按钮：`Label(popToggleTitle, systemImage: "arrow.up.right")`。
  - 收回动作沿用现有「收回」：先 `await model.select(id)`，再 `dismissWindow(id: "device", value: id)`。
  - `enum MirrorChrome { case plain, bezel }`；`MirrorView.init` 增加 `chrome: MirrorChrome = .plain`。`.bezel` 时：
    - `screen.aspectRatio(videoSize, contentMode: .fit).clipShape(BezelScreenShape()).phoneBezel()`，不加 `.frame(maxWidth: .infinity, maxHeight: .infinity)`，让外框与工具条一起居中；
    - `VStack(spacing: 12)` 中外框为 `layoutPriority(1)`，下面是 bar；
    - 外层 `.frame(maxWidth: .infinity, maxHeight: .infinity)`，内边距 16。
  - 若 QA 发现视频四角没被裁圆：`VideoSurfaceView` 增加 `var roundsCorners = false`，在 `layout()` 里设 `layer?.cornerRadius = BezelGeometry.innerRadius(screenWidth: bounds.width)` 并开启 `masksToBounds`，由 `VideoSurface` 在 `.bezel` 时传入 true。
  - `enum CaptureButtonsStyle { case toolbar; case videoBar(tint: Color) }`：`CaptureButtons` 的 `tint:` 参数换成 `style:`。
    - `.toolbar`：`.secondary` 按钮，内容为 `Label("截图", systemImage: "camera")` 和 `Label("录屏", systemImage: "record.circle")`；录屏中为 `Label(stopTitle, systemImage: "stop.circle.fill")`，文字与图标用 `danger`；
    - `.videoBar`：保留现有的纯图标外观（弹出窗口不变）。
  - `struct CaptureButtonsContent: View`：值类型展示视图，参数为 `style`、`canShot`、`shotBusy`、`recordingStartedAt: Date?`、`canRecord`、`isRunning`、`onShot: () -> Void`、`onRecord: () -> Void`。`CaptureButtons` 只负责从 commands / recording 取值后交给它。
  - `CaptureButtons.stopTitle(_ seconds: TimeInterval) -> String`（static）：`"停止 " + clock(seconds)`。
  - `ControlRow`：
    - 改为 `ToolbarPill`；
    - 设备有 `.keys` 能力时放返回、主页、多任务三个 30×30 `.icon` 按钮（`chevron.backward`、`circle`、`square.on.square`）；
    - 然后是 1×20 `border` 分隔线（左右外边距 4）和 `CaptureButtons(style: .toolbar)`。
  - 画布：`ZStack { Theme.canvas; DotGrid() }`；三种占位状态（已弹出 / 已停止 / 准备中）的按钮改用 `.secondary`，文字用 `.body`。

- [ ] **Step 1: 写失败测试**：

```swift
#expect(WorkspaceText.deviceMeta(platform: .android, runningSize: CGSize(width: 1080, height: 2400), connection: .usb) == "Android · 1080×2400 · USB")
#expect(WorkspaceText.deviceMeta(platform: .android, runningSize: nil, connection: .wifi) == "Android · Wi-Fi")
#expect(WorkspaceText.popToggleTitle(popped: false) == "弹出为独立窗口" && WorkspaceText.popToggleTitle(popped: true) == "收回独立窗口")
#expect(MirrorStatus.running.title == "实时" && MirrorStatus.running.tone == .success)
#expect(MirrorStatus.failed.tone == .danger && MirrorStatus.connecting.tone == .neutral)
#expect(MirrorStatus.resolve(isPresent: true, deviceState: .connected, popped: false, wanted: true, session: .running(width: 1, height: 2)) == .running)
#expect(MirrorStatus.resolve(isPresent: false, deviceState: .connected, popped: false, wanted: true, session: .running(width: 1, height: 2)) == .offline)
#expect(MirrorStatus.resolve(isPresent: true, deviceState: .connected, popped: true, wanted: true, session: .idle) == .popped)
#expect(CaptureButtons.stopTitle(65) == "停止 01:05")
```

  另写 `MirrorPaneSnapshotTests.headerCanvasBezelToolbar`，渲染 720×760：
  - 上方 `MirrorHeaderBar(name: "Pixel 8", meta: "Android · 1080×2400 · USB", status: .running, popped: false) {}`；
  - 下方为画布：`Theme.canvas` 加 `DotGrid`，中间是 `VStack(spacing: 12)`：
    - `Theme.videoBackground.aspectRatio(1080.0 / 2400, contentMode: .fit).frame(height: 520).clipShape(BezelScreenShape()).phoneBezel()`，代替 VideoSurface；
    - 一个 `ToolbarPill`，内含 3 个 icon 按钮、分隔线和 `CaptureButtonsContent(style: .toolbar, …)`，第二个 `CaptureButtonsContent` 处于录屏中；
  - 断言尺寸为 1440×1520。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/MirrorPaneTests -only-testing:TandemTests/MirrorPaneSnapshotTests`。
- [ ] **Step 3: 实现**；`MirrorPane` 传 `chrome: .bezel`，`DeviceWindowView` 传 `style: .videoBar(tint: Theme.onVideo)`。
- [ ] **Step 4: App 测试全部通过**（`InputRouterTests`、`ViewGeometryTests`、`VideoSurfaceViewTests` 不变）；对照 `Workspace.dc.html` 第 93–101 行（头部）和第 112–180 行（外框、工具条）检查快照：
  - 头部单行高 48；
  - 「实时」为绿胶囊，带圆点；
  - 外框 7 pt、#1C1C1E，圆角约为宽度的 15%，阴影柔和；
  - 工具条在外框下 12 pt，白底 85%，圆角 12；
  - 「停止 01:05」为红色。
- [ ] **Step 5: 提交**

```bash
git add App/Workspace App/DeviceWindow/MirrorView.swift App/DeviceWindow/DeviceWindowView.swift AppTests/MirrorPaneTests.swift AppTests/Snapshots/MirrorPaneSnapshotTests.swift
git commit -m "feat(workspace): device header, dotted canvas, phone bezel and floating toolbar"
```

### Task 10: 左栏、固定布局与窗口标题

**Files:**
- Modify: `App/Workspace/DeviceSidebar.swift`、`App/Workspace/WorkspaceView.swift:10-48`、`App/AppPolicy.swift`、`App/Workspace/WorkspaceText.swift`
- Test: `AppTests/AppPolicyTests.swift`、`AppTests/SidebarTests.swift`、`AppTests/Snapshots/SidebarSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 3 的 `Metrics`；Task 4 的组件；Task 9 的 `WorkspaceText`。
- Produces：
  - `AppPolicy.adjacentID(_ ids: [String], from current: String?, step: Int) -> String?`：
    - `step` 为 +1 或 -1；结果夹在首尾之间；
    - `current` 为 nil 时，+1 取第一个，-1 取最后一个；
    - `current` 不在列表里时取第一个；列表为空时返回 nil。
  - `WorkspaceText.windowTitle(deviceName: String?) -> String`：有设备时为 `"Tandem · <name>"`，否则为 `"Tandem"`。
  - `struct DeviceRowView: View { init(device: DeviceInfo, isSelected: Bool, isRecording: Bool, isPopped: Bool, isLocked: Bool, onPop: (() -> Void)?) }`：
    - 静态函数：`subtitle(_ device: DeviceInfo) -> String`，沿用 `"USB · 已连接"` 格式；`dotColor(_ state: DeviceState) -> Color`，connected 为 `success`，其余为 `dotOff`；`opacity(_ state: DeviceState) -> Double`，unauthorized 为 0.55，其余为 1；
    - 行：圆角 9，内边距 8 / 40 / 8 / 10，间距 10；
    - 内容：18 pt `iphone` 图标（`textSecondary`）；名称 13 pt，选中时 semibold；`isPopped` 时名称后加 `Chip("已弹出", tone: .accent)`；副标题行为 6 px 圆点加 11 pt 副标题；
    - 行尾小图标（`.meta` 字号）：锁定时 `lock.fill`，录屏中为 6 px `danger` 圆点；
    - 选中：底色 `card`，阴影 `shadow` 0.08 / radius 1.5 / y 1，外加 0.5 px `cardBorder` 描边；悬停：`hover`；
    - 悬停且 `onPop != nil` 时，右侧 6 pt 处出现 26×26 `.icon` 按钮（`arrow.up.right`，圆角 7）。`onPop` 只在未弹出且 `state == .connected` 时传入。
  - 左栏：
    - 头部：内边距 14 / 14 / 12，间距 10。左边是 `Image(nsImage: NSApplication.shared.applicationIconImage)`，30×30；右边是「Tandem」（14 bold）和「同驾 · 你和 AI 一起驾驶测试机」（`.meta`，`textSecondary`）。
    - 标题：`SectionHeader("设备", badge: Chip("\(count)", tone: .count))`，内边距 8 / 16。
    - 列表：`ScrollViewReader` + `ScrollView` + `LazyVStack(spacing: 2)`，左右内边距 8，右键菜单不变。
    - 键盘：列表 `.focusable().focusEffectDisabled().focused($listFocused)`。`.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)` 用 `adjacentID` 选中相邻设备，然后 `proxy.scrollTo(id)`，返回 `.handled`。点击行时选中，并设 `listFocused = true`。
    - 底部：上方 1 px `border`，内边距 10，间距 6。两个整宽、左对齐的 `.secondary` 按钮，都带 14 pt 图标：「无线配对…」（`wifi`）和 `SettingsLink` 的「设置」（`gearshape`）。
    - 背景 `sidebar`，右侧 1 px `border`（叠在宽度以内）。
  - `WorkspaceView`：
    - 不再用 `HSplitView`。结构为 `HStack(spacing: 0) { 左栏 宽 232; VStack(spacing: 0) { HStack(spacing: 0) { MirrorPane; RightColumn 宽 372 }; Rectangle(border) 高 1; BottomPanes 高 168 } }`；
    - `RightColumn` 左侧 1 px `border`（叠在宽度以内）；
    - `.frame(minWidth: Metrics.sidebarWidth + Metrics.panelWidth + Metrics.mirrorMinWidth, minHeight: 600)`，即 964；
    - `.navigationTitle(WorkspaceText.windowTitle(deviceName: 选中设备名))`，设备名取 `model.devices`，找不到时取 `lastKnownDevices`。

- [ ] **Step 1: 写失败测试**：

```swift
@Test func adjacentSelection() {
    let ids = ["a", "b", "c"]
    #expect(AppPolicy.adjacentID(ids, from: "b", step: 1) == "c")
    #expect(AppPolicy.adjacentID(ids, from: "c", step: 1) == "c")
    #expect(AppPolicy.adjacentID(ids, from: "a", step: -1) == "a")
    #expect(AppPolicy.adjacentID(ids, from: nil, step: 1) == "a")
    #expect(AppPolicy.adjacentID(ids, from: nil, step: -1) == "c")
    #expect(AppPolicy.adjacentID(ids, from: "x", step: -1) == "a")
    #expect(AppPolicy.adjacentID([], from: nil, step: 1) == nil)
}
// SidebarTests
#expect(WorkspaceText.windowTitle(deviceName: "Pixel 8") == "Tandem · Pixel 8" && WorkspaceText.windowTitle(deviceName: nil) == "Tandem")
#expect(DeviceRowView.dotColor(.connected) == Theme.success && DeviceRowView.dotColor(.unauthorized) == Theme.dotOff)
#expect(DeviceRowView.opacity(.unauthorized) == 0.55 && DeviceRowView.opacity(.offline) == 1)
#expect(DeviceRowView.subtitle(usbConnectedDevice) == "USB · 已连接")
```

  另写 `SidebarSnapshotTests.sidebar`，渲染 232×520：头部、标题（计数 3）、三行 `DeviceRowView`（选中且已弹出、录屏中且锁定、未授权）和底部；断言尺寸为 464×1040。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/AppPolicyTests -only-testing:TandemTests/SidebarTests -only-testing:TandemTests/SidebarSnapshotTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 45–87 行检查快照：
  - 左栏 #F4F4F6；
  - 选中行为白卡片；
  - 「已弹出」芯片 #EEF2FF；
  - 副标题前有 6 px 圆点；
  - 未授权行发淡；
  - 底部两个按钮上下排列、左对齐。
- [ ] **Step 5: 提交**

```bash
git add App/Workspace App/AppPolicy.swift AppTests/AppPolicyTests.swift AppTests/SidebarTests.swift AppTests/Snapshots/SidebarSnapshotTests.swift
git commit -m "feat(workspace): custom sidebar rows with keyboard selection, fixed layout and window title"
```

### Task 11: 底部两栏

**Files:**
- Modify: `App/Workspace/RecentCapturesStrip.swift`、`App/Workspace/ActivityLogView.swift`、`App/Workspace/WorkspaceView.swift:108-121`（`BottomPanes`）
- Test: `AppTests/BottomPanesTests.swift`、`AppTests/Snapshots/BottomPanesSnapshotTests.swift`

**Interfaces:**
- Consumes：Task 1 的 `thumbnailPNG`；Task 4 的组件。
- Produces：
  - `enum CaptureText { static func tileLabel(_ item: CaptureItem, timeZone: TimeZone = .current) -> String }`：`"<设备名> · HH:mm"`。
  - `enum ActivityText { static func line(_ e: ActivityEntry) -> String }`：成功为 `"<设备名> · <标题>"`，失败为 `"<设备名> · <标题>：<原因>"`。
  - `ActivitySource`：
    - `var chipTitle: String`：你 / AI；
    - `var chipTone: ChipTone`：user 为 `.accent`，ai 为 `.ai`。
  - `struct RecentTiles: View { init(items: [CaptureItem], store: CaptureStore) }` 与 `struct ActivityRows: View { init(entries: [ActivityEntry]) }`：放在 `ScrollView` 里的内容，供快照渲染。
- 最近截图：
  - 头部：高 38，左右内边距 16。`SectionHeader("最近截图")` 后跟数量（11 pt `textSecondary`），尾部是「清空」（`.link`，12 pt），列表为空时禁用。
  - 磁贴条：内边距 0 / 16 / 12，间距 12。
  - 磁贴：宽 120，竖排。
    - 截图：缩略图 aspect-fit，高 92，圆角 6，1 px `border`；
    - 录屏：112×92 `bezel` 色块，中间是 20 pt 白色 `play.fill`，右下角距右 6、距下 5 放 10 pt 等宽时长（`codeDarkText`）；
    - 下方标签：11 pt `textSecondary`，内容为 `tileLabel`。
  - 悬停：在 92 高的区域上叠一层浮层。底色 `card` 透明度 0.94，圆角 8，1 px `cardBorder`，内边距 8；里面上下两个 28 高、`.secondary` 的「拷贝」「在 Finder 中显示」。
  - 文件已删除的显示、拖出行为都保留。
  - 空列表文案：「本次会话还没有截图或录屏」，12 pt `textSecondary`。
- 操作记录：
  - 头部：`SectionHeader("操作记录")` 后跟「你和 AI 的所有操作」（11 pt `textSecondary`），尾部是「清空」（`.link`）；
  - 行（间距 6，12 pt，首行基线对齐）：时间 `HH:mm:ss`（`.monoMeta`，`textSecondary`），`Chip(source.chipTitle, tone: source.chipTone)`，然后是 `ActivityText.line`，单行，尾部省略；失败行用 `danger`；
  - 列表用 `ScrollView` + `LazyVStack`，左右内边距 16；空列表文案「暂无操作记录」。
- `BottomPanes`：
  - `HStack(spacing: 0) { RecentCapturesStrip; ActivityLogView 宽 372，左侧 1 px border }`，底色 `windowBackground`；
  - 记录栏宽度包含描边，与右栏对齐。

- [ ] **Step 1: 写失败测试**：

```swift
let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 30))!
#expect(CaptureText.tileLabel(item(name: "Pixel 8", date: date)) == "Pixel 8 · 15:30")
#expect(ActivityText.line(entry(device: "Pixel 8", title: "截图", failure: nil)) == "Pixel 8 · 截图")
#expect(ActivityText.line(entry(device: "Pixel 8", title: "截图", failure: "超时")) == "Pixel 8 · 截图：超时")
#expect(ActivitySource.user.chipTone == .accent && ActivitySource.ai.chipTone == .ai && ActivitySource.ai.chipTitle == "AI")
```

  另写 `BottomPanesSnapshotTests.bottomRow`：
  - 准备数据：
    - store 里用 `saveScreenshot(.png(AIEnv.png(width: 1080, height: 2400)))` 存一张截图；
    - 再 `addRecording`，`duration: 65`，缩略图为 `AIEnv.png(width: 480, height: 1066)`；
    - log 里写 1 条你的成功记录、1 条 AI 记录、1 条失败记录；
  - 渲染 1000×168：左边是头部加 `RecentTiles`，右边 372 宽，是头部加 `ActivityRows`；
  - 断言尺寸为 2000×336。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/BottomPanesTests -only-testing:TandemTests/BottomPanesSnapshotTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 396–470 行检查快照：
  - 底部高 168，白底；
  - 截图缩略图高 92；录屏为深色块加时长角标；
  - 标签「Pixel 8 · 15:30」；
  - 芯片：你为蓝、AI 为紫；
  - 时间为等宽字体；
  - 记录栏与右栏同宽。
- [ ] **Step 5: 提交**

```bash
git add App/Workspace AppTests/BottomPanesTests.swift AppTests/Snapshots/BottomPanesSnapshotTests.swift
git commit -m "feat(workspace): recent capture tiles and activity log rows per design"
```

### Task 12: 提示条、传输进度条、拖放遮罩

**Files:**
- Create: `App/Style/ProgressTrack.swift`
- Modify: `App/Workspace/CaptureToastView.swift`、`App/Workspace/MirrorPane.swift`、`App/DeviceWindow/MirrorView.swift`、`App/DeviceWindow/DeviceWindowView.swift:30-34`、`App/Transfers/TransferProgressBar.swift`、`App/Transfers/DropOverlay.swift`
- Test: `AppTests/ToastCenterTests.swift`、`AppTests/TransferNoticeTests.swift`、`AppTests/Snapshots/OverlaySnapshotTests.swift`

**Interfaces:**
- Consumes：Task 9 的 `MirrorChrome`、`BezelScreenShape`。
- Produces：
  - `struct ToastCountdown: Equatable`：
    - `static let total: Duration = .milliseconds(2800)`；`init()`；
    - `mutating func resume(at: ContinuousClock.Instant)`、`mutating func pause(at: ContinuousClock.Instant)`：重复调用无副作用；
    - `func remaining(at: ContinuousClock.Instant) -> Duration`：不小于 0。
  - `enum ToastText`：
    - `static func title(_ content: ToastContent) -> String`、`static func subtitle(_ content: ToastContent) -> String?`、`static func isError(_ content: ToastContent) -> Bool`；
    - 截图：标题「截图已保存」，副标题为 note，没有 note 时为文件名；
    - 录屏：标题为 note，没有时为「录屏已保存」；副标题为 `"mm:ss · <大小>"`；
    - 传输：标题与副标题为 notice 的 title / detail，`isError` 取 `notice.isError`。
  - `CaptureToastView.init(toasts:store:origin:edge: VerticalEdge = .top, onReveal:)`：
    - 卡片：最小宽 320、最大宽 560，内边距 10 / 14，圆角 12，底色 `card`，1 px `cardBorder`，阴影 `shadowDeep` 0.16 / radius 32 / y 12；
    - 左侧 22 px 圆形图标：`accent` 底，错误时 `danger` 底，白色符号；截图为 `camera.fill`，录屏为 `record.circle`，传输为 `checkmark` 或 `exclamationmark`；
    - 文字：标题 13 semibold，副标题 `.monoMeta`；
    - 尾部：截图 / 录屏有 36×36 缩略图，圆角 6，可拖出（`onDrag` 同 Task 11 的最近截图磁贴）；按钮为 `.link` 样式；
    - 计时：用 `ToastCountdown`，悬停时暂停，移开后按剩余时间继续，计时由 `.task(id: hovering)` 驱动。
  - 工作台的提示条放在 `MirrorPane` 投屏列 `overlay(alignment: .top)`，距设备头部下沿 14，`edge: .top`；弹出窗口仍在底部，`edge: .bottom`。
  - `MirrorView.init` 增加 `showsTransferBar: Bool = true`。`MirrorPane` 传 false，并在投屏列底部（`VStack` 最后，画布之下）放 `TransferProgressBar`。
  - `TransferProgressBar`：
    - `static func label(_ job: TransferJob, remaining: Int) -> String`：不再包含百分比，安装推送阶段为 `"安装 app.apk · 推送中"`；
    - `static func percentText(_ job: TransferJob) -> String`：`fraction` 为 nil 时为空字符串；
    - 视图：高 42，底色 `windowBackground`，顶部 1 px `border`，左右内边距 16，间距 12；依次为 12 pt 标签（中间省略，`layoutPriority(1)`）、`ProgressTrack`（最小宽 80）、宽 40 右对齐的 12 pt 等宽百分比、「取消」（`.link`）。
  - `struct ProgressTrack: View { let fraction: Double? }`：高 6，圆角 3，底色 `border`，填充 `accent`；nil 时不填充。
  - `DropOverlay.init(lines: [String], rounded: Bool)`：
    - 底色 `dropOverlay`（12%）；2 px 虚线 `accent` 描边，`rounded` 时用 `BezelScreenShape`，否则用直角矩形；
    - 居中一张提示卡（样式同提示条）：`square.and.arrow.down` 图标加 13 semibold 文案，文案不变；
    - `MirrorView` 在 `.bezel` 时传 `rounded: true`。

- [ ] **Step 1: 写失败测试**：

```swift
@Test func countdownPausesWhileHovering() {
    let t0 = ContinuousClock.now
    var c = ToastCountdown()
    c.resume(at: t0)
    c.pause(at: t0 + .seconds(1))
    #expect(c.remaining(at: t0 + .seconds(10)) == .milliseconds(1800))
    c.pause(at: t0 + .seconds(11))                       // 重复暂停无影响
    c.resume(at: t0 + .seconds(12))
    #expect(c.remaining(at: t0 + .milliseconds(12500)) == .milliseconds(1300))
    #expect(c.remaining(at: t0 + .seconds(60)) == .zero)
}
#expect(ToastText.title(.capture(shot, note: "64×48 · 投屏画质 · 已复制到剪贴板")) == "截图已保存")
#expect(ToastText.subtitle(.capture(shot, note: "64×48 · 投屏画质 · 已复制到剪贴板")) == "64×48 · 投屏画质 · 已复制到剪贴板")
#expect(ToastText.title(.capture(recording65s, note: nil)) == "录屏已保存")
#expect(ToastText.subtitle(.capture(recording65s, note: nil))?.hasPrefix("01:05 · ") == true)
#expect(ToastText.title(.capture(recording65s, note: "设备已断开，已保存已录制部分")) == "设备已断开，已保存已录制部分")
// TransferNoticeTests：改写原 label 期望
#expect(TransferProgressBar.label(running45, remaining: 2) == "推送 a.jpg · 还有 2 项")
#expect(TransferProgressBar.percentText(running45) == "45%")
#expect(TransferProgressBar.label(apkPushing80, remaining: 0) == "安装 app.apk · 推送中")
#expect(TransferProgressBar.percentText(job(push, .waiting)) == "")
```

  另写 `OverlaySnapshotTests.toastTransferDrop`，渲染 600×420，上下排列：
  - 一条截图提示条、一条错误传输提示条（`ToastCard` 设为 internal，或提出值类型的 `ToastCardView`）；
  - 一条 `TransferStrip`：把 `TransferProgressBar` 的展示部分提成值类型视图，参数为 `label`、`fraction`、`percent`、`onCancel`；
  - 一个 240×300 的 `DropOverlay(lines: ["松开以安装", "松开以推送到 Download"], rounded: true)`，放在 `videoBackground` 上；
  - 断言尺寸为 1200×840。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/ToastCenterTests -only-testing:TandemTests/TransferNoticeTests -only-testing:TandemTests/OverlaySnapshotTests`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: App 测试全部通过**；对照 `Workspace.dc.html` 第 573–585 行（提示条）检查快照：
  - 提示条宽 320–560、圆角 12、阴影较深；
  - 22 px 圆形图标；副标题为等宽字体；
  - 进度条为 6 px 轨道，百分比右对齐；
  - 拖放遮罩为淡蓝底、虚线框、白卡片。
- [ ] **Step 5: 提交**

```bash
git add App/Style/ProgressTrack.swift App/Workspace App/DeviceWindow App/Transfers AppTests
git commit -m "feat(workspace): top toast with hover pause, column transfer strip and drop overlay"
```

### Task 13: ROM 横幅与步骤 sheet、验收清单、同步总设计

**Files:**
- Create: `App/DeviceWindow/RomStepsSheet.swift`、`docs/superpowers/qa/p3d-manual-checklist.md`
- Modify: `App/DeviceWindow/RomBannerView.swift`、`App/AppModel.swift`（`injectDenied` 附近；`reconnect` 在 `:189-194`，`sessionLeft` 在 `:276-282`）、`App/DeviceWindow/MirrorView.swift`、`App/Workspace/MirrorPane.swift`、`App/DeviceWindow/DeviceWindowView.swift`、`App/TandemApp.swift:38-72`（`DeviceWindowHost`）
- Modify: `docs/superpowers/specs/2026-10-17-tandem-design.md`（第 86 行附近「截图两档」，第 137 行附近功能表「截图」行）
- Test: `AppTests/AppModelTests.swift`、`AppTests/RomGuideViewTests.swift`、`AppTests/Snapshots/RomSnapshotTests.swift`

**Interfaces:**
- Produces：
  - `AppModel`：
    - `private(set) var romBannerDismissed: Set<String> = []`；
    - `func dismissRomBanner(_ id: String)`；
    - `func romBanner(for id: String) -> RomGuide?`：`injectDenied` 含该 id 且未关闭时返回 `romGuides[id]`；
    - `reconnect` 与 `sessionLeft` 在移除 `injectDenied` 的同时 `romBannerDismissed.remove(id)`，即关闭只对本次投屏会话的该设备生效。
  - `RomBannerView.init(guide: RomGuide, onReconnect: @escaping () -> Void, onDismiss: @escaping () -> Void)`：
    - 一行：左右外边距 16，内边距 9 / 12，圆角 10，底色 `warnTint`，1 px `warnBorder`，字色 `warnText`，12 pt，卡片阴影；
    - 内容依次为：16 pt `exclamationmark.triangle`；文案「无法注入点击：需要额外开启调试权限」（占满剩余宽度）；`Button("查看步骤")`（`TandemButtonStyle(.link, tint: Theme.warnText)`，semibold）；22 px 圆形关闭按钮（`warnText` 透明度 0.08 底，`xmark` 10 pt）；
    - 自己持有 `@State showSteps`，用 `.sheet` 弹出 `RomStepsSheet`。
  - `struct RomStepsSheet: View { init(detected: RomGuide, onLater: @escaping () -> Void, onRecheck: @escaping () -> Void) }`：
    - `static func cards(for detected: RomGuide) -> [RomGuide]`：检测到的品牌在第一个，后面是 `forManufacturer("xiaomi")`、`("oppo")`、`("vivo")` 中品牌不同的项；
    - 布局：宽 480，内边距 22 / 24，间距 14；标题「打开输入注入权限」15 bold；
    - 每个品牌一张卡片：底色 `card`，1 px `cardBorder`，圆角 10，内边距 14；品牌名 13 semibold；步骤用 13 pt 编号列表，行距 6；
    - 脚注（11 pt `textSecondary`）：「选项名称可能随系统版本变化，以手机上的实际选项为准。其他品牌请在开发者选项中查找与「USB 调试」「模拟点击」相关的开关。」；
    - 底部靠右：`Button("稍后")`（`.secondary`）和 `Button("已打开，重新检测")`（`.primary`）。后者调用 `onRecheck`（即现有的 `model.reconnect`）并关闭 sheet。
  - `MirrorView.init` 增加 `onDismissRom: () -> Void = {}`，传给内部的 `RomBannerView`（弹出窗口用）。
  - `MirrorPane`：
    - 给 `MirrorView` 传 `romGuide: nil`；
    - `if let guide = model.romBanner(for: id)` 时，把 `RomBannerView(guide: guide, onReconnect: …, onDismiss: { model.dismissRomBanner(id) })` 放在投屏列 `overlay(alignment: .top)`，距设备头部下沿 12；
    - 同时有提示条时，提示条叠在横幅之上（`zIndex`）。
  - `DeviceWindowHost`：`romGuide: model.romBanner(for: id)`，`onDismissRom: { model.dismissRomBanner(id) }`，经 `DeviceWindowView` 传给 `MirrorView`。

- [ ] **Step 1: 写失败测试**：

```swift
// AppModelTests
@Test func romBannerDismissalLastsUntilReconnect() async {
    let (model, _) = model(backgroundLaunch: false)
    model.injectDenied.insert("a"); model.romGuides["a"] = RomGuide.forManufacturer("xiaomi")
    #expect(model.romBanner(for: "a")?.brand == "小米")
    model.dismissRomBanner("a")
    #expect(model.romBanner(for: "a") == nil)
    await model.reconnect("a")
    model.injectDenied.insert("a"); model.romGuides["a"] = RomGuide.forManufacturer("xiaomi")
    #expect(model.romBanner(for: "a") != nil)
}
// RomGuideViewTests
#expect(RomStepsSheet.cards(for: .forManufacturer("vivo")).map(\.brand) == ["vivo / iQOO", "小米", "OPPO / 一加 / realme"])
#expect(RomStepsSheet.cards(for: .forManufacturer("xiaomi")).map(\.brand) == ["小米", "OPPO / 一加 / realme", "vivo / iQOO"])
#expect(RomStepsSheet.cards(for: .forManufacturer("samsung")).map(\.brand) == ["该设备", "小米", "OPPO / 一加 / realme", "vivo / iQOO"])
```

  另写 `RomSnapshotTests.bannerAndSheet`：
  - 渲染 `RomBannerView`（宽 640、高 60，放在 `Theme.canvas` 上）；
  - 渲染 `RomStepsSheet(detected: .forManufacturer("xiaomi"))`，480×620；
  - 断言尺寸分别为 1280×120 和 960×1240。
- [ ] **Step 2: 运行确认失败**：App 测试 `-only-testing:TandemTests/AppModelTests -only-testing:TandemTests/RomGuideViewTests -only-testing:TandemTests/RomSnapshotTests`。
- [ ] **Step 3: 实现**；删掉 `RomBannerView` 里所有内联步骤。
- [ ] **Step 4: App 测试全部通过**；对照检查快照：
  - 横幅对照 `Workspace.dc.html` 第 103–110 行：单行，#FFF6E0 底，#7A5200 字；
  - sheet 对照 `RomBanner.dc.html` 第 48–75 行：品牌卡片，脚注，按钮靠右，右边一个为主按钮。
- [ ] **Step 5: 写验收清单** `docs/superpowers/qa/p3d-manual-checklist.md`：
  - 格式同 `p3c-manual-checklist.md`，每条写明步骤、预期、状态（初始为「待验证」）。
  - 截图：
    - 「截图」即时出图，提示条在 0.3 s 内出现，副标题为「1440×3040 · 投屏画质 · 已复制到剪贴板」这类格式；
    - 按住 ⌥ 点「截图」、菜单「设备 › 高清截图」、⌥⌘⇧S 都能截图，进行中「截图」按钮转圈并禁用，完成后副标题为「… · 无损 · …」；
    - 截图期间投屏不卡；
    - 连点十次只出一张图；
    - 停止投屏后截图会退回 screencap；
    - 粘贴到聊天软件和 Finder 都可用；
    - AI `screenshot` 工具的行为不变。
  - 外观（逐区域与 `Workspace.dc.html` 并排对照，浅色与深色各一遍）：
    - 窗口标题；
    - 左栏：头部、计数、选中行、悬停弹出按钮、↑ / ↓、右键菜单、锁定与录屏图标、底部按钮；
    - 设备头部：「实时」胶囊，「弹出 / 收回独立窗口」；
    - 画布点阵；手机外框四角确实裁圆（不圆就启用 Task 9 的 `roundsCorners` 备选）；
    - 点击、拖动、滚动坐标准确，尤其是靠近四角和边缘处；旋转后外框比例正确；
    - 浮动工具条；录屏时显示「停止 mm:ss」；
    - 右栏：四个标签，各分段的卡片、顺序与芯片；「恢复默认网络」；拖放区的点击选择与拖入（APK 走安装，其他文件走推送）；「查看日志」；链接芯片；自定义命令；能力概览；
    - 剪贴板页与 AI 页的开关；
    - 底部两栏的磁贴、悬停按钮、记录芯片配色；
    - 提示条：位置在顶部居中，2.8 s 后消失，悬停时暂停；
    - ROM 横幅：「查看步骤」sheet、关闭后本次会话不再出现、重连后再次出现；
    - 传输进度条在投屏列底部，不盖住画面；拖放遮罩；
    - 窗口缩到最小宽度 964 时没有挤压错位；
    - 弹出窗口：录屏、截图、底栏、ROM 横幅、提示条仍能正常使用。
  - 快照：逐个打开 `$TMPDIR/tandem-snapshots/*.png`，与对应设计稿区域对照。
- [ ] **Step 6: 同步总设计**：
  - 第 86 行改为：「**截图两档**：面板截图默认取投屏最新帧（原帧分辨率 PNG，会话没有画面时退回 screencap）；按住 ⌥ 点截图或菜单「高清截图」（⌥⌘⇧S）走 `adb exec-out screencap -p`（无损原分辨率）。AI 截图默认取最新帧，`hq=true` 时走 screencap。（2026-10-19 P3d）」；
  - 第 137 行附近功能表「截图」行的 Android 实现改为「默认投屏最新帧；高清 `exec-out screencap -p`」；
  - §2.1 的视觉一行后补「数值见 P3d 设计 §3」。
- [ ] **Step 7: 最终验证**：
  - `cd Packages/TandemCore && swift test` 全部通过；
  - App 测试（不加 `-only-testing`）全部通过；
  - `git grep -nE "\.(caption|callout|headline|subheadline)\b|buttonStyle\(\.(bordered|borderless|plain)\)|toggleStyle\(\.switch\)|pickerStyle\(\.segmented\)|roundedBorder|HSplitView" App/Workspace App/QuickActions App/Transfers/TransferProgressBar.swift App/Transfers/DropOverlay.swift App/DeviceWindow/RomBannerView.swift App/DeviceWindow/RomStepsSheet.swift` 没有输出。允许的例外只有 `CustomCommandsSection` 编辑模式的 `List`，以及弹出窗口 `.videoBar` 样式里的 `.plain` / `.borderless`。
- [ ] **Step 8: 提交**

```bash
git add App AppTests docs/superpowers/qa/p3d-manual-checklist.md docs/superpowers/specs/2026-10-17-tandem-design.md
git commit -m "feat(workspace): compact ROM banner with steps sheet; P3d QA checklist and spec sync"
```
