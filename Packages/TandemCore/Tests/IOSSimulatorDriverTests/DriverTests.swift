import DeviceCore
import Foundation
import Testing
@testable import IOSSimulatorDriver

@Suite struct SimulatorDriverTests {
    @Test func missingHelperExplainsBuildRequirementAndDoesNotAdvertiseControl() {
        let driver = IOSSimulatorDriver(helperURL: URL(fileURLWithPath: "/missing/tandem-simulator"))
        #expect(driver.availabilityError?.code == .UNSUPPORTED)
        #expect(driver.capabilities.isEmpty)
    }

    @Test func pollingOnlyPublishesChangesIncludingFailureRecoveryAndNewDevices() async throws {
        let runner = PollingSimctlRunner()
        let driver = IOSSimulatorDriver(helperURL: URL(fileURLWithPath: "/missing/tandem-simulator"),
                                        client: SimctlClient(runner: runner), pollInterval: .milliseconds(5))
        let log = SnapshotLog()
        let observer = Task { for await snapshot in driver.deviceSnapshots() { log.append(snapshot) } }
        defer { observer.cancel() }

        try await waitUntil { runner.pollCount >= 5 && !log.snapshots.isEmpty }
        #expect(log.snapshots.map { $0.map(\.name) } == [[]])

        runner.reply = .devices(["iPhone"])
        try await waitUntil { log.snapshots.last?.map(\.name) == ["iPhone"] }
        let firstDevicePoll = runner.pollCount
        try await waitUntil { runner.pollCount >= firstDevicePoll + 5 }
        #expect(log.snapshots.count == 2)

        runner.reply = .failure
        try await waitUntil { log.snapshots.last?.isEmpty == true && log.snapshots.count >= 3 }
        let failurePoll = runner.pollCount
        try await waitUntil { runner.pollCount >= failurePoll + 5 }
        #expect(log.snapshots.count == 3)

        runner.reply = .devices(["iPhone"])
        try await waitUntil { log.snapshots.count >= 4 }
        runner.reply = .devices(["iPhone", "iPad"])
        try await waitUntil { log.snapshots.count >= 5 }
        #expect(log.snapshots.map { Set($0.map(\.name)) } == [[], ["iPhone"], [], ["iPhone"], ["iPhone", "iPad"]])
    }

    @Test func uiTreeExplicitlySuggestsCoordinates() async {
        let actions = IOSSimulatorActions(udid: "3B76F05C-3449-4D26-A84F-BAB414513611", client: SimctlClient())
        do {
            _ = try await actions.uiTree()
            Issue.record("UI tree incorrectly supported")
        } catch let error as DeviceError {
            #expect(error.code == .UNSUPPORTED)
            #expect(error.message.contains("坐标"))
        } catch { Issue.record("wrong error: \(error)") }
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DeviceError.timeout("模拟器发现测试")
}

private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[DeviceInfo]] = []
    var snapshots: [[DeviceInfo]] { lock.withLock { values } }
    func append(_ snapshot: [DeviceInfo]) { lock.withLock { values.append(snapshot) } }
}

private final class PollingSimctlRunner: ProcessRunner, @unchecked Sendable {
    enum Reply {
        case devices([String]), failure
    }
    private let lock = NSLock()
    private var value: Reply = .devices([])
    private var polls = 0
    var reply: Reply {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var pollCount: Int { lock.withLock { polls } }
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        let response = lock.withLock { polls += 1; return value }
        switch response {
        case .failure: return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Xcode unavailable".utf8))
        case let .devices(names):
            let ids = ["3B76F05C-3449-4D26-A84F-BAB414513611", "B19835E8-C091-447D-BCC4-608B79D4F7C4"]
            let devices = zip(names, ids).map { name, id in ["udid": id, "name": name, "state": "Booted", "isAvailable": true] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-0": devices]])
            return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
        }
    }
    func stream(_ executable: URL, _ args: [String]) throws -> any RunningProcess { fatalError("not used") }
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: any RunningProcess) { fatalError("not used") }
}
