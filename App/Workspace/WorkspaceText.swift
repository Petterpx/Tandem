import CoreGraphics
import DeviceCore

/// 工作台投屏区的文案。
enum WorkspaceText {
    /// 「系统 · 分辨率 · 连接方式」，缺哪项省哪项；DeviceInfo 没有系统版本，不显示版本。
    static func deviceMeta(platform: Platform, runningSize: CGSize?, connection: ConnectionKind) -> String {
        var parts = [platform == .android ? "Android" : "iOS"]
        if let size = runningSize, size.width > 0, size.height > 0 {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        parts.append(connection == .usb ? "USB" : "Wi-Fi")
        return parts.joined(separator: " · ")
    }

    static func popToggleTitle(popped: Bool) -> String {
        popped ? "收回独立窗口" : "弹出为独立窗口"
    }
}

/// 投屏区头部的状态胶囊。
enum MirrorStatus: Equatable {
    case running, connecting, popped, stopped, unauthorized, offline, failed

    var title: String {
        switch self {
        case .running: "实时"
        case .connecting: "连接中"
        case .popped: "已弹出"
        case .stopped: "未投屏"
        case .unauthorized: "未授权"
        case .offline: "已断开"
        case .failed: "失败"
        }
    }

    var tone: ChipTone {
        switch self {
        case .running: .success
        case .failed: .danger
        case .connecting, .popped, .stopped, .unauthorized, .offline: .neutral
        }
    }

    /// 依次看：设备在不在、是否授权、是否已弹出、是否想投屏，最后看会话状态。
    static func resolve(isPresent: Bool, deviceState: DeviceState, popped: Bool, wanted: Bool, session: SessionState) -> MirrorStatus {
        if !isPresent || deviceState == .offline { return .offline }
        if deviceState == .unauthorized { return .unauthorized }
        if popped { return .popped }
        guard wanted else { return .stopped }
        switch session {
        case .running: return .running
        case .idle, .connecting: return .connecting
        case .disconnected: return .offline
        case .failed: return .failed
        }
    }
}
