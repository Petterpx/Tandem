import Foundation

/// 剪贴板同步的防回环记录：按设备记住最后一次同步的内容，相同则跳过。
struct ClipboardSyncGuard {
    private var last: [String: String] = [:]

    /// 设备 → Mac：内容与上次同步相同则返回 false，否则记录并返回 true。
    mutating func shouldSendToMac(_ id: String, _ text: String) -> Bool {
        accept(id, text)
    }

    /// Mac → 设备：规则同上。
    mutating func shouldSendToDevice(_ id: String, _ text: String) -> Bool {
        accept(id, text)
    }

    /// 只记录内容、不做判断（手动读取 / 写入后调用，避免随后被当作新变化回传）。
    mutating func note(_ id: String, _ text: String) {
        last[id] = text
    }

    /// 清除某台设备的记录（关闭同步时调用，重新开启后重新取基准）。
    mutating func reset(_ id: String) {
        last[id] = nil
    }

    private mutating func accept(_ id: String, _ text: String) -> Bool {
        if last[id] == text { return false }
        last[id] = text
        return true
    }
}
