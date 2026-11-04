import Foundation
import Testing
import DeviceCore
@testable import IOSSimulatorDriver

@Suite struct SimctlTests {
    let udid = "3B76F05C-3449-4D26-A84F-BAB414513611"

    @Test func filtersUnavailableAndNonIOSRuntimes() throws {
        let data = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"3B76F05C-3449-4D26-A84F-BAB414513611","name":"iPhone 16","state":"Booted","isAvailable":true},{"udid":"B19835E8-C091-447D-BCC4-608B79D4F7C4","name":"iPad","state":"Shutdown","isAvailable":true},{"udid":"bad","name":"Broken","state":"Booted","isAvailable":true},{"name":"Missing","state":"Booted","isAvailable":true},{"udid":"5295E52F-2E24-4A38-8D6B-D82AD474C094","name":"Unavailable","state":"Booted","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.tvOS-18-0":[{"udid":"6DC5B0EC-A209-4AEF-9392-FE251C3C3347","name":"Apple TV","state":"Booted","isAvailable":true}]}}"#.utf8)
        let devices = try SimctlClient.parseDevices(data)
        #expect(devices.count == 2)
        #expect(devices.first(where: { $0.udid == udid })?.isBooted == true)
        #expect(devices.first(where: { $0.name == "iPad" })?.isBooted == false)
    }

    @Test func rejectsAmbiguousBootedAliasBeforeLaunching() async {
        await #expect(throws: DeviceError.self) { try await SimctlClient().boot("booted") }
    }

    @Test func bootWaitsForBootStatusWithExplicitDevice() async throws {
        let runner = SimctlRecorder()
        try await SimctlClient(runner: runner).boot(udid)
        #expect(runner.arguments == [["simctl", "boot", udid], ["simctl", "bootstatus", udid, "-b"]])
    }

    @Test func screenshotReadsUniqueTemporaryPNGFilesAndCleansThem() async throws {
        let runner = ScreenshotRunner(output: .valid)
        let client = SimctlClient(runner: runner)
        async let first = client.screenshot(udid)
        async let second = client.screenshot(udid)
        #expect(try await first == ScreenshotRunner.png)
        #expect(try await second == ScreenshotRunner.png)
        let outputs = runner.outputs
        #expect(outputs.count == 2)
        #expect(Set(outputs).count == 2)
        for file in outputs {
            #expect(file.lastPathComponent.hasSuffix(".png"))
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    @Test(arguments: [ScreenshotOutput.missing, .empty, .invalid, .failed])
    fileprivate func screenshotRejectsMissingEmptyInvalidOrFailedOutputAndCleansTemporaryDirectory(_ output: ScreenshotOutput) async throws {
        let runner = ScreenshotRunner(output: output)
        await #expect(throws: DeviceError.self) { try await SimctlClient(runner: runner).screenshot(udid) }
        let file = try #require(runner.outputs.first)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func ndjsonPreservesSplitMessagesAndRejectsOversizeAndIncompleteEOF() throws {
        var decoder = SimulatorMessageDecoder(maxLineSize: 100)
        #expect(try decoder.append(Data(#"{"event":"rea"#.utf8)).isEmpty)
        let messages = try decoder.append(Data("dy\"}\n{\"id\":8,\"ok\":false,\"code\":\"UNSUPPORTED\",\"error\":\"key\"}\n".utf8))
        #expect(messages.count == 2)
        #expect(messages[0].event == "ready")
        #expect(messages[1].deviceError?.code == .UNSUPPORTED)
        try decoder.finish()
        _ = try decoder.append(Data("{".utf8))
        #expect(throws: DeviceError.self) { try decoder.finish() }
        var tiny = SimulatorMessageDecoder(maxLineSize: 2)
        #expect(throws: DeviceError.self) { try tiny.append(Data("123".utf8)) }
    }
}

private final class SimctlRecorder: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var arguments: [[String]] { lock.withLock { calls } }
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        lock.withLock { calls.append(args) }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func stream(_ executable: URL, _ args: [String]) throws -> any RunningProcess { fatalError() }
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: any RunningProcess) { fatalError() }
}

private enum ScreenshotOutput: Sendable { case valid, missing, empty, invalid, failed }

private final class ScreenshotRunner: ProcessRunner, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let lock = NSLock()
    private var paths: [URL] = []
    private let output: ScreenshotOutput
    var outputs: [URL] { lock.withLock { paths } }
    init(output: ScreenshotOutput) { self.output = output }
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        guard let path = args.last, path.hasPrefix("/") else {
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let file = URL(fileURLWithPath: path)
        lock.withLock { paths.append(file) }
        switch output {
        case .valid, .failed: try Self.png.write(to: file)
        case .missing: break
        case .empty: try Data().write(to: file)
        case .invalid: try Data("not a PNG screenshot despite exit code zero".utf8).write(to: file)
        }
        return ProcessResult(exitCode: output == .failed ? 1 : 0, stdout: Data(), stderr: Data("screenshot command result".utf8))
    }
    func stream(_ executable: URL, _ args: [String]) throws -> any RunningProcess { fatalError("not used") }
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: any RunningProcess) { fatalError("not used") }
}
