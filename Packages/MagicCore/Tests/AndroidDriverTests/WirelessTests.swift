import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private func fixtureText(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [WirelessStep] = []
    var steps: [WirelessStep] { lock.withLock { _steps } }
    func add(_ s: WirelessStep) { lock.withLock { _steps.append(s) } }
}

private let adbURL = URL(fileURLWithPath: "/fake/adb")

private func makeConnector(_ runner: FakeProcessRunner) -> WirelessConnector {
    WirelessConnector(adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), pollInterval: .milliseconds(1))
}

@Test func parsesMdnsWithTrailingDot() throws {
    let s = MdnsParser.parse(try fixtureText("mdns-services"))
    #expect(s.count == 2)
    #expect(s[0] == MdnsService(instance: "adb-R5CT1234567-AbCdEf", kind: .connect, host: "192.168.1.23", port: 41235))
    #expect(s[1] == MdnsService(instance: "studio-K8x2pQaB1c", kind: .pairing, host: "192.168.1.23", port: 37099))
}

@Test func qrPayloadFormat() {
    let c = PairingCredentials(name: "studio-abc", password: "123456")
    #expect(c.qrPayload == "WIFI:T:ADB;S:studio-abc;P:123456;;")
}

@Test func generatedCredentialsShape() {
    var rng = SeededRNG(state: 42)
    let c = PairingCredentials.generate(using: &rng)
    #expect(c.name.wholeMatch(of: /studio-[A-Za-z0-9]{10}/) != nil)
    #expect(c.password.wholeMatch(of: /[0-9]{12}/) != nil)
}

@Test func parsesWlanIP() throws {
    #expect(WirelessConnector.parseWlanIPv4(try fixtureText("ip-addr-wlan0")) == "192.168.1.23")
    #expect(WirelessConnector.parseWlanIPv4("") == nil)
}

@Test func qrFlowPairsThenConnects() async throws {
    let runner = FakeProcessRunner()
    let connectOnly = "List of discovered mdns services\nadb-R5CT1234567-AbCdEf\t_adb-tls-connect._tcp.\t192.168.1.23:41235\n"
    let both = connectOnly + "studio-K8x2pQaB1c\t_adb-tls-pairing._tcp\t192.168.1.23:37099\n"
    runner.stubSequence(adbURL.path, ["mdns", "services"], stdouts: [connectOnly, both])
    runner.stub(adbURL.path, ["pair", "192.168.1.23:37099", "123456789012"], stdout: "Successfully paired to 192.168.1.23:37099 [guid=adb-R5CT1234567-AbCdEf]\n")
    runner.stub(adbURL.path, ["connect", "192.168.1.23:41235"], stdout: "connected to 192.168.1.23:41235\n")
    let rec = StepRecorder()
    let result = try await makeConnector(runner).pairWithQR(
        PairingCredentials(name: "studio-K8x2pQaB1c", password: "123456789012")) { rec.add($0) }
    #expect(result == "192.168.1.23:41235")
    #expect(rec.steps == [.waitingForScan, .pairing, .connecting, .connected(serial: "192.168.1.23:41235")])
    #expect(runner.calls.filter { $0.args == ["mdns", "services"] }.count >= 2)
}

@Test func qrFlowTimesOutWaitingForScan() async {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["mdns", "services"], stdout: "List of discovered mdns services\n")
    do {
        _ = try await makeConnector(runner).pairWithQR(PairingCredentials(name: "studio-x", password: "1"), timeout: .milliseconds(30)) { _ in }
        Issue.record("应当超时")
    } catch let e as DeviceError {
        #expect(e.code == .TIMEOUT)
        #expect(e.message.contains("等待扫码"))
    } catch { Issue.record("意外错误 \(error)") }
}

@Test func pairFailureSurfacesAdbOutput() async {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["pair", "192.168.1.23:37099", "000000"], stdout: "Failed: Wrong password or connection was dropped.\n")
    do {
        _ = try await makeConnector(runner).pairWithCode(hostPort: "192.168.1.23:37099", code: "000000") { _ in }
        Issue.record("应当失败")
    } catch let e as DeviceError {
        #expect(e.code == .CONNECTION_FAILED)
        #expect(e.message.contains("Failed: Wrong password or connection was dropped."))
    } catch { Issue.record("意外错误 \(error)") }
}

@Test func pairWithCodeConnectsToDiscoveredService() async throws {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["pair", "192.168.1.23:37099", "123456"], stdout: "Successfully paired to 192.168.1.23:37099\n")
    runner.stub(adbURL.path, ["mdns", "services"], stdout: "List of discovered mdns services\nadb-R5CT1234567-AbCdEf\t_adb-tls-connect._tcp\t192.168.1.23:41235\n")
    runner.stub(adbURL.path, ["connect", "192.168.1.23:41235"], stdout: "already connected to 192.168.1.23:41235\n")
    let result = try await makeConnector(runner).pairWithCode(hostPort: "192.168.1.23:37099", code: "123456") { _ in }
    #expect(result == "192.168.1.23:41235")
}

@Test func connectFailureSurfaces() async {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["pair", "192.168.1.23:37099", "123456"], stdout: "Successfully paired to 192.168.1.23:37099\n")
    runner.stub(adbURL.path, ["mdns", "services"], stdout: "adb-X\t_adb-tls-connect._tcp\t192.168.1.23:41235\n")
    runner.stub(adbURL.path, ["connect", "192.168.1.23:41235"], stdout: "failed to connect to '192.168.1.23:41235': Connection refused\n")
    do {
        _ = try await makeConnector(runner).pairWithCode(hostPort: "192.168.1.23:37099", code: "123456") { _ in }
        Issue.record("应当失败")
    } catch let e as DeviceError {
        #expect(e.code == .CONNECTION_FAILED)
        #expect(e.message.contains("failed to connect"))
    } catch { Issue.record("意外错误 \(error)") }
}

@Test func switchToWirelessRunsTcpipThenConnect() async throws {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["-s", "R5CT", "shell", "ip -f inet addr show wlan0"], stdout: try fixtureText("ip-addr-wlan0"))
    runner.stub(adbURL.path, ["-s", "R5CT", "tcpip", "5555"], stdout: "restarting in TCP mode port: 5555\n")
    runner.stub(adbURL.path, ["connect", "192.168.1.23:5555"], stdout: "connected to 192.168.1.23:5555\n")
    let result = try await makeConnector(runner).switchToWireless(serial: "R5CT")
    #expect(result == "192.168.1.23:5555")
    #expect(runner.calls.map(\.args) == [
        ["-s", "R5CT", "shell", "ip -f inet addr show wlan0"],
        ["-s", "R5CT", "tcpip", "5555"],
        ["connect", "192.168.1.23:5555"],
    ])
}

@Test func switchToWirelessFailsWithoutWifi() async {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["-s", "R5CT", "shell", "ip -f inet addr show wlan0"], stdout: "")
    do {
        _ = try await makeConnector(runner).switchToWireless(serial: "R5CT")
        Issue.record("应当失败")
    } catch let e as DeviceError {
        #expect(e.code == .CONNECTION_FAILED)
        #expect(e.message.contains("手机未连接 Wi-Fi"))
    } catch { Issue.record("意外错误 \(error)") }
}

@Test(arguments: [
    ("", "error: device unauthorized.\n", Int32(1)),
    ("error: closed\n", "", Int32(0)),
    ("", "", Int32(0)),
])
func switchToWirelessFailsWhenTcpipFails(stdout: String, stderr: String, exitCode: Int32) async throws {
    let runner = FakeProcessRunner()
    runner.stub(adbURL.path, ["-s", "R5CT", "shell", "ip -f inet addr show wlan0"], stdout: try fixtureText("ip-addr-wlan0"))
    runner.stub(adbURL.path, ["-s", "R5CT", "tcpip", "5555"], stdout: stdout, stderr: stderr, exitCode: exitCode)
    runner.stub(adbURL.path, ["connect", "192.168.1.23:5555"], stdout: "connected to 192.168.1.23:5555\n")
    do {
        _ = try await makeConnector(runner).switchToWireless(serial: "R5CT")
        Issue.record("应当失败")
    } catch let e as DeviceError {
        #expect(e.code == .CONNECTION_FAILED)
        let detail = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { #expect(e.message.contains(detail)) }
    } catch { Issue.record("意外错误 \(error)") }
    #expect(!runner.calls.contains { $0.args.first == "connect" })
}
