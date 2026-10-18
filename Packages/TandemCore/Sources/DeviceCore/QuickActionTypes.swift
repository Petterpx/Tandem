import Foundation

/// 网络开关种类。
public enum NetworkKind: String, Sendable, CaseIterable {
    case wifi, data, airplane
}

/// 网络开关状态，nil 表示未知。
public struct NetworkState: Equatable, Sendable {
    public var wifi: Bool?
    public var data: Bool?
    public var airplane: Bool?

    public init(wifi: Bool? = nil, data: Bool? = nil, airplane: Bool? = nil) {
        self.wifi = wifi
        self.data = data
        self.airplane = airplane
    }

    public subscript(kind: NetworkKind) -> Bool? {
        switch kind {
        case .wifi: wifi
        case .data: data
        case .airplane: airplane
        }
    }
}

/// 前台应用信息。
public struct AppInfo: Equatable, Sendable {
    public var package: String
    public var activity: String?
    public var versionName: String?

    public init(package: String, activity: String? = nil, versionName: String? = nil) {
        self.package = package
        self.activity = activity
        self.versionName = versionName
    }
}

/// 可设置的开发者选项。
public enum DevOption: Equatable, Sendable {
    case showTouches(Bool), layoutBounds(Bool), stayAwake(Bool), animationScale(Double)
    /// 动画倍速可选值。
    public static let animationScales: [Double] = [0, 0.5, 1, 2, 5, 10]
}

/// 开发者选项当前值，nil 表示未知。
public struct DevOptions: Equatable, Sendable {
    public var showTouches: Bool?
    public var layoutBounds: Bool?
    public var stayAwake: Bool?
    public var animationScale: Double?

    public init(showTouches: Bool? = nil, layoutBounds: Bool? = nil, stayAwake: Bool? = nil, animationScale: Double? = nil) {
        self.showTouches = showTouches
        self.layoutBounds = layoutBounds
        self.stayAwake = stayAwake
        self.animationScale = animationScale
    }
}

/// 可设置的系统项。
public enum SystemSetting: Equatable, Sendable {
    case darkMode(Bool), fontScale(Double)
    /// `tag == ""` 表示跟随系统。
    case appLocale(package: String, tag: String)
    /// 字体缩放可选值。
    public static let fontScales: [Double] = [0.85, 1.0, 1.15, 1.3]
}

/// 系统设置当前值，nil 表示未知。
public struct SystemSettings: Equatable, Sendable {
    public var darkMode: Bool?
    public var fontScale: Double?
    public var appLocale: String?
    public var appLocaleSupported: Bool

    public init(darkMode: Bool? = nil, fontScale: Double? = nil, appLocale: String? = nil, appLocaleSupported: Bool) {
        self.darkMode = darkMode
        self.fontScale = fontScale
        self.appLocale = appLocale
        self.appLocaleSupported = appLocaleSupported
    }
}

/// 一次 shell 命令的执行结果。
public struct ShellResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

/// 包名校验，防止注入 shell。
public enum PackageName {
    public static func validate(_ s: String) throws -> String {
        guard s.range(of: #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "包名不合法：\(s)")
        }
        return s
    }
}
