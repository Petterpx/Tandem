import Testing
import DeviceCore
@testable import MagicDevX

@Suite struct AppPolicyTests {
    private func dev(_ id: String, _ state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(serial: id, platform: .android, name: id, state: state, connection: .usb)
    }

    /// 同一台手机（硬件序列号 S），当前首选传输为 serial。
    private func phone(_ serial: String, _ conn: ConnectionKind, _ state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(serial: serial, platform: .android, name: "Phone", state: state, connection: conn, hardwareSerial: "S")
    }

    @Test func reconnectOnlyForOpenConnectedAndInactive() {
        let devices = [dev("a"), dev("b"), dev("c", .offline), dev("d"), dev("e"), dev("f")]
        let states: [String: SessionState] = [
            "a": .disconnected, "b": .running(width: 1, height: 1), "c": .disconnected,
            "d": .failed(DeviceError(code: .TIMEOUT, message: "x")), "e": .connecting, "f": .idle,
        ]
        let open: Set<String> = ["a", "b", "c", "d", "e", "f", "z"]
        let ids = AppPolicy.reconnectIDs(devices: devices, openWindowIDs: open, states: states)
        #expect(Set(ids) == ["a", "d", "f"])
    }

    @Test func reconnectSkipsClosedWindows() {
        let ids = AppPolicy.reconnectIDs(devices: [dev("a")], openWindowIDs: [], states: ["a": .disconnected])
        #expect(ids.isEmpty)
    }

    @Test func reconnectTreatsMissingStateAsIdle() {
        let ids = AppPolicy.reconnectIDs(devices: [dev("a")], openWindowIDs: ["a"], states: [:])
        #expect(ids == ["a"])
    }

    @Test func autoOpenFiresOncePerID() {
        var seen = Set<String>()
        let first = AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: true)
        #expect(first == ["a"])
        let second = AppPolicy.autoOpenIDs(devices: [dev("a"), dev("b")], seen: &seen, enabled: true)
        #expect(second == ["b"])
        let third = AppPolicy.autoOpenIDs(devices: [dev("a"), dev("b")], seen: &seen, enabled: true)
        #expect(third.isEmpty)
    }

    @Test func autoOpenWaitsForConnectedState() {
        var seen = Set<String>()
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a", .unauthorized)], seen: &seen, enabled: true).isEmpty)
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: true) == ["a"])
    }

    @Test func autoOpenDisabledDoesNotFireNorBackfill() {
        var seen = Set<String>()
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: false).isEmpty)
        // 之后开启，已存在的设备不会补开窗口
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: true).isEmpty)
    }

    @Test func autoOpenFiresAgainAfterReplug() {
        var seen = Set<String>()
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: true) == ["a"])
        #expect(AppPolicy.autoOpenIDs(devices: [], seen: &seen, enabled: true).isEmpty)
        #expect(AppPolicy.autoOpenIDs(devices: [dev("a")], seen: &seen, enabled: true) == ["a"])
    }

    // MARK: - 传输切换

    /// Wi-Fi 投屏中插上 USB：首选传输变为 USB，会话仍跑在 Wi-Fi 上 → 需要在 USB 上重启。
    @Test func handoverWhenUSBPluggedInDuringWifi() {
        let ids = AppPolicy.handoverIDs(devices: [phone("S", .usb)], openWindowIDs: ["S"],
                                        activeSerials: ["S": "192.168.1.23:5555"])
        #expect(ids == ["S"])
    }

    /// 转无线后拔掉 USB：剩下 Wi-Fi，会话还挂在已消失的 USB 传输上 → 需要在 Wi-Fi 上重连。
    @Test func handoverWhenUSBUnpluggedAfterSwitchToWireless() {
        let ids = AppPolicy.handoverIDs(devices: [phone("192.168.1.23:5555", .wifi)], openWindowIDs: ["S"],
                                        activeSerials: ["S": "S"])
        #expect(ids == ["S"])
    }

    @Test func noHandoverWhenTransportUnchangedOrNotApplicable() {
        let usb = phone("S", .usb)
        // 已在首选传输上
        #expect(AppPolicy.handoverIDs(devices: [usb], openWindowIDs: ["S"], activeSerials: ["S": "S"]).isEmpty)
        // 没有进行中的 run（由 reconnectIDs 负责）
        #expect(AppPolicy.handoverIDs(devices: [usb], openWindowIDs: ["S"], activeSerials: [:]).isEmpty)
        // 窗口已关闭
        #expect(AppPolicy.handoverIDs(devices: [usb], openWindowIDs: [], activeSerials: ["S": "x:5555"]).isEmpty)
        // 设备未处于 connected
        #expect(AppPolicy.handoverIDs(devices: [phone("S", .usb, .unauthorized)], openWindowIDs: ["S"],
                                      activeSerials: ["S": "x:5555"]).isEmpty)
    }

    @Test func reconnectUsesLogicalID() {
        let ids = AppPolicy.reconnectIDs(devices: [phone("192.168.1.23:5555", .wifi)], openWindowIDs: ["S"],
                                         states: ["S": .disconnected])
        #expect(ids == ["S"])
    }
}
