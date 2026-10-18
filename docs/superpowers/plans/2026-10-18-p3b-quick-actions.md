# P3b 快捷操作 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在「快捷操作」标签加入网络、应用、打开链接、开发者、系统、自定义命令六个分段，并把对应能力注册为 MCP 工具。

**Architecture:**
- **DeviceCore**：新增 6 项能力与模型类型，`DeviceActions` 增加对应方法；协议扩展给出抛 `UNSUPPORTED` 的默认实现，测试替身和 P4 iOS 只需实现用得到的部分。
- **AndroidDriver**：按领域拆分 `AndroidActions+*.swift`；命令拼装与输出解析放在纯函数命名空间 `AndroidCommands`，以真机输出为夹具单测。
- **App**：
  - `QuickActionsStore` 持久化固定包名、链接历史、自定义命令、折叠状态与 AI shell 开关；
  - 面板操作经 `DeviceCommands`（新扩展文件）→ `ActionRunner`；
  - 面板状态由 `QuickActionsModel` 按设备 id 维护；
  - AI 侧在 `AICommands` 增加不需要会话的操作路径，`ToolRegistry` 注册 13 个新工具。

**Tech Stack:** Swift 6（严格并发）、SwiftUI、Swift Testing、XcodeGen、adb。

**Spec:** `docs/superpowers/specs/2026-10-18-p3b-quick-actions-design.md`（总设计 `2026-10-17-tandem-design.md`；P2 设计 `2026-10-18-p2-mcp-design.md`）

## Global Constraints

- **工程**：最低系统 macOS 14；`SWIFT_VERSION: "6.0"`，严格并发；不引入第三方依赖；测试用 Swift Testing。
- **文件**：新增或删除 App / AppTests 下的文件后运行 `xcodegen generate`；`*.xcodeproj` 不提交。
- **测试命令**：
  - 包测试：`cd Packages/TandemCore && swift test`
  - App 测试：`xcodebuild test -project Tandem.xcodeproj -scheme Tandem -destination 'platform=macOS'`
  - 真机测试：`PATH="$HOME/Library/Android/sdk/platform-tools:$PATH" TANDEM_TEST_SERIAL=R28M31LKJ1J swift test --filter AndroidIntegrationTests`，只做可逆操作。
- **索引与调用**：adb 调用一律用 `DeviceInfo.serial`；记录、设置、状态一律按逻辑 id。
- **执行路径**：面板操作只经 `DeviceCommands` → `ActionRunner`；AI 操作只经 `AICommands` → `ActionRunner`（来源 `.ai`）；视图里不直接调用 adb 或 `DeviceActions`。
- **风格**：颜色只从 `Theme` 取；注释用中文，密度与现有代码一致；提交信息用英文 conventional commits，不加署名行。
- **照抄 spec 的值**：
  - 链接历史 20 条；自定义命令输出最多显示 200 行；shell 超时 30 秒；AI shell 输出 64 KB 截断。
  - 网络回读等待约 1.5 秒；动画倍速 0、0.5、1、2、5、10；字体 0.85、1.0、1.15、1.3。
  - App 语言下拉：跟随系统、`zh-CN`、`zh-TW`、`en`、`ja`、`ko`。
  - 包名正则 `^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$`；占位符 `{package}`。
  - shell 转义：单引号包裹，内部 `'` → `'\''`。
- **文案**：错误与记录文案照抄 spec §3.9、§4、§6。
- **工作分支**：`feat/p3b-quick-actions`。

## Review Focus

1. **注入**：包名、URL、`{package}` 替换值或 App 语言标签中含 `'`、`;`、空格、`$(...)` 时，不能拼出额外的 shell 命令。由 Task 2 的 `quoteNeutralizesInjection`、Task 6 的 `placeholderIsQuoted` 固定。
2. **经 Wi-Fi 调试的设备关闭 Wi-Fi**：会立刻断开 adb，人和 AI 都失去设备。面板必须先确认；AI 调用返回 `UNSUPPORTED`，说明会断开调试连接。由 Task 7 的 `wifiOffOverWifiNeedsConfirmation` 和 Task 10 的 `aiCannotDisableWifiOverWifi` 固定。
3. **读不到前台 App**（锁屏、桌面、系统界面）：解析返回明确错误，依赖它的按钮置灰，不能拿到错误包名后去清数据。由 Task 3 的 `foregroundUnparsableIsError` 固定。
4. **快速切换设备**：上一台设备的状态读取晚返回，不能覆盖当前设备的面板。由 Task 8 的 `staleResultDoesNotOverwriteOtherDevice` 固定。
5. **巨量输出**（`logcat -d` 一类）：面板最多显示 200 行，AI 结果截断到 64 KB 并注明。由 Task 6 的 `outputIsCappedAt200Lines` 和 Task 10 的 `shellOutputIsTruncated` 固定。

---

### Task 1: DeviceCore 模型、能力与协议

**Files:**
- Create: `Packages/TandemCore/Sources/DeviceCore/QuickActionTypes.swift`、`ShellQuote.swift`
- Modify: `Packages/TandemCore/Sources/DeviceCore/Capability.swift`、`DeviceActions.swift`、`DeviceError.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/Adb/AndroidDriver.swift`（能力集合加 6 项）
- Modify: `App/Workspace/QuickActionsTab.swift`（`Capability.title` 加 6 个中文名）
- Modify: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidDriverTests.swift`（期望的能力集合）
- Test: `Packages/TandemCore/Tests/DeviceCoreTests/QuickActionTypesTests.swift`

**Interfaces:**
- Produces:
  - `Capability` 新增 `network, apps, openURL, devOptions, systemSettings, shell`；中文名依次为 网络、应用管理、打开链接、开发者选项、系统设置、Shell
  - `public enum NetworkKind: String, Sendable, CaseIterable { case wifi, data, airplane }`
  - `public struct NetworkState: Equatable, Sendable { public var wifi: Bool?; public var data: Bool?; public var airplane: Bool?; public subscript(kind: NetworkKind) -> Bool? }`，nil 表示未知
  - `public struct AppInfo: Equatable, Sendable { public var package: String; public var activity: String?; public var versionName: String? }`
  - `public enum DevOption: Equatable, Sendable { case showTouches(Bool), layoutBounds(Bool), stayAwake(Bool), animationScale(Double); public static let animationScales: [Double] = [0, 0.5, 1, 2, 5, 10] }`
  - `public struct DevOptions: Equatable, Sendable { showTouches, layoutBounds, stayAwake: Bool?; animationScale: Double? }`
  - `public enum SystemSetting: Equatable, Sendable { case darkMode(Bool), fontScale(Double), appLocale(package: String, tag: String); public static let fontScales: [Double] = [0.85, 1.0, 1.15, 1.3] }`，`tag == ""` 表示跟随系统
  - `public struct SystemSettings: Equatable, Sendable { darkMode: Bool?; fontScale: Double?; appLocale: String?; appLocaleSupported: Bool }`
  - `public struct ShellResult: Equatable, Sendable { stdout: String; stderr: String; exitCode: Int32; timedOut: Bool }`
  - `public enum PackageName { public static func validate(_ s: String) throws -> String }`：不匹配正则时抛 `INVALID_ARGUMENT`，信息为"包名不合法：<s>"
  - `public enum ShellQuote { public static func quote(_ s: String) -> String }`
  - `DeviceError.unsupported(_ message: String) -> DeviceError`（code `.UNSUPPORTED`）
  - `DeviceActions` 新增以下方法；协议扩展中的默认实现一律 `throw DeviceError.unsupported("该设备不支持此操作")`：
    - `networkState() async throws -> NetworkState`
    - `setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState`
    - `foregroundApp() async throws -> AppInfo`
    - `launchApp(_ package: String) async throws`
    - `forceStop(_ package: String) async throws`
    - `clearData(_ package: String) async throws`
    - `uninstall(_ package: String) async throws`
    - `openURL(_ url: String) async throws`
    - `devOptions() async throws -> DevOptions`
    - `setDevOption(_ option: DevOption) async throws`
    - `systemSettings(appPackage: String?) async throws -> SystemSettings`
    - `setSystem(_ setting: SystemSetting) async throws`
    - `openSystemLocaleSettings() async throws`
    - `shell(_ command: String, timeout: Duration) async throws -> ShellResult`

- [ ] **Step 1: 写失败测试**

```swift
@Test func packageNameValidation() throws {
    #expect(try PackageName.validate("com.demo.app_1") == "com.demo.app_1")
    for bad in ["demo", "com.demo;rm -rf /", "com..demo", "com.demo'", ""] {
        #expect(throws: DeviceError.self) { try PackageName.validate(bad) }
    }
}
@Test func quoteWrapsAndEscapes() {
    #expect(ShellQuote.quote("a b") == "'a b'")
    #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
    #expect(ShellQuote.quote("") == "''")
}
@Test func networkStateSubscript() { /* NetworkState(wifi: true, data: nil, airplane: false)[.data] == nil */ }
@Test func defaultImplementationsAreUnsupported() async {
    // 只实现 screenshot / uiTree 的最小替身调用 networkState() → DeviceError.code == .UNSUPPORTED
}
```

- [ ] **Step 2: 运行确认失败**：`cd Packages/TandemCore && swift test --filter QuickActionTypesTests`。
- [ ] **Step 3: 实现**（`AndroidActions` 暂不实现新方法，走默认实现；Task 2–5 再逐个覆盖）。
- [ ] **Step 4: 运行包测试与 App 测试**，全部通过（能力概览多出 6 行）。
- [ ] **Step 5: 提交** `feat(core): quick action capabilities, models and actions protocol`

### Task 2: Android 网络

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidCommands.swift`（命名空间与 `Network`）、`AndroidActions+Network.swift`
- Modify: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions.swift`
  - init 增加 `settleDelay: Duration = .milliseconds(1500)`；
  - 新增私有 `sdkLevel() async throws -> Int`，内容为 `getprop ro.build.version.sdk`；
  - 新增私有 `shellChecked(_:)`：输出含 `Unknown command` 或 `not found` 时抛 `unsupported("该系统版本不支持此操作")`。
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidCommandsTests.swift`、`AndroidNetworkTests.swift`

**Interfaces:**
- Produces:
  - `enum AndroidCommands`（internal）
  - `AndroidCommands.Network.readCommand = "settings get global wifi_on; settings get global mobile_data; settings get global airplane_mode_on"`
  - `AndroidCommands.Network.parseState(_ out: String) -> NetworkState`：逐行解析；`"0"` 为 false，其它整数为 true，`null`、空或非数字为 nil
  - `AndroidCommands.Network.setCommand(_ kind: NetworkKind, on: Bool) -> String`：
    - wifi → `svc wifi enable` / `svc wifi disable`
    - data → `svc data enable` / `svc data disable`
    - airplane → `cmd connectivity airplane-mode enable` / `cmd connectivity airplane-mode disable`
  - `AndroidActions.networkState()`、`setNetwork(_:on:)`：
    - 飞行模式要求 sdk < 30 时抛 `unsupported("该系统版本不支持通过 shell 切换飞行模式")`；
    - 执行后 `settleDelay` 回读，目标项不等于 `on` 时抛 `DeviceError(code: .CONNECTION_FAILED, message: "设置未生效", suggestion: "部分 ROM 禁止通过 shell 修改此项，请在手机上手动设置")`；
    - 一致时返回回读状态。

- [ ] **Step 1: 写失败测试**

```swift
@Test func parsesNetworkSettings() {
    #expect(AndroidCommands.Network.parseState("1\n0\n0\n") == NetworkState(wifi: true, data: false, airplane: false))
    #expect(AndroidCommands.Network.parseState("2\nnull\n\n") == NetworkState(wifi: true, data: nil, airplane: nil))
}
@Test func quoteNeutralizesInjection() {
    // ShellQuote.quote("x'; reboot; echo '") 交给 /bin/sh -c "printf %s <quoted>" 执行，输出原样等于输入（真实 sh，本机运行）
}
@Test func setNetworkReadsBack() async throws {
    // stub shell "svc wifi disable" → ""；readCommand → "0\n1\n0"；settleDelay .zero → 返回 wifi == false
}
@Test func setNetworkMismatchFails() async {
    // readCommand 回读 wifi 仍为 "1" → CONNECTION_FAILED "设置未生效"
}
@Test func airplaneNeedsAndroid11() async {
    // getprop ro.build.version.sdk → "29" → UNSUPPORTED，且没有执行 cmd connectivity
}
```

- [ ] **Step 2: 运行确认失败**：`swift test --filter 'AndroidCommandsTests|AndroidNetworkTests'`。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 运行包测试**，全部通过。
- [ ] **Step 5: 提交** `feat(android): network state and switches with read-back`

### Task 3: Android 应用与链接

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Apps.swift`
- Modify: `AndroidCommands.swift`（`Apps`、`URL`）
- Create: `Packages/TandemCore/Tests/AndroidDriverTests/Fixtures/dumpsys-activities-samsung.txt`、`dumpsys-activities-aosp.txt`
- Test: `AndroidCommandsTests.swift`、`Packages/TandemCore/Tests/AndroidDriverTests/AndroidAppsTests.swift`

**Interfaces:**
- Produces:
  - `AndroidCommands.Apps.foregroundCommand = "dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity|^ +ResumedActivity'"`
  - `AndroidCommands.Apps.parseForeground(_ out: String) -> (package: String, activity: String)?`
    - 匹配 `u\d+ ([A-Za-z0-9_.]+)/([A-Za-z0-9_.$]+)`，取第一处；
    - 以 `.` 开头的 Activity 补全为 `包名 + Activity`。
  - `AndroidCommands.Apps.parseVersionName(_ out: String) -> String?`：取 `versionName=` 后的值
  - `AndroidCommands.Apps.parseLaunchComponent(_ out: String) -> String?`：取 `resolve-activity --brief` 输出的最后一个非空行，必须含 `/`
  - `AndroidActions.foregroundApp()`：
    - 解析不到时抛 `DeviceError(code: .CONNECTION_FAILED, message: "无法识别前台 App", suggestion: "请解锁设备并打开目标 App")`；
    - 版本名取自 `dumpsys package <pkg> | grep -m1 versionName`，读取失败时为 nil。
  - `launchApp`：
    - 执行 `cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <pkg>`，取不到组件时报"该应用没有可启动的界面"；
    - 再执行 `am start -n <component>`，输出含 `Error` 即失败，信息带上原始输出。
  - `forceStop` 执行 `am force-stop <pkg>`。
  - `clearData`、`uninstall` 分别执行 `pm clear <pkg>`、`pm uninstall <pkg>`；输出不含 `Success` 即失败，信息为"操作失败：<原始输出>"。
  - `openURL` 执行 `am start -a android.intent.action.VIEW -d <ShellQuote.quote(url)>`：
    - 输出含 `unable to resolve Intent` 时，信息为"没有应用能打开该链接"；
    - 输出含其它 `Error` 时，带原始输出。
  - 上述各方法都先用 `PackageName.validate` 校验包名。

- [ ] **Step 1: 写失败测试**
  - `parsesSamsungForeground`、`parsesAospForeground`：两个夹具都取出 `com.demo` / `com.demo.MainActivity`（其中一个夹具是 `.MainActivity` 的缩写形式）。
  - `foregroundUnparsableIsError`：锁屏或空输出时，`foregroundApp()` 抛 CONNECTION_FAILED "无法识别前台 App"。
  - `launchUsesResolvedComponent`：stub 依次为 resolve 输出 `"priority=0 preferredOrder=0\ncom.demo/.Main\n"`、am start 输出 `"Starting: Intent"` → 调用了 `am start -n com.demo/.Main`。
  - `uninstallFailureCarriesOutput`：输出 `Failure [DELETE_FAILED_INTERNAL_ERROR]` 时，message 含这段原文。
  - `openURLQuotesAndReportsUnresolvable`：URL `https://a.b/?x=1&y='z'` 被单引号转义后出现在命令中；输出含 `unable to resolve Intent` 时，报"没有应用能打开该链接"。
  - `invalidPackageIsRejectedBeforeAdb`：`clearData("x;reboot")` 抛 INVALID_ARGUMENT，且 runner 没收到任何调用。
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**。夹具用真机 `dumpsys activity activities` 的相关行，三星格式可先从 R28M31LKJ1J 只读抓取。
- [ ] **Step 4: 运行包测试**，全部通过。
- [ ] **Step 5: 提交** `feat(android): foreground app, app management and open url`

### Task 4: Android 开发者选项与系统设置

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Settings.swift`
- Modify: `AndroidCommands.swift`（`DevSettings`、`System`）
- Test: `AndroidCommandsTests.swift`、`Packages/TandemCore/Tests/AndroidDriverTests/AndroidSettingsTests.swift`

**Interfaces:**
- Produces:
  - **读取开发者选项**：`AndroidCommands.DevSettings.readCommand = "settings get system show_touches; getprop debug.layout; settings get global stay_on_while_plugged_in; settings get global window_animation_scale"`；`parse(_ out:) -> DevOptions`
    - `debug.layout` 为 `true` 时开，其余为关，空为 nil；
    - `stay_on_while_plugged_in` 非 0 为开；
    - 倍速取 Double，`null` 视为 1。
  - **修改开发者选项**：`AndroidCommands.DevSettings.setCommand(_ o: DevOption) throws -> String`
    - showTouches：`settings put system show_touches 1|0`
    - layoutBounds：`setprop debug.layout true|false; service call activity 1599295570 > /dev/null`
    - stayAwake：`settings put global stay_on_while_plugged_in 7|0`
    - animationScale：三条 `settings put global <key> <v>` 用 `; ` 连接；`v` 不在 `DevOption.animationScales` 中时抛 INVALID_ARGUMENT
  - **系统设置解析**：
    - `AndroidCommands.System.parseNight(_ out:) -> Bool?`：`Night mode: yes` 为 true，`no` 为 false，其余为 nil
    - `parseFontScale(_:) -> Double?`
    - `parseAppLocales(_:) -> String?`：`Locales for com.demo for user 0 are [zh-CN]` 取 `zh-CN`；`[]` 取 `""`
    - `setCommand(_ s: SystemSetting) throws -> String`：
      - 深色模式 `cmd uimode night yes|no`
      - 字体 `settings put system font_scale <v>`，v 须在 `fontScales` 中
      - App 语言 `cmd locale set-app-locales <pkg> --locales <ShellQuote.quote(tag)>`；tag 须为空或匹配 `^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$`，否则 INVALID_ARGUMENT
  - **`AndroidActions` 方法**：
    - `devOptions()`、`setDevOption(_:)`。
    - `systemSettings(appPackage:)`：`appLocaleSupported = sdk >= 33`；支持且给出包名时读取 `cmd locale get-app-locales <pkg>`。
    - `setSystem(_:)`：App 语言在 sdk < 33 时抛 `unsupported("该系统版本不支持设置 App 语言（需要 Android 13+）")`。
    - `openSystemLocaleSettings()`：`am start -a android.settings.LOCALE_SETTINGS`。

- [ ] **Step 1: 写失败测试**
  - `parsesDevOptions`：`"1\ntrue\n7\n0.5\n"` 解析为全开、倍速 0.5；`"null\n\n0\nnull\n"` 解析为 showTouches nil、layoutBounds nil、stayAwake false、倍速 1。
  - `animationScaleSetsAllThree`：命令包含三个 key 与值 `2`；值为 `3` 时抛 INVALID_ARGUMENT。
  - `parsesNightAndLocales`。
  - `appLocaleNeedsAndroid13`：sdk 为 32 时抛 UNSUPPORTED，且没有调用 `cmd locale`。
  - `localeTagValidated`：`zh-CN`、`en`、`""` 可用；`zh;reboot` 抛 INVALID_ARGUMENT。
- [ ] **Step 2: 运行确认失败**。
- [ ] **Step 3: 实现**。
- [ ] **Step 4: 运行包测试**，全部通过。
- [ ] **Step 5: 提交** `feat(android): developer options and system settings`

### Task 5: Android shell 与真机集成测试

**Files:**
- Create: `Packages/TandemCore/Sources/AndroidDriver/AndroidActions+Shell.swift`
- Test: `Packages/TandemCore/Tests/AndroidDriverTests/AndroidShellTests.swift`、`AndroidIntegrationTests.swift`

**Interfaces:**
- Produces：`AndroidActions.shell(_ command:timeout:)`
  - 执行 `adb -s <serial> shell timeout <整秒> sh -c <ShellQuote.quote(command)>`：设备端 `timeout` 负责超时，到点也能拿到部分输出；本机 runner 的超时为设备超时加 5 秒，作为兜底。
  - 不按退出码抛错，原样返回 `ShellResult`；退出码 124 时 `timedOut = true`。
  - 本机兜底超时触发时抛 `DeviceError.timeout("shell 命令")`。

- [ ] **Step 1: 写失败测试**
  - `shellWrapsWithDeviceTimeout`：命令是 `echo 'hi'`，30 秒超时时，参数为 `["-s","S","shell","timeout","30","sh","-c","'echo '\\''hi'\\'''"]`。
  - `nonZeroExitIsReturnedNotThrown`：退出码 2、stderr 为 `"x"`，返回 `exitCode == 2`。
  - `exit124IsTimedOut`。
- [ ] **Step 2: 真机集成测试**（`AndroidIntegrationTests`，有 `TANDEM_TEST_SERIAL` 时运行；结束时一律恢复原状，失败也要恢复，用 `defer` 或 do/catch）：
  - `networkStateReadable`：三项中至少一项不为 nil。
  - `wifiToggleRoundTrip`：serial 含 `:` 时直接 return；否则先关 Wi-Fi 再开，两次回读都符合期望。
  - `foregroundAppReadable`：解锁亮屏时包名非空；无法识别时记录 `Issue` 并说明原因，不硬失败。
  - `showTouchesRoundTrip`。
  - `darkModeRoundTrip`。
  - `shellEcho`：`echo tandem` 的输出为 `"tandem\n"`，退出码 0。
- [ ] **Step 3: 实现**，运行包测试，再在真机 R28M31LKJ1J 上跑集成测试，全部通过。
- [ ] **Step 4: 提交** `feat(android): device shell with timeout and quick action integration tests`

### Task 6: QuickActionsStore

**Files:**
- Create: `App/QuickActions/QuickActionsStore.swift`
- Test: `AppTests/QuickActionsStoreTests.swift`

**Interfaces:**
- Consumes：Task 1 的 `ShellQuote`、`PackageName`。
- Produces:
  - `struct CustomCommand: Codable, Identifiable, Equatable { let id: UUID; var name: String; var command: String; var needsPackage: Bool { command.contains("{package}") }; func render(package: String?) throws -> String }`：缺包名时抛 `DeviceError(code: .INVALID_ARGUMENT, message: "该命令需要目标 App")`；包名经 `PackageName.validate` 后用 `ShellQuote.quote` 替换。
  - `@MainActor @Observable final class QuickActionsStore`：`init(defaults: UserDefaults)`，状态与操作如下：
    - `pinnedPackages: [String]`：`pin(_:)` 去重并追加；`unpin(_:)`
    - `urlHistory: [String]`：`recordURL(_:)` 把该 URL 移到最前，最多 20 条；`removeURL(_:)`
    - `commands: [CustomCommand]`：`addCommand(name:command:)`、`updateCommand(_:)`、`removeCommand(id:)`、`moveCommands(from: IndexSet, to: Int)`
    - `collapsedSections: Set<String>`：`toggleSection(_:)`
    - `allowAIShell: Bool`，默认 true
    - 每项都写入 UserDefaults，键为 `quickActions.pinned`、`.urlHistory`、`.commands`（JSON 编码）、`.collapsed`、`.allowAIShell`
  - `static func cappedOutput(_ s: String, maxLines: Int = 200) -> String`：超过上限时保留前 200 行，并追加 `…（共 N 行，已省略 M 行）`

- [ ] **Step 1: 写失败测试**
  - `pinsDeduplicateAndPersist`
  - `urlHistoryKeeps20MostRecentFirst`
  - `commandsPersistAndReorder`
  - `allowAIShellDefaultsTrue`
  - `placeholderIsQuoted`：命令 `am force-stop {package}`，包名 `com.demo` 渲染为 `am force-stop 'com.demo'`；包名 `x';reboot` 抛 INVALID_ARGUMENT；缺包名抛「该命令需要目标 App」
  - `outputIsCappedAt200Lines`：输入 250 行，输出 200 行再加一行省略说明
- [ ] **Step 2: 运行确认失败**；**Step 3: 实现**；**Step 4: App 测试通过**。
- [ ] **Step 5: 提交** `feat(app): quick actions store for pins, links, commands and settings`

### Task 7: DeviceCommands 快捷操作入口

**Files:**
- Create: `App/Actions/DeviceCommands+QuickActions.swift`
- Modify: `App/Actions/DeviceCommands.swift`（`runner`、`device`、`actions` 由 `private let` 改为 `let`，供扩展文件使用；注释说明）
- Create: `AppTests/Support/RecordingActions.swift`（`final class RecordingActions: DeviceActions, @unchecked Sendable`：记录每次调用的方法名与参数，各方法的返回值或错误可配置）
- Test: `AppTests/DeviceCommandsQuickTests.swift`

**Interfaces:**
- Consumes：Task 1 的类型与方法；Task 6 的 `CustomCommand`。
- Produces（扩展方法；读取不写记录，修改经 `runner.perform` 写记录，来源「你」）：
  - **读取**：
    - `func readNetwork(_ id: String) async -> Result<NetworkState, DeviceError>`
    - `func readForegroundApp(_ id: String) async -> Result<AppInfo, DeviceError>`
    - `func readDevOptions(_ id: String) async -> Result<DevOptions, DeviceError>`
    - `func readSystem(_ id: String, appPackage: String?) async -> Result<SystemSettings, DeviceError>`
    - 读取时非 `DeviceError` 的错误包装为 CONNECTION_FAILED。
  - **网络**：`func setNetwork(_ id: String, _ kind: NetworkKind, on: Bool) async -> NetworkState?`，title 如 `打开 Wi-Fi`、`关闭移动数据`、`开启飞行模式`
  - **应用**：
    - `enum AppAction { case launch, forceStop, clearData, restart, uninstall }`，title 依次为 `启动 / 强停 / 清数据 / 重启 / 卸载 <pkg>`
    - `func appAction(_ id: String, _ action: AppAction, package: String) async -> Bool`；restart = forceStop 后 launch
  - **链接**：`func openURL(_ id: String, _ url: String, store: QuickActionsStore) async -> Bool`，title `打开链接 <url>`；成功后 `store.recordURL`
  - **开发者 / 系统**：
    - `func setDevOption(_ id: String, _ o: DevOption) async -> Bool`，title 如 `显示触摸点：开`、`动画倍速：0.5x`
    - `func setSystem(_ id: String, _ s: SystemSetting) async -> Bool`，title 如 `深色模式：开`、`字体大小：1.15`、`App 语言 com.demo：zh-CN`
    - `func openSystemLocaleSettings(_ id: String) async`
  - **自定义命令**：`func runCustom(_ id: String, _ c: CustomCommand, package: String?) async -> ShellResult?`，title `执行：<名称>`；退出码非 0 或超时记为失败，failure 文案为 `退出码 n` 或 `超时`，但仍返回结果，供界面显示输出
  - **Wi-Fi 确认**：`static func needsWifiConfirmation(_ device: DeviceInfo, kind: NetworkKind, on: Bool) -> Bool`，条件为 `device.connection == .wifi && kind == .wifi && !on`

- [ ] **Step 1: 写失败测试**
  - `setNetworkLogsTitle`
  - `restartStopsThenLaunches`：调用序列为 `["forceStop com.demo", "launchApp com.demo"]`
  - `openURLRecordsHistoryOnSuccessOnly`
  - `customCommandFailureStillReturnsOutput`
  - `readsDoNotLog`
  - `wifiOffOverWifiNeedsConfirmation`：Wi-Fi 连接的设备关 Wi-Fi 为 true；USB 设备为 false；打开为 false
- [ ] **Step 2–4**：运行确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): device commands for quick actions`

### Task 8: 面板（一）：分段框架、网络、应用、打开链接

**Files:**
- Create: `App/QuickActions/QuickActionsModel.swift`、`App/QuickActions/QuickSection.swift`、`App/QuickActions/NetworkSection.swift`、`App/QuickActions/AppsSection.swift`、`App/QuickActions/OpenURLSection.swift`
- Modify: `App/Workspace/QuickActionsTab.swift`（改为：分段列表在上，「设备能力」在最下）、`App/AppServices.swift`（创建并持有 `quickStore: QuickActionsStore` 与 `quickModel: QuickActionsModel`）
- Test: `AppTests/QuickActionsModelTests.swift`

**Interfaces:**
- Consumes：Task 6、7。
- Produces：
  - `enum AppTarget: Hashable { case foreground, pinned(String) }`
  - `@MainActor @Observable final class QuickActionsModel`：
    - `init(commands: DeviceCommands, store: QuickActionsStore)`
    - 按设备 id 保存的状态：`network: [String: Result<NetworkState, DeviceError>]`、`foreground: [String: Result<AppInfo, DeviceError>]`、`devOptions`、`system`、`target: [String: AppTarget]`、`busy: Set<String>`（键 `"<id>.<section>"`）、`lastOutput: [String: [UUID: ShellResult]]`（设备 id → 命令 id → 输出）
    - `func targetPackage(_ id: String) -> String?`：`.foreground` 取前台 App 读取成功时的包名，`.pinned(p)` 取 p
    - 刷新：`func refreshAll(_ id: String) async`、`func refresh(_ id: String, section: QuickSectionID) async`
    - 每次读取结果写入**发起时**的 id 下；视图只读取当前选中 id 的条目
  - `enum QuickSectionID: String, CaseIterable { case network, apps, openURL, devOptions, system, custom }`，每项有中文标题和所需 `Capability`
  - `QuickSection`：带折叠（`store.collapsedSections`）、右上角刷新按钮、能力不足时整体置灰并显示「该设备不支持」的容器视图

- [ ] **Step 1: 写失败测试**（`QuickActionsModel` 用 `RecordingActions`）
  - `targetPackageFollowsSelection`
  - `staleResultDoesNotOverwriteOtherDevice`：设备 A 的网络读取挂起；切换并刷新 B；A 晚返回后只写入 `network["A"]`，`network["B"]` 不受影响
  - `refreshAllReadsEachSupportedSection`：没有某项能力的分段不读取
- [ ] **Step 2–4**：运行确认失败 → 实现模型 → 测试通过。
- [ ] **Step 5: 视图**（spec §3.1–§3.5）：
  - **网络**：三个 Toggle，绑定回读值，切换中显示 `ProgressView`；`needsWifiConfirmation` 为真时先弹 `.confirmationDialog`「关闭 Wi-Fi 会断开与设备的无线调试连接」。
  - **应用**：目标 Picker（「前台 App」加已固定包名，每项可移除）；前台行显示包名与版本，带「📌 固定」；五个按钮在无目标包名时置灰；「卸载」先弹 `.alert`，标题「卸载 <pkg>？」，正文「卸载后应用数据不可恢复」，按钮「卸载」为 destructive。
  - **打开链接**：TextField 加「打开」，`onSubmit` 也会打开；下方是历史列表，点击打开，悬停出现删除按钮。
  - 标签出现、选中设备变化时调用 `refreshAll`。
- [ ] **Step 6: App 测试通过**；**Step 7: 提交** `feat(app): quick actions panel with network, apps and links`

### Task 9: 面板（二）：开发者、系统、自定义命令

**Files:**
- Create: `App/QuickActions/DevOptionsSection.swift`、`SystemSection.swift`、`CustomCommandsSection.swift`、`CustomCommandEditor.swift`
- Modify: `App/Workspace/QuickActionsTab.swift`、`App/QuickActions/QuickActionsModel.swift`（如需新增 setter 包装）

**Interfaces:**
- Consumes：Task 6–8。

- [ ] **Step 1: 开发者**：三个 Toggle 加「动画倍速」Picker（关、0.5x、1x、2x、5x、10x，对应 0、0.5、1、2、5、10）；修改后重新读取该分段。
- [ ] **Step 2: 系统**：
  - 「深色模式」Toggle；
  - 「字体大小」Picker（小、默认、大、特大）；
  - 「App 语言」Picker：跟随系统、简体中文（zh-CN）、繁體中文（zh-TW）、English（en）、日本語（ja）、한국어（ko），作用于 `targetPackage`；无目标或 `!appLocaleSupported` 时置灰，`.help("需要 Android 13+")` 或「请先在「应用」分段选择目标」；
  - 「打开系统语言设置」按钮。
- [ ] **Step 3: 自定义命令**：
  - 按钮列表：含 `{package}` 且无目标包名时置灰；点击执行时按钮显示进度；
  - 结果显示在按钮下方的等宽框里，内容为 `QuickActionsStore.cappedOutput(stdout + stderr)`，带「拷贝」；失败时标题行标红并显示退出码；
  - 「编辑」切换为 `List` 加 `.onMove` 排序、删除；「添加」打开 `CustomCommandEditor` sheet，含名称和命令两个输入框，并提示「可用 {package} 表示「应用」分段选中的包名」；
  - 列表为空时显示示例提示。
- [ ] **Step 4: 手动构建检查**：`xcodegen generate && xcodebuild build …` 成功，App 测试通过。
- [ ] **Step 5: 提交** `feat(app): developer, system and custom command sections`

### Task 10: AICommands 快捷操作

**Files:**
- Modify: `App/AI/AICommands.swift`：`act` 新增参数 `needsSession: Bool = true`；`needsSession == false` 时跳过 `runningSession`，body 不再接收会话参数。可以拆成两个私有函数，共用锁定和排队逻辑。
- Create: `App/AI/AICommands+QuickActions.swift`
- Test: `AppTests/AICommandsQuickTests.swift`

**Interfaces:**
- Consumes：Task 1 的类型；`deviceActions(_:)`、`run`、`act`（已有）。
- Produces（都返回给 AI 的文本；感知类经 `run(..., logSuccess: false)`，操作类经 `act(..., needsSession: false)`）：
  - `currentApp(_:)`：返回 `包名\nActivity: …\n版本: …`
  - `launchApp(_:package:)`、`forceStop(_:package:)`、`clearAppData(_:package:)`、`uninstallApp(_:package:)`、`openURL(_:url:)`
  - `networkState(_:)`：返回 `wifi: on|off|unknown` 等三行
  - `setNetwork(_:kind:on:)`：返回回读后的三行状态
  - `devOptions(_:)`、`setDevOption(_:_:)`
  - `systemSettings(_:package:)`、`setSystem(_:_:)`
  - `shell(_:command:)`：
    - 超时 30 秒；
    - 输出格式为 `exit: n` 加 stdout，stderr 非空时追加 `--- stderr ---` 段；
    - 总长超过 64 KB 时截断并追加 `…（输出已截断，共 N 字节）`；
    - `timedOut` 时抛 `TIMEOUT`，message 为 `shell 命令超时`，suggestion 带前 2 KB 的部分输出。
  - **AI 不能断开 Wi-Fi 调试**：设备 `connection == .wifi` 且 `kind == .wifi && !on` 时，抛 `unsupported("设备经 Wi-Fi 调试连接，关闭 Wi-Fi 会断开连接")`。
  - **记录标题**：`current_app`、`launch_app <pkg>`、`force_stop <pkg>`、`clear_app_data <pkg>`、`uninstall_app <pkg>`、`open_url <url>`、`set_network <kind> on|off`、`set_dev_option <option> <value>`、`set_system <setting> <value>`、`shell <命令前 80 字>`

- [ ] **Step 1: 写失败测试**（`AIEnv` 加 `RecordingActions`）
  - `quickActionsDoNotStartSessions`：`acquire` 未被调用
  - `lockedQuickActionIsRejected`：锁定后 `clearAppData` 抛 AI_LOCKED，`currentApp` 照常返回
  - `aiCannotDisableWifiOverWifi`
  - `shellOutputIsTruncated`：输出 70 KB，结果 ≤ 64 KB 并含"已截断"
  - `shellTimeoutCarriesPartialOutput`
  - `shellTitleHasCommand`
- [ ] **Step 2–4**：运行确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): ai quick action commands`

### Task 11: ToolRegistry 新工具与 shell 开关

**Files:**
- Modify: `App/AI/ToolRegistry.swift`：新增 13 个工具；init 增加 `allowShell: @escaping () -> Bool = { true }`
- Modify: `App/AI/ControlServer.swift`：新增 `func toolsChanged()`，用上次的设备列表重新计算工具名单，变化时推送 `tools/list_changed`；记住 `devicesChanged` 传入的列表
- Modify: `App/AppServices.swift`：`allowShell` 取自 `quickStore.allowAIShell`；该值变化时调用 `server.toolsChanged()`（在设置页 Toggle 的 setter 里调用 `AppServices.setAllowAIShell(_:)`）
- Modify: `App/Settings/SettingsView.swift`：新增 Toggle「允许 AI 执行 shell 命令」；`SettingsView` 需要接收 `services`，或者一个绑定加回调
- Test: `AppTests/ToolRegistryQuickTests.swift`、`AppTests/ControlServerTests.swift`（新增一条）

**Interfaces:**
- Consumes：Task 10。
- Produces：工具名、参数、类别和能力照抄 spec §4 的表。
  - **参数**：
    - `package` 为 string，`clear_app_data` / `uninstall_app` 必填；`launch_app` / `force_stop` 也必填（spec §4 表中参数均为 `package`，不提供默认值）。
    - `set_network`：`kind` 为 enum，`on` 为 boolean。
    - `set_dev_option`：`option` 为 enum，`value` 为 `{"type": ["boolean","number"]}`，按 option 校验类型与取值。
    - `set_system`：`setting` 为 enum，`value` 为 `["boolean","number","string"]`；`package` 在 `app_locale` 时必填。
    - `get_system_settings`：`package?`。
    - `shell`：`command` 必填且非空。
  - **shell 开关**：`allowShell()` 为 false 时，`descriptors` 不含 `shell`；调用 `shell` 返回 `ToolResult.failure(code: "UNSUPPORTED", message: "已在 Tandem 设置中关闭", suggestion: nil)`。

- [ ] **Step 1: 写失败测试**
  - `newToolsListedInSpecOrder`：工具名依次追加在 P2 的 12 个之后，顺序为 `current_app, launch_app, force_stop, clear_app_data, uninstall_app, open_url, get_network_state, set_network, get_dev_options, set_dev_option, get_system_settings, set_system, shell`
  - `devOptionValueValidated`：`animation_scale` 传 `true` → INVALID_ARGUMENT；`show_touches` 传 `2` → INVALID_ARGUMENT
  - `appLocaleNeedsPackage`
  - `shellHiddenAndRejectedWhenDisabled`
  - ControlServerTests 的 `toolsChangedPushesWhenShellToggled`：通过 MCPBridge 收到 `notifications/tools/list_changed`
- [ ] **Step 2–4**：运行确认失败 → 实现 → App 测试通过。
- [ ] **Step 5: 提交** `feat(app): quick action mcp tools and shell permission`

### Task 12: 验收清单与最终验证

**Files:**
- Create: `docs/superpowers/qa/p3b-manual-checklist.md`

- [ ] **Step 1: 验收清单**：照抄 spec §7 的人工验收项，并逐个分段加入检查：
  - 网络开关回读，Wi-Fi 调试设备关 Wi-Fi 时的确认框；
  - 应用目标切换与固定、五个按钮、卸载确认框；
  - 链接历史；
  - 开发者与系统各项；App 语言在 Android 13 以下置灰；
  - 自定义命令的添加、编辑、排序、`{package}` 和输出；
  - 分段折叠在重启后保留；
  - 深色模式下的面板；
  - 通过 MCP 调用全部新工具，包括锁定时的表现和 shell 开关。

  每条写明步骤、预期结果、状态（初始为「待验证」）。
- [ ] **Step 2: 最终验证**：
  - `cd Packages/TandemCore && swift test` 全部通过；
  - 真机：`PATH=… TANDEM_TEST_SERIAL=R28M31LKJ1J swift test --filter AndroidIntegrationTests` 全部通过；
  - `xcodegen generate && xcodebuild test …` 全部通过；
  - `adb forward --list` 无残留的 `scrcpy_`。
- [ ] **Step 3: 提交** `docs: P3b manual QA checklist`
