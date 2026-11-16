import DeviceCore
import Foundation
import Testing
@testable import IOSPhysicalDriver

@Suite struct IOSPhysicalAppLauncherTests {
    private let serial = "00008150-TEST1234"
    @Test func parsesSystemAndUserAppsDeduplicatingAndRejectingInvalidIdentifiers() throws {
        let data = Data(#"{"info":{"outcome":"success"},"result":{"apps":[{"name":"Settings","bundleIdentifier":"com.apple.Preferences"},{"name":"微信","bundleIdentifier":"com.tencent.xin"},{"name":"duplicate","bundleIdentifier":"com.tencent.xin"},{"bundleIdentifier":"com.example.fallback"},{"name":"bad","bundleIdentifier":"/tmp/app"}]}}"#.utf8)
        let apps = try IOSPhysicalAppLauncher.parseApps(data)
        #expect(apps.count == 3)
        #expect(apps.contains(.init(name: "Settings", bundleID: "com.apple.Preferences")))
        #expect(apps.contains(.init(name: "微信", bundleID: "com.tencent.xin")))
        #expect(apps.contains(.init(name: "com.example.fallback", bundleID: "com.example.fallback")))
        #expect(throws: DeviceError.self) { try IOSPhysicalAppLauncher.parseApps(Data(#"{"info":{"outcome":"failed"},"result":{"apps":[]}}"#.utf8)) }
        #expect(throws: DeviceError.self) { try IOSPhysicalAppLauncher.parseApps(Data("not json".utf8)) }
    }

    @Test func concurrentListsShareCacheAndPrivateResultDirectoryIsRemoved() async throws {
        let runner = AppCommandRunner()
        let launcher = IOSPhysicalAppLauncher(runner: runner)
        async let first = launcher.installedApps(on: serial)
        async let second = launcher.installedApps(on: serial)
        let (a, b) = try await (first, second)
        #expect(a == b)
        _ = try await launcher.installedApps(on: serial)
        #expect(runner.calls.count == 1)
        let args = try #require(runner.calls.first)
        #expect(args.contains("--include-all-apps"))
        #expect(args.contains("--device"))
        #expect(!args.contains("--require-container-access"))
        #expect(runner.privateDirectory)
        #expect(runner.resultPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) })
    }

    @Test func expiredListsRefreshAndLaunchesDispatchOncePerCallWithoutExtraArguments() async throws {
        let runner = AppCommandRunner()
        let launcher = IOSPhysicalAppLauncher(runner: runner, cacheLifetime: .zero)
        _ = try await launcher.installedApps(on: serial)
        _ = try await launcher.installedApps(on: serial)
        #expect(runner.calls.count == 2)
        try await launcher.launch("com.apple.Preferences", on: serial)
        try await launcher.launch("com.apple.Preferences", on: serial)
        #expect(runner.calls.count == 4)
        for args in runner.calls.suffix(2) {
            #expect(Array(args.prefix(4)) == ["devicectl", "device", "process", "launch"])
            #expect(args.last == "com.apple.Preferences")
            #expect(!args.contains("--terminate-existing"))
            #expect(!args.contains("--console"))
            #expect(!args.contains("--payload-url"))
        }
    }

    @Test func invalidBundleIdentifiersNeverReachProcess() async throws {
        let runner = AppCommandRunner()
        let launcher = IOSPhysicalAppLauncher(runner: runner)
        for invalid in ["", "Settings", "--help", "-com.apple.foo", "com..apple.foo", "com.apple.foo arg", "com.apple.foo;open", "/Applications/App.app", "com.app.💡", "com.app\0"] {
            await #expect(throws: DeviceError.self) { try await launcher.launch(invalid, on: serial) }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func timeoutAndCLIRejectionAreSanitizedNeverRetriedAndCleanTempFiles() async throws {
        for timedOut in [true, false] {
            let runner = AppCommandRunner(failure: timedOut ? .timeout("secret stderr") : nil, exitCode: 1)
            let launcher = IOSPhysicalAppLauncher(runner: runner)
            do {
                try await launcher.launch("com.apple.Preferences", on: serial)
                Issue.record("Failed launch reported success")
            } catch let error as DeviceError {
                #expect(error.code == (timedOut ? .TIMEOUT : .CONNECTION_FAILED))
                #expect(error.message.contains("状态未知"))
                #expect(!error.message.contains("secret stderr"))
            }
            #expect(runner.calls.count == 1)
            #expect(runner.resultPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) })
        }
    }
}

private final class AppCommandRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var privateMode = true
    private let failure: DeviceError?
    private let exitCode: Int32
    var calls: [[String]] { lock.withLock { recorded } }
    var privateDirectory: Bool { lock.withLock { privateMode } }
    var resultPaths: [URL] {
        calls.compactMap { args in args.firstIndex(of: "--json-output").map { URL(fileURLWithPath: args[$0 + 1]) } }
    }
    init(failure: DeviceError? = nil, exitCode: Int32 = 0) { self.failure = failure; self.exitCode = exitCode }
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        #expect(executable.path == "/usr/bin/xcrun")
        #expect(timeout == .seconds(15))
        let index = try #require(args.firstIndex(of: "--json-output"))
        let output = URL(fileURLWithPath: args[index + 1])
        let attrs = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)
        lock.withLock {
            recorded.append(args)
            privateMode = privateMode && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700
        }
        try await Task.sleep(for: .milliseconds(10))
        if let failure { throw failure }
        let json = args.contains("apps")
            ? #"{"info":{"outcome":"success"},"result":{"apps":[{"name":"Settings","bundleIdentifier":"com.apple.Preferences"}]}}"#
            : #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":42}}}"#
        try Data(json.utf8).write(to: output)
        return .init(exitCode: exitCode, stdout: Data(), stderr: Data("secret stderr".utf8))
    }
    func stream(_ executable: URL, _ args: [String]) throws -> any RunningProcess { throw DeviceError.unsupported("test") }
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: any RunningProcess) { throw DeviceError.unsupported("test") }
}
