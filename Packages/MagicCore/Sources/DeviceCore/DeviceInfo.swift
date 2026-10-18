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
    /// adb serial
    public var id: String
    public var platform: Platform
    /// 展示名（model，下划线换空格）
    public var name: String
    public var state: DeviceState
    public var connection: ConnectionKind
    /// ro.serialno，用于去重
    public var hardwareSerial: String?
    public var capabilities: Set<Capability>

    public init(
        id: String,
        platform: Platform,
        name: String,
        state: DeviceState,
        connection: ConnectionKind,
        hardwareSerial: String? = nil,
        capabilities: Set<Capability> = []
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.state = state
        self.connection = connection
        self.hardwareSerial = hardwareSerial
        self.capabilities = capabilities
    }
}
