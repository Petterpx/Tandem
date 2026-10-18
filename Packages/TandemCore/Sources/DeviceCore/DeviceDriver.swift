public protocol DeviceDriver: Sendable {
    func deviceSnapshots() -> AsyncStream<[DeviceInfo]>
    func makeSession(for device: DeviceInfo) -> any DeviceSession
    /// 创建不依赖投屏会话的设备操作；按传入 DeviceInfo 的当前 serial 绑定。
    func makeActions(for device: DeviceInfo) -> any DeviceActions
}
