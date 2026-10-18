import Foundation

/// 不依赖投屏会话的设备操作。
public protocol DeviceActions: Sendable {
    /// 截图，返回设备原分辨率的 PNG 数据。
    func screenshot() async throws -> Data
    /// 读取当前界面结构。
    func uiTree() async throws -> UITree
}
