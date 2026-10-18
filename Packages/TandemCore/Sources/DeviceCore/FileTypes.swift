import Foundation

/// 设备上的文件或目录条目。
public struct RemoteFile: Equatable, Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var name: String
    public var path: String
    public var kind: Kind
    public var size: UInt64
    public var modified: Date

    public init(name: String, path: String, kind: Kind, size: UInt64, modified: Date) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// 传输进度；total 未知时无比例。
public struct TransferProgress: Equatable, Sendable {
    public var bytes: UInt64
    public var total: UInt64?

    public init(bytes: UInt64, total: UInt64?) {
        self.bytes = bytes
        self.total = total
    }

    /// 0...1 的完成比例；total 为 nil 或 0 时为 nil。
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(bytes) / Double(total)
    }
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

/// 设备路径校验：须为绝对路径，且不含 NUL 与换行。
public enum DevicePath {
    public static func validate(_ s: String) throws -> String {
        guard s.hasPrefix("/"), !s.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "设备路径不合法：\(s)")
        }
        return s
    }
}
