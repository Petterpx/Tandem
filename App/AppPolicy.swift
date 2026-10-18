import DeviceCore

/// 与 SwiftUI 无关的决策逻辑，便于测试。
enum AppPolicy {
    /// 设备列表更新后需要（重新）启动会话的 id（逻辑 id）：窗口开着、设备已连接、会话处于 disconnected / idle / failed。
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
        seen.formIntersection(devices.map(\.id))  // 离开列表的 id 重新插入时可再次触发
        for device in devices where device.state == .connected {
            if seen.insert(device.id).inserted && enabled { result.append(device.id) }
        }
        return result
    }

    /// 需要切换传输的 id：窗口开着、设备已连接，但会话正在另一个传输上 connecting / running
    /// （Wi-Fi 投屏中插上 USB；或转无线后拔掉 USB、会话还没发现断开）。
    static func handoverIDs(devices: [DeviceInfo], openWindowIDs: Set<String>, activeSerials: [String: String]) -> [String] {
        devices.compactMap { device in
            guard openWindowIDs.contains(device.id), device.state == .connected,
                  let active = activeSerials[device.id], active != device.serial else { return nil }
            return device.id
        }
    }

    // MARK: - 自动重连（服务端挂了但手机还连着）

    /// 连续失败超过这么多次后停止自动重连，显示「重试」。
    static let maxAutoRetries = 5

    /// 连续第 `failures` 次断开 / 失败（从 1 开始）后，等多久再自动重连：1s、2s，之后 5s；超过上限返回 nil。
    static func retryDelay(afterFailures failures: Int) -> Duration? {
        guard failures >= 1, failures <= maxAutoRetries else { return nil }
        return [.seconds(1), .seconds(2)].dropFirst(failures - 1).first ?? .seconds(5)
    }

    /// 会话自己结束（disconnected / failed）、窗口开着且设备仍是 connected 时才自动重连。
    /// 设备离线或离开列表时交给设备列表变化（reconnectIDs）处理。
    static func shouldAutoRetry(state: SessionState, windowOpen: Bool, device: DeviceInfo?) -> Bool {
        guard windowOpen, device?.state == .connected else { return false }
        switch state {
        case .disconnected, .failed: return true
        case .idle, .connecting, .running: return false
        }
    }
}
