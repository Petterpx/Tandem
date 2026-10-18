import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private let adbURL = URL(fileURLWithPath: "/fake/adb")
private let adbPath = adbURL.path
private let readArgs = ["-s", "S", "shell", AndroidCommands.Network.readCommand]

private func actions(_ runner: FakeProcessRunner) -> AndroidActions {
    AndroidActions(serial: "S", adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), settleDelay: .zero)
}

@Suite struct AndroidNetworkTests {
    @Test func networkStateParsesRead() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, readArgs, stdout: "1\n0\n0\n")
        #expect(try await actions(runner).networkState() == NetworkState(wifi: true, data: false, airplane: false))
    }

    @Test func setNetworkReadsBack() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "svc wifi disable"], stdout: "")
        runner.stub(adbPath, readArgs, stdout: "0\n1\n0")
        let state = try await actions(runner).setNetwork(.wifi, on: false)
        #expect(state.wifi == false)
        #expect(state.data == true)
    }

    @Test func setNetworkMismatchFails() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "svc wifi disable"], stdout: "")
        runner.stub(adbPath, readArgs, stdout: "1\n1\n0")
        do {
            _ = try await actions(runner).setNetwork(.wifi, on: false)
            Issue.record("应抛错")
        } catch let error as DeviceError {
            #expect(error.code == .CONNECTION_FAILED)
            #expect(error.message == "设置未生效")
            #expect(error.suggestion == "部分 ROM 禁止通过 shell 修改此项，请在手机上手动设置")
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test func airplaneNeedsAndroid11() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "getprop ro.build.version.sdk"], stdout: "29\n")
        do {
            _ = try await actions(runner).setNetwork(.airplane, on: true)
            Issue.record("应抛错")
        } catch let error as DeviceError {
            #expect(error.code == .UNSUPPORTED)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
        #expect(!runner.calls.contains { $0.args.contains { $0.contains("cmd connectivity") } })
    }

    @Test func unknownCommandIsUnsupported() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "svc data enable"], stdout: "svc: not found", exitCode: 127)
        do {
            _ = try await actions(runner).setNetwork(.data, on: true)
            Issue.record("应抛错")
        } catch let error as DeviceError {
            #expect(error.code == .UNSUPPORTED)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }
}
