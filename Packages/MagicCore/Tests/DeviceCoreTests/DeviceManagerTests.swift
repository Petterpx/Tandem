import Testing
@testable import DeviceCore

private func info(
    id: String, name: String = "Pixel", state: DeviceState = .connected,
    conn: ConnectionKind = .usb, hw: String? = nil
) -> DeviceInfo {
    DeviceInfo(id: id, platform: .android, name: name, state: state, connection: conn, hardwareSerial: hw)
}

@Suite struct DeviceManagerTests {
    @Test func dedupesSamePhonePreferringUSB() {
        let usb = info(id: "R5CT1234567", conn: .usb, hw: "R5CT1234567")
        let wifi = info(id: "192.168.1.23:5555", conn: .wifi, hw: "R5CT1234567")
        #expect(DeviceManager.merge([[wifi, usb]]).map(\.id) == ["R5CT1234567"])
    }

    @Test func dedupesAcrossDrivers() {
        let usb = info(id: "A", conn: .usb, hw: "S")
        let wifi = info(id: "B", conn: .wifi, hw: "S")
        #expect(DeviceManager.merge([[wifi], [usb]]).map(\.id) == ["A"])
    }

    @Test func keepsDevicesWithoutHardwareSerial() {
        let a = info(id: "a"), b = info(id: "b")
        #expect(DeviceManager.merge([[a, b]]).map(\.id) == ["a", "b"])
    }

    @Test func keepsNonConnectedEntries() {
        let ok = info(id: "A", hw: "S")
        let off1 = info(id: "B", state: .offline, conn: .wifi, hw: "S")
        let off2 = info(id: "C", state: .unauthorized, hw: "S")
        #expect(DeviceManager.merge([[ok, off1, off2]]).map(\.id) == ["A", "B", "C"])
    }

    @Test func sortsByNameThenId() {
        let r = DeviceManager.merge([[info(id: "z", name: "A"), info(id: "b", name: "B"), info(id: "a", name: "B")]])
        #expect(r.map(\.id) == ["z", "a", "b"])
    }

    @Test func sessionIsReusedForSameId() async {
        let driver = FakeDriver()
        let manager = DeviceManager(drivers: [driver])
        var it = await manager.devices().makeAsyncIterator()
        driver.continuation.yield([info(id: "x", hw: "S")])
        let list = await it.next()
        #expect(list?.map(\.id) == ["x"])
        let s1 = await manager.session(for: "x")
        let s2 = await manager.session(for: "x")
        #expect(s1 != nil)
        #expect(s1 === s2)
        #expect(driver.madeCount == 1)
    }

    @Test func unknownIdReturnsNil() async {
        let driver = FakeDriver()
        let manager = DeviceManager(drivers: [driver])
        var it = await manager.devices().makeAsyncIterator()
        driver.continuation.yield([info(id: "x")])
        _ = await it.next()
        #expect(await manager.session(for: "nope") == nil)
    }

    @Test func mergesUpdatesFromMultipleDrivers() async {
        let d1 = FakeDriver(), d2 = FakeDriver()
        let manager = DeviceManager(drivers: [d1, d2])
        var it = await manager.devices().makeAsyncIterator()
        d1.continuation.yield([info(id: "a", name: "A")])
        #expect(await it.next()?.map(\.id) == ["a"])
        d2.continuation.yield([info(id: "b", name: "B")])
        #expect(await it.next()?.map(\.id) == ["a", "b"])
    }

    @Test func sessionSurvivesDisconnectAndReconnect() async {
        let driver = FakeDriver()
        let manager = DeviceManager(drivers: [driver])
        var it = await manager.devices().makeAsyncIterator()
        driver.continuation.yield([info(id: "x")])
        _ = await it.next()
        let a = await manager.session(for: "x")
        driver.continuation.yield([])
        _ = await it.next()
        #expect(await manager.session(for: "x") == nil)
        driver.continuation.yield([info(id: "x")])
        _ = await it.next()
        let b = await manager.session(for: "x")
        #expect(a != nil)
        #expect(a === b)
        #expect(driver.madeCount == 1)
    }
}
