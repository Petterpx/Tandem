import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

@Test func deviceSnapshotsMapsEntriesAndCachesHardwareSerial() async throws {
    let adbURL = URL(fileURLWithPath: "/fake/adb")
    let runner = FakeProcessRunner()
    let body = "R5CT1234567\tdevice usb:1-1 product:shiba model:Pixel_8 device:shiba transport_id:3\n"
        + "9b2c8f11\tunauthorized usb:1-2 transport_id:4\n"
    let framed = Data((String(format: "%04x", body.utf8.count) + body).utf8)
    runner.stubStreamBytes(adbURL.path, ["track-devices", "-l"], chunks: [framed, framed])
    runner.stub(adbURL.path, ["-s", "R5CT1234567", "shell", "getprop", "ro.serialno"], stdout: "HW123\n")

    let client = AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner)
    let driver = AndroidDriver(adb: client, runner: runner, serverJar: URL(fileURLWithPath: "/fake/jar"), restartDelay: .seconds(60))

    var snapshots: [[DeviceInfo]] = []
    for await snapshot in driver.deviceSnapshots() {
        snapshots.append(snapshot)
        if snapshots.count == 2 { break }
    }

    let expected = [
        DeviceInfo(serial: "R5CT1234567", platform: .android, name: "Pixel 8", state: .connected, connection: .usb,
                   hardwareSerial: "HW123", capabilities: [.mirror, .touch, .keys, .text, .clipboard, .screenshot, .record, .uiTree, .network, .apps, .openURL, .devOptions, .systemSettings, .shell, .files, .logs]),
        DeviceInfo(serial: "9b2c8f11", platform: .android, name: "9b2c8f11", state: .unauthorized, connection: .usb,
                   hardwareSerial: nil, capabilities: [.mirror, .touch, .keys, .text, .clipboard, .screenshot, .record, .uiTree, .network, .apps, .openURL, .devOptions, .systemSettings, .shell, .files, .logs]),
    ]
    #expect(snapshots == [expected, expected])
    let getprops = runner.calls.filter { $0.args.contains("getprop") }
    #expect(getprops.count == 1)
}

@Test func deviceSnapshotsRestartsTrackDevicesAfterExit() async throws {
    let adbURL = URL(fileURLWithPath: "/fake/adb")
    let runner = FakeProcessRunner()
    let framed = Data("0000".utf8)
    runner.stubStreamBytes(adbURL.path, ["track-devices", "-l"], chunks: [framed])
    let client = AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner)
    let driver = AndroidDriver(adb: client, runner: runner, serverJar: URL(fileURLWithPath: "/fake/jar"), restartDelay: .milliseconds(10))

    var count = 0
    for await snapshot in driver.deviceSnapshots() {
        #expect(snapshot.isEmpty)
        count += 1
        if count == 2 { break }
    }
    #expect(runner.calls.filter { $0.args == ["track-devices", "-l"] }.count >= 2)
}

private func framedList(_ body: String) -> Data {
    Data((String(format: "%04x", body.utf8.count) + body).utf8)
}

/// 依次喂给 track-devices 的若干包，收集同样数量的快照里 serial 对应的 hardwareSerial。
private func hardwareSerials(chunks: [Data], getprops: [String], serial: String = "192.168.1.23:5555")
    async -> (serials: [String?], getpropCalls: Int) {
    let adbURL = URL(fileURLWithPath: "/fake/adb")
    let runner = FakeProcessRunner()
    runner.stubStreamBytes(adbURL.path, ["track-devices", "-l"], chunks: chunks)
    runner.stubSequence(adbURL.path, ["-s", serial, "shell", "getprop", "ro.serialno"], stdouts: getprops)
    let client = AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner)
    let driver = AndroidDriver(adb: client, runner: runner, serverJar: URL(fileURLWithPath: "/fake/jar"), restartDelay: .seconds(60))
    var result: [String?] = []
    for await snapshot in driver.deviceSnapshots() {
        result.append(snapshot.first { $0.serial == serial }?.hardwareSerial)
        if result.count == chunks.count { break }
    }
    return (result, runner.calls.filter { $0.args.contains("getprop") }.count)
}

@Test func failedHardwareSerialLookupIsRetriedOnNextSnapshot() async {
    let entry = framedList("192.168.1.23:5555\tdevice transport_id:7\n")
    let r = await hardwareSerials(chunks: [entry, entry], getprops: ["", "HW1\n"])
    #expect(r.serials == [nil, "HW1"])
    #expect(r.getpropCalls == 2)
}

@Test func hardwareSerialIsForgottenWhenSerialLeavesTheList() async {
    // 同一个 ip:port 之后换成了另一台手机：不能沿用上一台的硬件序列号。
    let entry = framedList("192.168.1.23:5555\tdevice transport_id:7\n")
    let r = await hardwareSerials(chunks: [entry, framedList(""), entry], getprops: ["HW1\n", "HW2\n"])
    #expect(r.serials == ["HW1", nil, "HW2"])
    #expect(r.getpropCalls == 2)
}

@Test func hardwareSerialIsForgottenWhenSerialStopsBeingConnected() async {
    let entry = framedList("192.168.1.23:5555\tdevice transport_id:7\n")
    let offline = framedList("192.168.1.23:5555\toffline transport_id:7\n")
    let r = await hardwareSerials(chunks: [entry, offline, entry], getprops: ["HW1\n", "HW2\n"])
    #expect(r.serials == ["HW1", nil, "HW2"])
    #expect(r.getpropCalls == 2)
}
