public struct DeviceError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case DEVICE_NOT_FOUND, DEVICE_UNAUTHORIZED, INJECT_PERMISSION_DENIED, UNSUPPORTED
        case AI_LOCKED, DEVICE_AMBIGUOUS, WDA_SIGN_EXPIRED, TIMEOUT, ADB_NOT_FOUND, CONNECTION_FAILED
        case INVALID_ARGUMENT, ELEMENT_NOT_FOUND, ELEMENT_AMBIGUOUS, APP_UNAVAILABLE
    }

    public var code: Code
    public var message: String
    public var suggestion: String?

    public init(code: Code, message: String, suggestion: String? = nil) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
    }

    public static func adbNotFound() -> DeviceError {
        DeviceError(
            code: .ADB_NOT_FOUND,
            message: "未找到可用的 adb",
            suggestion: "请安装 Android Platform Tools：brew install --cask android-platform-tools，或安装 Android Studio"
        )
    }

    public static func timeout(_ what: String) -> DeviceError {
        DeviceError(code: .TIMEOUT, message: "\(what)超时", suggestion: "请检查设备连接后重试")
    }

    public static func connectionFailed(_ detail: String) -> DeviceError {
        DeviceError(code: .CONNECTION_FAILED, message: "连接失败：\(detail)", suggestion: "请确认设备已开启调试并与电脑处于同一网络")
    }
}

extension DeviceError {
    /// 设备或系统版本不支持某操作。
    public static func unsupported(_ message: String) -> DeviceError {
        DeviceError(code: .UNSUPPORTED, message: message)
    }
}
