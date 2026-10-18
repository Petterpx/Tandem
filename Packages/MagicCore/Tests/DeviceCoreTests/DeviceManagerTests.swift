import Testing
@testable import DeviceCore

private func info(
    id: String, name: String = "Pixel", state: DeviceState = .connected,
    conn: ConnectionKind = .usb, hw: String? = nil
) -> DeviceInfo {
    DeviceInfo(serial: id, platform: .android, name: name, state: state, connection: conn, hardwareSerial: hw)
}

@Suite struct DeviceManagerTests {
    @Test func logicalIdIsHardwareSerialFallingBackToAdbSerial() {
        #expect(info(id: "192.168.1.23:5555", conn: .wifi, hw: "R5CT").id == "R5CT")
        #expect(info(id: "192.168.1.23:5555", conn: .wifi).id == "192.168.1.23:5555")
    }

    @Test func dedupesSamePhonePreferringUSB() {
        let usb = info(id: "R5CT1234567", conn: .usb, hw: "R5CT1234567")
        let wifi = info(id: "192.168.1.23:5555", conn: .wifi, hw: "R5CT1234567")
        let merged = DeviceManager.merge([[wifi, usb]])
        #expect(merged.map(\.id) == ["R5CT1234567"])
        #expect(merged.map(\.serial) == ["R5CT1234567"])
    }

    @Test func dedupesAcrossDrivers() {
        let usb = info(id: "A", conn: .usb, hw: "S")
        let wifi = info(id: "B", conn: .wifi, hw: "S")
        let merged = DeviceManager.merge([[wifi], [usb]])
        #expect(merged.map(\.id) == ["S"])
        #expect(merged.map(\.serial) == ["A"])
    }

    @Test func connectedTransportWinsOverNonConnectedOneWithSameId() {
        // USB 未授权（还读不到 ro.serialno，id 退回 adb serial，恰好与硬件序列号相同）+ Wi-Fi 已连接：只保留一条。
        let usb = info(id: "S", state: .unauthorized, conn: .usb)
        let wifi = info(id: "10.0.0.2:5555", conn: .wifi, hw: "S")
        let merged = DeviceManager.merge([[usb, wifi]])
        #expect(merged.map(\.id) == ["S"])
        #expect(merged.map(\.serial) == ["10.0.0.2:5555"])
    }

    @Test func keepsDevicesWithoutHardwareSerial() {
        let a = info(id: "a"), b = info(id: "b")
        #expect(DeviceManager.merge([[a, b]]).map(\.id) == ["a", "b"])
    }

    @Test func keepsNonConnectedEntries() {
        let ok = info(id: "A", hw: "S")
        let off1 = info(id: "B", state: .offline, conn: .wifi)
        let off2 = info(id: "C", state: .unauthorized)
        #expect(DeviceManager.merge([[ok, off1, off2]]).map(\.id) == ["B", "C", "S"])
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
        #expect(list?.map(\.id) == ["S"])
        #expect(await manager.session(for: "x") == nil)  // 按逻辑 id 取，不按 adb serial
        let s1 = await manager.session(for: "S")
        let s2 = await manager.session(for: "S")
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

    // MARK: - 传输切换（同一台手机的 USB / Wi-Fi）

    /// Wi-Fi 投屏时插上 USB：逻辑 id 不变、会话实例不变，首选传输换成 USB 并推给会话。
    @Test func usbPluggedInDuringWifiKeepsSessionAndSwitchesSerial() async throws {
        let driver = FakeDriver()
        let manager = DeviceManager(drivers: [driver])
        var it = await manager.devices().makeAsyncIterator()
        let wifi = info(id: "192.168.1.23:5555", conn: .wifi, hw: "S")
        let usb = info(id: "S", conn: .usb, hw: "S")
        driver.continuation.yield([wifi])
        #expect(await it.next()?.map(\.serial) == ["192.168.1.23:5555"])
        let session = try #require(await manager.session(for: "S") as? FakeSession)
        #expect(session.device.serial == "192.168.1.23:5555")

        driver.continuation.yield([wifi, usb])
        let list = await it.next()
        #expect(list?.map(\.id) == ["S"])
        #expect(list?.map(\.serial) == ["S"])
        #expect(list?.first?.connection == .usb)
        #expect(await manager.session(for: "S") === session)
        #expect(session.device.serial == "S")
        #expect(session.device.connection == .usb)
        #expect(driver.madeCount == 1)
    }

    /// 一键转无线后拔掉 USB：逻辑 id 不变、会话实例不变，首选传输退回 Wi-Fi。
    @Test func usbUnpluggedAfterSwitchToWirelessFallsBackToWifi() async throws {
        let driver = FakeDriver()
        let manager = DeviceManager(drivers: [driver])
        var it = await manager.devices().makeAsyncIterator()
        let usb = info(id: "S", conn: .usb, hw: "S")
        let wifi = info(id: "192.168.1.23:5555", conn: .wifi, hw: "S")
        driver.continuation.yield([usb, wifi])
        #expect(await it.next()?.map(\.serial) == ["S"])
        let session = try #require(await manager.session(for: "S") as? FakeSession)

        driver.continuation.yield([wifi])
        let list = await it.next()
        #expect(list?.map(\.id) == ["S"])
        #expect(list?.map(\.serial) == ["192.168.1.23:5555"])
        #expect(await manager.session(for: "S") === session)
        #expect(session.device.serial == "192.168.1.23:5555")
        #expect(session.device.connection == .wifi)
        #expect(driver.madeCount == 1)
    }
}
