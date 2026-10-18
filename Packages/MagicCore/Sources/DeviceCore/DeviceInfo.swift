public enum Platform: String, Sendable {
    case android, ios
}

public enum ConnectionKind: String, Sendable {
    case usb, wifi
}

public enum DeviceState: Equatable, Sendable {
    case connected, unauthorized, offline
}

public struct DeviceInfo: Identifiable, Equatable, Sendable {
    /// 逻辑设备 id：硬件序列号（ro.serialno），读不到时退回 adb serial。
    /// 同一台手机的 USB 与 Wi-Fi 传输共用这个 id；窗口与会话都按它管理。
    public var id: String { hardwareSerial ?? serial }
    /// 当前首选传输的 adb serial（USB 序列号或 ip:port），所有 adb 调用都用它。
    public var serial: String
    public var platform: Platform
    /// 展示名（model，下划线换空格）
    public var name: String
    public var state: DeviceState
    /// `serial` 对应的传输方式
    public var connection: ConnectionKind
    /// ro.serialno，仅在 connected 时读取
    public var hardwareSerial: String?
    public var capabilities: Set<Capability>

    public init(
        serial: String,
        platform: Platform,
        name: String,
        state: DeviceState,
        connection: ConnectionKind,
        hardwareSerial: String? = nil,
        capabilities: Set<Capability> = []
    ) {
        self.serial = serial
        self.platform = platform
        self.name = name
        self.state = state
        self.connection = connection
        self.hardwareSerial = hardwareSerial
        self.capabilities = capabilities
    }
}
