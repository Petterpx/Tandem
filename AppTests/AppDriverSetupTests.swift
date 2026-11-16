import AndroidDriver
import DeviceCore
import Foundation
import IOSPhysicalDriver
import Testing
@testable import Tandem

@Suite struct AppDriverSetupTests {
    @Test func androidFailureStillDiscoversSimulator() async throws {
        let device = DeviceInfo(serial: "sim-1", platform: .ios, name: "iPhone", state: .connected, connection: .simulator)
        let setup = await AppDriverSetup.load(simulator: SnapshotDriver(devices: [device])) {
            throw DeviceError.adbNotFound()
        }
        let manager = DeviceManager(drivers: setup.drivers)
        var iterator = await manager.devices().makeAsyncIterator()
        #expect(await iterator.next() == [device])
        #expect(setup.android == nil)
        #expect(setup.androidError?.code == .ADB_NOT_FOUND)
    }

    @Test func emptySimulatorDiscoveryDoesNotHideAndroid() async throws {
        let device = DeviceInfo(serial: "android-1", platform: .android, name: "Pixel", state: .connected, connection: .usb)
        let setup = await AppDriverSetup.load(simulator: SnapshotDriver(devices: [])) {
            let adb = Adb(url: URL(fileURLWithPath: "/unused/adb"), version: "test")
            return .init(adb: adb, client: AdbClient(adb: adb, runner: SystemProcessRunner()),
                         driver: SnapshotDriver(devices: [device]))
        }
        let manager = DeviceManager(drivers: setup.drivers)
        var iterator = await manager.devices().makeAsyncIterator()
        var observed: [DeviceInfo] = []
        for _ in 0..<2 {
            observed = await iterator.next() ?? []
            if !observed.isEmpty { break }
        }
        #expect(observed == [device])
        #expect(setup.androidError == nil)
    }

    @Test func androidFailureStillDiscoversSimulatorAndPhysicalDevice() async throws {
        let simulator = DeviceInfo(serial: "sim-1", platform: .ios, name: "Simulator", state: .connected, connection: .simulator)
        let physical = DeviceInfo(serial: "ios-usb-1", platform: .ios, name: "USB iPhone", state: .connected, connection: .usb)
        let setup = await AppDriverSetup.load(simulator: SnapshotDriver(devices: [simulator]),
                                             physical: SnapshotDriver(devices: [physical])) {
            throw DeviceError.adbNotFound()
        }
        let manager = DeviceManager(drivers: setup.drivers)
        var iterator = await manager.devices().makeAsyncIterator()
        var observed: [DeviceInfo] = []
        for _ in 0..<2 {
            observed = await iterator.next() ?? []
            if observed.count == 2 { break }
        }
        #expect(Set(observed.map(\.serial)) == [simulator.serial, physical.serial])
        #expect(setup.android == nil)
        #expect(setup.androidError?.code == .ADB_NOT_FOUND)
    }

    @Test func unavailablePhysicalHelperDoesNotHideOtherPlatforms() async throws {
        let physical = IOSPhysicalDriver(helperURL: URL(fileURLWithPath: "/nonexistent/tandem-ios-usb"))
        #expect(physical.availabilityError != nil)
        let simulator = DeviceInfo(serial: "sim-1", platform: .ios, name: "Simulator", state: .connected, connection: .simulator)
        let android = DeviceInfo(serial: "android-1", platform: .android, name: "Pixel", state: .connected, connection: .usb)
        let setup = await AppDriverSetup.load(simulator: SnapshotDriver(devices: [simulator]), physical: physical) {
            let adb = Adb(url: URL(fileURLWithPath: "/unused/adb"), version: "test")
            return .init(adb: adb, client: AdbClient(adb: adb, runner: SystemProcessRunner()),
                         driver: SnapshotDriver(devices: [android]))
        }
        let manager = DeviceManager(drivers: setup.drivers)
        var iterator = await manager.devices().makeAsyncIterator()
        var observed: [DeviceInfo] = []
        for _ in 0..<3 {
            observed = await iterator.next() ?? []
            if observed.count == 2 { break }
        }
        #expect(Set(observed.map(\.serial)) == [simulator.serial, android.serial])
        #expect(setup.androidError == nil)
        #expect(setup.android != nil)
    }
}

private struct SnapshotDriver: DeviceDriver {
    var devices: [DeviceInfo]
    func deviceSnapshots() -> AsyncStream<[DeviceInfo]> {
        AsyncStream { $0.yield(devices); $0.finish() }
    }
    func makeSession(for device: DeviceInfo) -> any DeviceSession { FakeDeviceSession() }
    func makeActions(for device: DeviceInfo) -> any DeviceActions { FakeActions() }
}
