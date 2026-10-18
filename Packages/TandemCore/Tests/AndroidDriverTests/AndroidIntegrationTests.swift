import AVFoundation
import Foundation
import ImageIO
import Testing
import DeviceCore
import MediaKit
@testable import AndroidDriver

/// 真机集成测试：仅在设置 TANDEM_TEST_SERIAL 时运行，否则整组显示为 skipped。
/// scrcpy-server 路径取 TANDEM_SCRCPY_SERVER，默认仓库内 App/Resources/Vendor/scrcpy-server-v5.0.1。
/// 串行执行：多个用例各自起会话，并行会互相影响端口转发检查。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TANDEM_TEST_SERIAL"] != nil))
struct AndroidIntegrationTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func scrcpyForwards(_ client: AdbClient) async throws -> [String] {
        let result = try await client.run(["forward", "--list"])
        return result.stdoutString.split(whereSeparator: \.isNewline)
            .map(String.init).filter { $0.contains("scrcpy_") }
    }

    private func waitForRunning(_ session: any DeviceSession) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in session.events {
                    if case .state(.running) = event { return true }
                    if case .state(.failed) = event { return false }
                }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func endToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = try #require(env["TANDEM_TEST_SERIAL"])
        let jar = env["TANDEM_SCRCPY_SERVER"].map { URL(fileURLWithPath: $0) }
            ?? Self.repoRoot.appendingPathComponent("App/Resources/Vendor/scrcpy-server-v5.0.1")
        let bundledAdb = Self.repoRoot.appendingPathComponent("App/Resources/Vendor/adb")

        let runner = SystemProcessRunner()
        let adb = try await AdbLocator(
            runner: runner,
            environment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: bundledAdb
        ).locate()
        let client = AdbClient(adb: adb, runner: runner)
        let forwardsBefore = try await scrcpyForwards(client)

        let device = DeviceInfo(serial: serial, platform: .android, name: serial, state: .connected, connection: .usb)
        let driver = AndroidDriver(adb: client, runner: runner, serverJar: jar)
        let session = driver.makeSession(for: device)

        // 先订阅 events（AsyncStream 会缓冲），再启动。
        async let running = waitForRunning(session)
        await session.start()
        #expect(await running, "10 秒内应收到 .running")

        var frame = session.latestFrame()
        for _ in 0..<50 where frame == nil {
            try await Task.sleep(for: .milliseconds(100))
            frame = session.latestFrame()
        }
        #expect(frame != nil, "5 秒内应有画面")

        do {
            try await session.setClipboard("tandem-测试", paste: false)
            #expect(try await session.getClipboard() == "tandem-测试")
            await session.send(.key(.home))
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
        let forwardsAfter = try await scrcpyForwards(client)
        #expect(Set(forwardsAfter) == Set(forwardsBefore), "stop 后不应残留 scrcpy 端口转发：\(forwardsAfter)")
    }

    @Test func screenshotIsDeviceResolutionPNG() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = try #require(env["TANDEM_TEST_SERIAL"])
        let runner = SystemProcessRunner()
        let adb = try await AdbLocator(
            runner: runner,
            environment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: Self.repoRoot.appendingPathComponent("App/Resources/Vendor/adb")
        ).locate()
        let client = AdbClient(adb: adb, runner: runner)

        let png = try await AndroidActions(serial: serial, adb: client).screenshot()
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let h = try #require(props[kCGImagePropertyPixelHeight] as? Int)

        // 解析 `wm size` 的 Physical size 行（可能还有 Override size，截图取物理分辨率）。
        let out = try await client.shell(serial, "wm size")
        let line = try #require(out.split(whereSeparator: \.isNewline).first { $0.contains("Physical size") })
        let dims = try #require(line.split(separator: ":").last)
            .trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) }
        #expect(dims.count == 2)
        #expect(([w, h] == dims) || ([h, w] == dims), "截图 \(w)x\(h) 应等于 \(dims)（允许横竖互换）")
    }

    @Test func recordsTwoSecondsFromSession() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = try #require(env["TANDEM_TEST_SERIAL"])
        let jar = env["TANDEM_SCRCPY_SERVER"].map { URL(fileURLWithPath: $0) }
            ?? Self.repoRoot.appendingPathComponent("App/Resources/Vendor/scrcpy-server-v5.0.1")
        let runner = SystemProcessRunner()
        let adb = try await AdbLocator(
            runner: runner,
            environment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: Self.repoRoot.appendingPathComponent("App/Resources/Vendor/adb")
        ).locate()
        let client = AdbClient(adb: adb, runner: runner)
        let device = DeviceInfo(serial: serial, platform: .android, name: serial, state: .connected, connection: .usb)
        let session = AndroidDriver(adb: client, runner: runner, serverJar: jar).makeSession(for: device)

        async let running = waitForRunning(session)
        await session.start()
        guard await running else {
            await session.stop()
            Issue.record("10 秒内应收到 .running")
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rec-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CanvasRecorder(url: url)
        let token = session.addFrameObserver { recorder.append($0) }
        try? await Task.sleep(for: .seconds(2))
        session.removeFrameObserver(token)
        let result = await Result { try await recorder.finish() }
        await session.stop()

        let summary = try result.get()
        let duration = try await AVURLAsset(url: summary.url).load(.duration).seconds
        #expect((1.5...2.5).contains(duration), "录制时长 \(duration) 秒应在 1.5…2.5 之间")
        #expect(summary.fileSize > 0 && summary.thumbnailPNG != nil)
    }

    @Test func uiTreeRootMatchesScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = try #require(env["TANDEM_TEST_SERIAL"])
        let runner = SystemProcessRunner()
        let adb = try await AdbLocator(
            runner: runner,
            environment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: Self.repoRoot.appendingPathComponent("App/Resources/Vendor/adb")
        ).locate()
        let client = AdbClient(adb: adb, runner: runner)
        let tree = try await AndroidActions(serial: serial, adb: client).uiTree()
        let size = try await client.shell(serial, "wm size")
        // 与 UI 树一致：Override size（若有）优先于 Physical size。
        let lines = size.split(whereSeparator: \.isNewline)
        let physical = try #require(lines.first { $0.contains("Override size") } ?? lines.first { $0.contains("Physical size") })
        let dims = physical.split(separator: ":").last!.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Double($0) }
        #expect(dims.count == 2)
        #expect(Set(dims) == Set([Double(tree.screen.width), Double(tree.screen.height)]))
        #expect(!tree.elements.isEmpty)
    }

    // MARK: - 快捷操作（均为可逆操作，结束时恢复读到的原值）

    private func realActions() async throws -> (serial: String, actions: AndroidActions) {
        let env = ProcessInfo.processInfo.environment
        let serial = try #require(env["TANDEM_TEST_SERIAL"])
        let runner = SystemProcessRunner()
        let adb = try await AdbLocator(
            runner: runner,
            environment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: Self.repoRoot.appendingPathComponent("App/Resources/Vendor/adb")
        ).locate()
        return (serial, AndroidActions(serial: serial, adb: AdbClient(adb: adb, runner: runner)))
    }

    @Test func networkStateReadable() async throws {
        let (_, actions) = try await realActions()
        let s = try await actions.networkState()
        #expect(s.wifi != nil || s.data != nil || s.airplane != nil, "三项网络状态至少应有一项可读：\(s)")
    }

    @Test func wifiToggleRoundTrip() async throws {
        let (serial, actions) = try await realActions()
        // 无线调试连接时（ip:port 或 mDNS 名）关 Wi-Fi 会断线，直接跳过。
        if DeviceListParser.connectionKind(serial: serial) == .wifi { return }
        let original = try #require(try await actions.networkState().wifi, "无法读取 Wi-Fi 原状态")
        do {
            let flipped = try await actions.setNetwork(.wifi, on: !original)
            #expect(flipped.wifi == !original)
            let back = try await actions.setNetwork(.wifi, on: original)
            #expect(back.wifi == original)
        } catch {
            _ = try? await actions.setNetwork(.wifi, on: original)
            throw error
        }
        #expect(try await actions.networkState().wifi == original)
    }

    @Test func foregroundAppReadable() async throws {
        let (_, actions) = try await realActions()
        do {
            let app = try await actions.foregroundApp()
            #expect(!app.package.isEmpty)
        } catch {
            Issue.record("无法识别前台应用（可能锁屏或熄屏）：\(error)")
        }
    }

    @Test func showTouchesRoundTrip() async throws {
        let (_, actions) = try await realActions()
        let original = try #require(try await actions.devOptions().showTouches, "无法读取 show_touches 原值")
        do {
            try await actions.setDevOption(.showTouches(!original))
            #expect(try await actions.devOptions().showTouches == !original)
        } catch {
            try? await actions.setDevOption(.showTouches(original))
            throw error
        }
        try await actions.setDevOption(.showTouches(original))
        #expect(try await actions.devOptions().showTouches == original)
    }

    @Test func darkModeRoundTrip() async throws {
        let (_, actions) = try await realActions()
        let original = try #require(try await actions.systemSettings(appPackage: nil).darkMode, "无法读取深色模式原值")
        do {
            try await actions.setSystem(.darkMode(!original))
            #expect(try await actions.systemSettings(appPackage: nil).darkMode == !original)
        } catch {
            try? await actions.setSystem(.darkMode(original))
            throw error
        }
        try await actions.setSystem(.darkMode(original))
        #expect(try await actions.systemSettings(appPackage: nil).darkMode == original)
    }

    @Test func shellEcho() async throws {
        let (_, actions) = try await realActions()
        let r = try await actions.shell("echo tandem", timeout: .seconds(30))
        #expect(r.stdout == "tandem\n")
        #expect(r.exitCode == 0)
    }

    // MARK: - 文件（adb sync）

    @Test func fileRoundTrip() async throws {
        let (_, actions) = try await realActions()
        let remote = "/sdcard/Download/tandem_test_\(UUID().uuidString).bin"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.bin")
        let payload = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: source)

        do {
            try await actions.push(source, to: remote, progress: { _ in })
            let info = try #require(try await actions.stat(remote))
            #expect(info.size == 1024)
            let back = dir.appendingPathComponent("back.bin")
            try await actions.pull(remote, to: back, progress: { _ in })
            #expect(try Data(contentsOf: back) == payload)
        } catch {
            _ = try? await actions.shellChecked("rm -f \(ShellQuote.quote(remote))")
            throw error
        }
        _ = try await actions.shellChecked("rm -f \(ShellQuote.quote(remote))")
        #expect(try await actions.stat(remote) == nil)
    }

    @Test func listSdcard() async throws {
        let (_, actions) = try await realActions()
        let names = try await actions.listDirectory("/sdcard").map(\.name)
        #expect(names.contains("Download"))
    }

    // MARK: - 安装与媒体扫描

    @Test func installAndUninstallTestApk() async throws {
        let (serial, actions) = try await realActions()
        let apk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tandem-test.apk")
        let package = "dev.tandem.testapp"
        let installed: String?
        do {
            installed = try await actions.install(apk: apk, progress: { _ in })
        } catch {
            _ = try? await actions.shellChecked("pm uninstall \(package)")
            throw error
        }
        defer { Task.detached { _ = try? await actions.shellChecked("pm uninstall \(package)") } }
        #expect(installed == package)
        let listed = try await actions.shellChecked("pm list packages \(package)").stdout
        #expect(listed.contains("package:\(package)"))
        _ = try await actions.shellChecked("pm uninstall \(package)", timeout: .seconds(30))
        let after = try await actions.shellChecked("pm list packages \(package)").stdout
        #expect(!after.contains(package), "卸载后不应残留（serial \(serial)）")
    }

    /// 推送一张 PNG 到 Pictures，扫描后应进入 MediaStore；删除并再次扫描后应移出。
    @Test func mediaScanAddsAndRemovesImage() async throws {
        let (_, actions) = try await realActions()
        let remote = "/sdcard/Pictures/tandem_scan_test.png"
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent("tandem_scan_test.png")
        try png.write(to: local)
        let query = "content query --uri content://media/external/images/media --projection _data --where \"_data LIKE '%tandem_scan_test%'\""
        func inStore() async throws -> Bool {
            try await actions.shellChecked(query).stdout.contains("tandem_scan_test")
        }
        func cleanup() async {
            _ = try? await actions.shellChecked("rm -f \(ShellQuote.quote(remote))")
            try? await actions.mediaScan([remote])
        }
        do {
            try await actions.push(local, to: remote, progress: { _ in })
            try await actions.mediaScan([remote])
            var found = false
            for _ in 0..<10 where !found {
                found = try await inStore()
                if !found { try await Task.sleep(for: .milliseconds(500)) }
            }
            #expect(found, "扫描后图片应进入 MediaStore")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        var gone = false
        for _ in 0..<10 where !gone {
            gone = try await !inStore()
            if !gone { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(gone, "删除并再次扫描后应移出 MediaStore")
    }

    @Test func logSnapshotReadable() async throws {
        let (_, actions) = try await realActions()
        let s = try await actions.logSnapshot(LogQuery(package: nil, lines: 50))
        #expect(s.entries.count >= 1, "logcat 缓冲应至少有 1 条可解析记录")
    }
}
