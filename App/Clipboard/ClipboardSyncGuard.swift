import Foundation

/// 剪贴板同步的防回环记录：按设备记住最后一次同步的内容，相同则跳过。
struct ClipboardSyncGuard {
    private var last: [String: String] = [:]

    /// 设备端剪贴板文本上限（UTF-8 字节），对应 ControlMessage.clipboardTextMaxLength（AndroidDriver 内部常量）；
    /// 超出的文本会被截断后才写到设备上。
    static let deviceTextMaxBytes = (1 << 18) - 14

    /// 设备 → Mac：设备读到的内容与上次同步一致（含被截断的回读）则返回 false，否则记录并返回 true。
    mutating func shouldSendToMac(_ id: String, _ text: String) -> Bool {
        if isEcho(id, text) { return false }
        last[id] = text
        return true
    }

    /// Mac → 设备：只判断、不记录；推送成功后再调用 note，失败则保持原记录。
    func shouldSendToDevice(_ id: String, _ text: String) -> Bool {
        last[id] != text
    }

    /// 设备读到的 `read` 是否是已记录内容的回读：完全相同，
    /// 或记录的文本超过上限、`read` 是它按字节截断的非空前缀。
    func isEcho(_ id: String, _ read: String) -> Bool {
        guard let recorded = last[id] else { return false }
        if recorded == read { return true }
        return !read.isEmpty
            && recorded.utf8.count > Self.deviceTextMaxBytes
            && recorded.utf8.starts(with: read.utf8)
    }

    /// 只记录内容、不做判断（手动读取 / 写入后调用，避免随后被当作新变化回传）。
    mutating func note(_ id: String, _ text: String) {
        last[id] = text
    }

    /// 清除某台设备的记录（关闭同步时调用，重新开启后重新取基准）。
    mutating func reset(_ id: String) {
        last[id] = nil
    }
}
