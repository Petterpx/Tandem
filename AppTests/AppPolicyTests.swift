import Testing
import DeviceCore
@testable import MagicDevX

@Suite struct AppPolicyTests {
    private func dev(_ id: String, _ state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(id: id, platform: .android, name: id, state: state, connection: .usb)
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
}
