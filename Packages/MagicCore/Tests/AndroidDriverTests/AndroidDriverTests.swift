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
        DeviceInfo(id: "R5CT1234567", platform: .android, name: "Pixel 8", state: .connected, connection: .usb,
                   hardwareSerial: "HW123", capabilities: [.mirror, .touch, .keys, .text, .clipboard]),
        DeviceInfo(id: "9b2c8f11", platform: .android, name: "9b2c8f11", state: .unauthorized, connection: .usb,
                   hardwareSerial: nil, capabilities: [.mirror, .touch, .keys, .text, .clipboard]),
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
