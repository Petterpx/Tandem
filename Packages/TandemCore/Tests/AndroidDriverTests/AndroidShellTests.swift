import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private let adbURL = URL(fileURLWithPath: "/fake/adb")
private let adbPath = adbURL.path

private func actions(_ runner: FakeProcessRunner) -> AndroidActions {
    AndroidActions(serial: "S", adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), settleDelay: .zero)
}

@Suite struct AndroidShellTests {
    @Test func shellWrapsWithDeviceTimeout() async throws {
        let runner = FakeProcessRunner()
        let args = ["-s", "S", "shell", "timeout", "30", "sh", "-c", "'echo '\\''hi'\\'''"]
        runner.stub(adbPath, args, stdout: "hi\n")
        let r = try await actions(runner).shell("echo 'hi'", timeout: .seconds(30))
        #expect(runner.calls.map(\.args) == [args])
        #expect(r == ShellResult(stdout: "hi\n", stderr: "", exitCode: 0))
    }

    @Test func nonZeroExitIsReturnedNotThrown() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "timeout", "30", "sh", "-c", "'false'"], stderr: "x", exitCode: 2)
        let r = try await actions(runner).shell("false", timeout: .seconds(30))
        #expect(r.exitCode == 2)
        #expect(r.stderr == "x")
        #expect(!r.timedOut)
    }

    @Test func exit124IsTimedOut() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "timeout", "1", "sh", "-c", "'sleep 9'"], stdout: "part", exitCode: 124)
        let r = try await actions(runner).shell("sleep 9", timeout: .milliseconds(200))
        #expect(r.timedOut)
        #expect(r.exitCode == 124)
        #expect(r.stdout == "part")
    }

    @Test func runnerTimeoutMapsToShellTimeout() async {
        let runner = FakeProcessRunner()
        runner.stubFailure(adbPath, ["-s", "S", "shell", "timeout", "30", "sh", "-c", "'x'"], error: DeviceError.timeout("adb"))
        do {
            _ = try await actions(runner).shell("x", timeout: .seconds(30))
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .TIMEOUT)
            #expect(e.message == "shell 命令超时")
        } catch { Issue.record("错误类型不对：\(error)") }
    }
}
