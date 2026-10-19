import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

private let adbPath = "/fake/adb"
private let apk = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/tandem-test.apk")
private let tempID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let tempPath = "/data/local/tmp/tandem_11111111-2222-3333-4444-555555555555.apk"
private let installArgs = ["-s", "S", "shell", "pm install -r -d '\(tempPath)'"]
private let rmArgs = ["-s", "S", "shell", "rm -f '\(tempPath)'"]

/// 推送成功的 sync 流（一个文件：OKAY + DONE 应答）。
private func pushStreams() -> [InMemoryByteStream] {
    streams(Data("OKAY".utf8) + u32(0))
}

@Suite struct AndroidInstallTests {
    private func stubManifest(_ runner: FakeProcessRunner) async throws {
        // 让 fake runner 交回夹具 APK 里真实的清单字节。
        let real = try await SystemProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", apk.path, "AndroidManifest.xml"], timeout: .seconds(10))
        let axml = real.stdout
        runner.stubData("/usr/bin/unzip", ["-p", apk.path, "AndroidManifest.xml"], stdout: axml)
    }

    @Test func installPushesThenPmInstalls() async throws {
        let runner = FakeProcessRunner()
        try await stubManifest(runner)
        runner.stub(adbPath, installArgs, stdout: "Performing Streamed Install\nSuccess\n")
        runner.stub(adbPath, rmArgs)
        let factory = StreamFactory(pushStreams())
        let package = try await makeActions(runner, factory).install(apk: apk, tempID: tempID, progress: { _ in })
        #expect(package == "dev.tandem.testapp")
        #expect(factory.made[1].written.range(of: Data(tempPath.utf8)) != nil)
        let adbCalls = runner.calls.filter { $0.path == adbPath }.map(\.args)
        #expect(adbCalls == [installArgs, rmArgs])
    }

    @Test func installTempPathQuoted() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, installArgs, stdout: "Success\n")
        runner.stub(adbPath, rmArgs)
        _ = try await makeActions(runner, StreamFactory(pushStreams())).install(apk: apk, tempID: tempID, progress: { _ in })
        let install = try #require(runner.calls.first { $0.args == installArgs })
        #expect(install.args.last == "pm install -r -d '\(tempPath)'")
        #expect(runner.timeout(adbPath, installArgs) == .seconds(120))
    }

    @Test func installFailureCarriesAdviceAndCleansUp() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, installArgs, stdout: "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n", exitCode: 1)
        runner.stub(adbPath, rmArgs)
        do {
            _ = try await makeActions(runner, StreamFactory(pushStreams())).install(apk: apk, tempID: tempID, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message == "安装失败：Failure [INSTALL_FAILED_VERSION_DOWNGRADE]")
            #expect(e.suggestion == "设备上已有更高版本")
        }
        #expect(runner.calls.map(\.args).contains(rmArgs))
    }

    @Test func installFailureWithNotFoundIsNotUnsupported() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, installArgs, stdout: "Failure [INSTALL_FAILED_MISSING_SHARED_LIBRARY: Package not found]\n")
        runner.stub(adbPath, rmArgs)
        do {
            _ = try await makeActions(runner, StreamFactory(pushStreams())).install(apk: apk, tempID: tempID, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message.contains("Package not found"))
        }
    }

    @Test func cancelDuringInstallStillCleansUp() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, installArgs, stdout: "Success\n")
        runner.stub(adbPath, rmArgs)
        let actions = makeActions(runner, StreamFactory(pushStreams()))
        let task = Task { try await actions.install(apk: apk, tempID: tempID, progress: { _ in }) }
        task.cancel()
        _ = try? await task.value
        #expect(runner.calls.map(\.args).contains(rmArgs))
    }

    @Test func unsupportedDetectionCanBeDisabled() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "x"], stdout: "foo: not found")
        let actions = makeActions(runner, StreamFactory([]))
        let out = try await actions.shellChecked("x", detectUnsupported: false)
        #expect(out.output.contains("not found"))
        await #expect(throws: DeviceError.self) { try await actions.shellChecked("x") }
    }

    @Test func failureAdviceMapping() {
        #expect(AndroidCommands.Install.failureAdvice("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: x]") == "签名与已安装版本不一致，请先卸载")
        #expect(AndroidCommands.Install.failureAdvice("INSTALL_FAILED_INSUFFICIENT_STORAGE") == "设备存储空间不足")
        #expect(AndroidCommands.Install.failureAdvice("INSTALL_FAILED_NO_MATCHING_ABIS") == "APK 不支持该设备的 CPU 架构")
        #expect(AndroidCommands.Install.failureAdvice("Failure [INSTALL_PARSE_FAILED_NOT_APK]") == "不是有效的 APK")
        #expect(AndroidCommands.Install.failureAdvice("Failure [INSTALL_FAILED_OTHER]") == nil)
    }

    @Test func mediaScanQuotesURI() async throws {
        let runner = FakeProcessRunner()
        let cmd = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Pictures/a b.jpg'"
        runner.stub(adbPath, ["-s", "S", "shell", cmd], stdout: "Broadcast completed: result=0\n")
        try await makeActions(runner, StreamFactory([])).mediaScan(["/sdcard/Pictures/a b.jpg"])
        #expect(runner.calls.map(\.args) == [["-s", "S", "shell", cmd]])
    }

    @Test func mediaScanValidatesPath() async {
        let runner = FakeProcessRunner()
        await #expect(throws: DeviceError.self) { try await makeActions(runner, StreamFactory([])).mediaScan(["relative.jpg"]) }
        #expect(runner.calls.isEmpty)
    }

    @Test func mediaScanHostilePathIsQuoted() async throws {
        let runner = FakeProcessRunner()
        let cmd = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Pictures/a'\\''b$(x).jpg'"
        runner.stub(adbPath, ["-s", "S", "shell", cmd], stdout: "Broadcast completed: result=0\n")
        try await makeActions(runner, StreamFactory([])).mediaScan(["/sdcard/Pictures/a'b$(x).jpg"])
        #expect(runner.calls.map(\.args) == [["-s", "S", "shell", cmd]])
    }

    /// 任一路径含换行即整体拒绝，一条广播也不发。
    @Test func mediaScanNewlinePathRejectedBeforeAnyCall() async {
        let runner = FakeProcessRunner()
        await #expect(throws: DeviceError.self) {
            try await makeActions(runner, StreamFactory([])).mediaScan(["/sdcard/Pictures/ok.jpg", "/sdcard/Pictures/a\nb.jpg"])
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func mediaScanBatchesIntoOneShell() async throws {
        let runner = FakeProcessRunner()
        let a = AndroidCommands.Install.scanCommand("/sdcard/Pictures/a.jpg")
        let b = AndroidCommands.Install.scanCommand("/sdcard/Pictures/b.jpg")
        // 输出里出现 "not found" 也不当作不支持
        runner.stub(adbPath, ["-s", "S", "shell", a + " ; " + b], stdout: "Broadcast completed: result=0\nnot found\n")
        try await makeActions(runner, StreamFactory([])).mediaScan(["/sdcard/Pictures/a.jpg", "/sdcard/Pictures/b.jpg"])
        #expect(runner.calls.map(\.args) == [["-s", "S", "shell", a + " ; " + b]])
    }

    @Test func scanBatchesStayUnderLimit() {
        let paths = (0..<500).map { "/sdcard/Pictures/" + String(repeating: "x", count: 200) + "_\($0).jpg" }
        let batches = AndroidCommands.Install.scanBatches(paths)
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { $0.utf8.count <= AndroidCommands.Install.scanBatchLimit })
        // 拆开后与逐条命令一一对应、顺序不变
        let joined = batches.flatMap { $0.components(separatedBy: " ; ") }
        #expect(joined == paths.map(AndroidCommands.Install.scanCommand))
        #expect(AndroidCommands.Install.scanBatches([]).isEmpty)
        // 单条超过上限时自成一批
        #expect(AndroidCommands.Install.scanBatches(["/a.jpg", "/b.jpg"], limit: 10).count == 2)
    }
}
