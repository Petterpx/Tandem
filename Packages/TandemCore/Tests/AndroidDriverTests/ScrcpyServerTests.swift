import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct ScrcpyServerTests {
    @Test func serverCommandIsExact() {
        let o = ScrcpyLaunchOptions.for(.usb, scid: 0x0abc1234)
        #expect(o.serverCommand() == ["CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1",
                                      "scid=0abc1234", "log_level=info", "audio=false", "video_codec=h264", "max_size=1920",
                                      "video_bit_rate=8000000", "max_fps=60", "tunnel_forward=true", "clipboard_autosync=false"])
        #expect(o.socketName == "scrcpy_0abc1234")
    }

    @Test func wifiUsesLowerQuality() {
        let o = ScrcpyLaunchOptions.for(.wifi, scid: 1)
        #expect(o.maxSize == 1280 && o.bitRate == 4_000_000 && o.maxFps == 60)
        #expect(o.serverCommand().contains("max_size=1280"))
        #expect(o.serverCommand().contains("video_bit_rate=4000000"))
        #expect(o.socketName == "scrcpy_00000001")
    }

    @Test func detectsInjectPermissionLine() {
        #expect(ScrcpyLog.isInjectPermissionError(
            "java.lang.SecurityException: Injecting input events requires the caller (or the source of the instrumentation, if any) to have the INJECT_EVENTS permission."))
        #expect(!ScrcpyLog.isInjectPermissionError("[server] INFO: Device: [Google] google Pixel 8 (Android 15)"))
    }

    @Test func launcherPushesForwardsAndStarts() async throws {
        let adbURL = URL(fileURLWithPath: "/fake/adb")
        let jar = URL(fileURLWithPath: "/fake/scrcpy-server-v5.0.1")
        let options = ScrcpyLaunchOptions.for(.usb, scid: 0x0abc1234)
        let runner = FakeProcessRunner()
        runner.stub(adbURL.path, ["-s", "SER", "push", jar.path, "/data/local/tmp/scrcpy-server.jar"], stdout: "1 file pushed\n")
        runner.stub(adbURL.path, ["-s", "SER", "forward", "tcp:0", "localabstract:scrcpy_0abc1234"], stdout: "27183\n")
        runner.stub(adbURL.path, ["-s", "SER", "forward", "--remove", "tcp:27183"])
        runner.stubStream(adbURL.path, ["-s", "SER", "shell"] + options.serverCommand(), lines: ["[server] INFO: Device: Pixel 8"])

        let video = InMemoryByteStream(Data([0]) + Data("Pixel 8".utf8) + Data(count: 64 - 7))
        let control = InMemoryByteStream()
        let ports = Recorder<UInt16>()
        let launcher = AdbScrcpyLauncher(
            adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), runner: runner, serverJar: jar,
            connect: { port in
                let n = ports.append(port)
                return n == 1 ? video : control
            })

        let launched = try await launcher.launch(serial: "SER", options: options)

        #expect(launched.connection.deviceName == "Pixel 8")
        #expect(ports.values == [27183, 27183])
        #expect(runner.calls.map(\.args) == [
            ["-s", "SER", "push", jar.path, "/data/local/tmp/scrcpy-server.jar"],
            ["-s", "SER", "forward", "tcp:0", "localabstract:scrcpy_0abc1234"],
            ["-s", "SER", "shell"] + options.serverCommand(),
        ])
        var logs: [String] = []
        for await line in launched.logs { logs.append(line) }
        #expect(logs == ["[server] INFO: Device: Pixel 8"])

        await launched.stop()
        #expect(video.isClosed && control.isClosed)
        #expect(runner.calls.last?.args == ["-s", "SER", "forward", "--remove", "tcp:27183"])
    }

    @Test func launcherFailsWhenPushFails() async {
        let adbURL = URL(fileURLWithPath: "/fake/adb")
        let jar = URL(fileURLWithPath: "/fake/jar")
        let runner = FakeProcessRunner()
        runner.stub(adbURL.path, ["-s", "SER", "push", jar.path, "/data/local/tmp/scrcpy-server.jar"], stderr: "no space", exitCode: 1)
        let launcher = AdbScrcpyLauncher(adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), runner: runner, serverJar: jar,
                                         connect: { _ in InMemoryByteStream() })
        let error = await #expect(throws: DeviceError.self) {
            _ = try await launcher.launch(serial: "SER", options: .for(.usb, scid: 1))
        }
        #expect(error?.code == .CONNECTION_FAILED)
        #expect(runner.calls.count == 1)
    }
}

/// 线程安全的追加记录器。
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    var values: [T] { lock.withLock { _values } }
    /// 返回追加后的数量。
    @discardableResult func append(_ value: T) -> Int {
        lock.withLock { _values.append(value); return _values.count }
    }
}
