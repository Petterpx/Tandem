import Foundation
import ImageIO
import Testing
import DeviceCore
@testable import AndroidDriver

/// 真机集成测试：仅在设置 TANDEM_TEST_SERIAL 时运行，否则整组显示为 skipped。
/// scrcpy-server 路径取 TANDEM_SCRCPY_SERVER，默认仓库内 App/Resources/Vendor/scrcpy-server-v5.0.1。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_TEST_SERIAL"] != nil))
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
}
