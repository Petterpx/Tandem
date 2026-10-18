import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private let adbURL = URL(fileURLWithPath: "/fake/adb")
private let adbPath = adbURL.path

private func client(_ runner: FakeProcessRunner) -> AdbClient {
    AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner)
}

@Suite struct AndroidActionsTests {
    @Test func screenshotRunsScreencapOnCurrentSerial() async throws {
        let runner = FakeProcessRunner()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])
        runner.stubData(adbPath, ["-s", "192.168.1.5:5555", "exec-out", "screencap", "-p"], stdout: png)
        let actions = AndroidActions(serial: "192.168.1.5:5555", adb: client(runner))
        #expect(try await actions.screenshot() == png)
    }

    @Test func screenshotRejectsNonPNG() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "exec-out", "screencap", "-p"], stdout: "error: closed")
        let actions = AndroidActions(serial: "S", adb: client(runner))
        do {
            _ = try await actions.screenshot()
            Issue.record("应抛错")
        } catch let error as DeviceError {
            #expect(error.message.contains("截图数据无效"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test func screenshotFailureSurfacesAdbError() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "exec-out", "screencap", "-p"], stderr: "device offline", exitCode: 1)
        let actions = AndroidActions(serial: "S", adb: client(runner))
        do {
            _ = try await actions.screenshot()
            Issue.record("应抛错")
        } catch {
            #expect(error as? DeviceError == DeviceError.connectionFailed("device offline"))
        }
    }

    private static let dumpCommand = "uiautomator dump /data/local/tmp/tandem_ui.xml"

    @Test func uiTreeDumpsThenReads() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", Self.dumpCommand], stdout: "UI hierchary dumped to: /data/local/tmp/tandem_ui.xml")
        runner.stubData(adbPath, ["-s", "S", "exec-out", "cat", "/data/local/tmp/tandem_ui.xml"], stdout: try uiDumpFixture())
        let tree = try await AndroidActions(serial: "S", adb: client(runner)).uiTree()
        #expect(tree.screen == CGSize(width: 1080, height: 2400))
    }

    @Test func uiTreeRetriesOnceThenFails() async {
        let runner = FakeProcessRunner()
        runner.stubSequence(adbPath, ["-s", "S", "shell", Self.dumpCommand],
                            stdouts: ["ERROR: could not get idle state.", "ERROR: could not get idle state."])
        do {
            _ = try await AndroidActions(serial: "S", adb: client(runner)).uiTree()
            Issue.record("应抛错")
        } catch let error as DeviceError {
            #expect(error.message.contains("读取界面结构失败"))
            #expect(error.suggestion == "界面可能正在动画或页面禁止读取，请稍后重试或改用截图")
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
        #expect(runner.calls.filter { $0.args.contains(Self.dumpCommand) }.count == 2)
    }
}
