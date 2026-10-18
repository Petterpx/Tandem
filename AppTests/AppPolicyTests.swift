import Testing
import DeviceCore
@testable import Tandem

@Suite struct AppPolicyTests {
    private func dev(_ id: String, _ state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(serial: id, platform: .android, name: id, state: state, connection: .usb)
    }

    /// 同一台手机（硬件序列号 S），当前首选传输为 serial。
    private func phone(_ serial: String, _ conn: ConnectionKind, _ state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(serial: serial, platform: .android, name: "Phone", state: state, connection: conn, hardwareSerial: "S")
    }

    @Test func reconnectOnlyForWantedConnectedAndInactive() {
        let devices = [dev("a"), dev("b"), dev("c", .offline), dev("d"), dev("e"), dev("f")]
        let states: [String: SessionState] = [
            "a": .disconnected, "b": .running(width: 1, height: 1), "c": .disconnected,
            "d": .failed(DeviceError(code: .TIMEOUT, message: "x")), "e": .connecting, "f": .idle,
        ]
        let wanted: Set<String> = ["a", "b", "c", "d", "e", "f", "z"]
        let ids = AppPolicy.reconnectIDs(devices: devices, wanted: wanted, states: states)
        #expect(Set(ids) == ["a", "d", "f"])
    }

    @Test func reconnectSkipsUnwanted() {
        let ids = AppPolicy.reconnectIDs(devices: [dev("a")], wanted: [], states: ["a": .disconnected])
        #expect(ids.isEmpty)
    }

    @Test func reconnectTreatsMissingStateAsIdle() {
        let ids = AppPolicy.reconnectIDs(devices: [dev("a")], wanted: ["a"], states: [:])
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
        let ids = AppPolicy.handoverIDs(devices: [phone("S", .usb)], wanted: ["S"],
                                        activeSerials: ["S": "192.168.1.23:5555"])
        #expect(ids == ["S"])
    }

    /// 转无线后拔掉 USB：剩下 Wi-Fi，会话还挂在已消失的 USB 传输上 → 需要在 Wi-Fi 上重连。
    @Test func handoverWhenUSBUnpluggedAfterSwitchToWireless() {
        let ids = AppPolicy.handoverIDs(devices: [phone("192.168.1.23:5555", .wifi)], wanted: ["S"],
                                        activeSerials: ["S": "S"])
        #expect(ids == ["S"])
    }

    @Test func noHandoverWhenTransportUnchangedOrNotApplicable() {
        let usb = phone("S", .usb)
        // 已在首选传输上
        #expect(AppPolicy.handoverIDs(devices: [usb], wanted: ["S"], activeSerials: ["S": "S"]).isEmpty)
        // 没有进行中的 run（由 reconnectIDs 负责）
        #expect(AppPolicy.handoverIDs(devices: [usb], wanted: ["S"], activeSerials: [:]).isEmpty)
        // 不在 wanted 中
        #expect(AppPolicy.handoverIDs(devices: [usb], wanted: [], activeSerials: ["S": "x:5555"]).isEmpty)
        // 设备未处于 connected
        #expect(AppPolicy.handoverIDs(devices: [phone("S", .usb, .unauthorized)], wanted: ["S"],
                                      activeSerials: ["S": "x:5555"]).isEmpty)
    }

    @Test func reconnectUsesLogicalID() {
        let ids = AppPolicy.reconnectIDs(devices: [phone("192.168.1.23:5555", .wifi)], wanted: ["S"],
                                         states: ["S": .disconnected])
        #expect(ids == ["S"])
    }

    // MARK: - 自动重连退避

    @Test func retryBackoffIsOneTwoFiveSecondsThenGivesUp() {
        let delays = (1...7).map { AppPolicy.retryDelay(afterFailures: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(5), .seconds(5), .seconds(5), nil, nil])
        #expect(AppPolicy.retryDelay(afterFailures: AppPolicy.maxAutoRetries + 1) == nil)
    }

    @Test func autoRetryOnlyForWantedConnectedDevice() {
        let error = DeviceError(code: .CONNECTION_FAILED, message: "x")
        // 服务端挂了但手机还连着：断开 / 失败都自动重连
        #expect(AppPolicy.shouldAutoRetry(state: .disconnected, wanted: true, device: dev("a")))
        #expect(AppPolicy.shouldAutoRetry(state: .failed(error), wanted: true, device: dev("a")))
        // 正常状态、用户停止（idle）不重连
        #expect(!AppPolicy.shouldAutoRetry(state: .idle, wanted: true, device: dev("a")))
        #expect(!AppPolicy.shouldAutoRetry(state: .connecting, wanted: true, device: dev("a")))
        #expect(!AppPolicy.shouldAutoRetry(state: .running(width: 1, height: 1), wanted: true, device: dev("a")))
        // 不再需要运行、设备不在或不是 connected：等设备列表变化再说
        #expect(!AppPolicy.shouldAutoRetry(state: .disconnected, wanted: false, device: dev("a")))
        #expect(!AppPolicy.shouldAutoRetry(state: .disconnected, wanted: true, device: nil))
        #expect(!AppPolicy.shouldAutoRetry(state: .disconnected, wanted: true, device: dev("a", .offline)))
    }

    /// 自动重连用尽后，设备再次出现（离线 → 已连接、或重新进入列表）时重新获得自动重连。
    @Test func retryBudgetResetsWhenDeviceComesBack() {
        #expect(AppPolicy.shouldResetRetries(previous: .offline, current: .connected) == true)
        #expect(AppPolicy.shouldResetRetries(previous: .unauthorized, current: .connected) == true)
        #expect(AppPolicy.shouldResetRetries(previous: nil, current: .connected) == true)
        #expect(AppPolicy.shouldResetRetries(previous: .connected, current: .connected) == false)
        #expect(AppPolicy.shouldResetRetries(previous: .connected, current: .offline) == false)
        #expect(AppPolicy.shouldResetRetries(previous: nil, current: .offline) == false)
    }
}
