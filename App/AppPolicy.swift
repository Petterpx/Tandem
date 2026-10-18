import DeviceCore

/// 与 SwiftUI 无关的决策逻辑，便于测试。
enum AppPolicy {
    /// 设备列表更新后需要（重新）启动会话的 id：窗口开着、设备已连接、会话处于 disconnected / idle / failed。
    static func reconnectIDs(
        devices: [DeviceInfo],
        openWindowIDs: Set<String>,
        states: [String: SessionState]
    ) -> [String] {
        devices.compactMap { device in
            guard openWindowIDs.contains(device.id), device.state == .connected else { return nil }
            switch states[device.id] ?? .idle {
            case .disconnected, .idle, .failed: return device.id
            case .connecting, .running: return nil
            }
        }
    }

    /// 首次以 connected 出现的 id（每个 id 只触发一次）。`seen` 无论是否启用都会记录，避免之后开启时补开旧设备。
    static func autoOpenIDs(devices: [DeviceInfo], seen: inout Set<String>, enabled: Bool) -> [String] {
        var result: [String] = []
        for device in devices where device.state == .connected {
            if seen.insert(device.id).inserted && enabled { result.append(device.id) }
        }
        return result
    }
}
