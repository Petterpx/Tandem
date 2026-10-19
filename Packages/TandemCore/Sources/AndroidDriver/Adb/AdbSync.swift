import DeviceCore
import Foundation

/// adb server 的 host 请求：4 位十六进制长度 + 内容，应答 OKAY / FAIL。
public enum AdbHost {
    public static func request(_ stream: any ByteStream, _ service: String) async throws {
        try await stream.write(Data(String(format: "%04x", service.utf8.count).utf8) + Data(service.utf8))
        let status = try await stream.readExactly(4)
        switch String(decoding: status, as: UTF8.self) {
        case "OKAY":
            return
        case "FAIL":
            throw DeviceError.connectionFailed(try await readLengthPrefixed(stream))
        default:
            throw DeviceError.connectionFailed("adb 应答异常：\(String(decoding: status, as: UTF8.self))")
        }
    }

    /// `host-serial:<serial>:features`，在独立连接上调用（server 回复后关闭连接）。
    public static func features(_ stream: any ByteStream, serial: String) async throws -> Set<String> {
        try await request(stream, "host-serial:\(serial):features")
        let list = try await readLengthPrefixed(stream)
        return Set(list.split(separator: ",").map(String.init))
    }

    private static func readLengthPrefixed(_ stream: any ByteStream) async throws -> String {
        let header = String(decoding: try await stream.readExactly(4), as: UTF8.self)
        guard let length = Int(header, radix: 16) else {
            throw DeviceError.connectionFailed("adb 应答长度异常：\(header)")
        }
        return String(decoding: try await stream.readExactly(length), as: UTF8.self)
    }
}

/// adb sync 协议会话（AOSP file_sync_protocol.h），整数一律小端。
public final class AdbSyncSession: @unchecked Sendable {
    let stream: any ByteStream
    let features: Set<String>

    init(stream: any ByteStream, features: Set<String>) {
        self.stream = stream
        self.features = features
    }

    /// 在一条全新连接上依次切到设备 transport 和 sync 模式。
    public static func open(_ stream: any ByteStream, serial: String, features: Set<String>) async throws -> AdbSyncSession {
        try await AdbHost.request(stream, "host:transport:\(serial)")
        try await AdbHost.request(stream, "sync:")
        return AdbSyncSession(stream: stream, features: features)
    }

    public func stat(_ path: String) async throws -> RemoteFile? {
        let v2 = features.contains("stat_v2")
        try await sendRequest(v2 ? "STA2" : "STAT", path)
        let id = try await readID()
        if id == "FAIL" { throw try await readFailure("sync 失败：") }
        let body = Fields(try await stream.readExactly(v2 ? 68 : 12))
        if v2 {
            guard id == "STA2" else { throw Self.unexpected(id) }
            let error = body.u32(0), mode = body.u32(20), size = body.u64(36), mtime = body.i64(52)
            guard error == 0 else { return nil }
            return Self.file(path: path, mode: mode, size: size, mtime: mtime)
        }
        guard id == "STAT" else { throw Self.unexpected(id) }
        let mode = body.u32(0)
        guard mode != 0 else { return nil }
        return Self.file(path: path, mode: mode, size: UInt64(body.u32(4)), mtime: Int64(body.u32(8)))
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        let v2 = features.contains("ls_v2")
        try await sendRequest(v2 ? "LIS2" : "LIST", path)
        let entryID = v2 ? "DNT2" : "DENT"
        var result: [RemoteFile] = []
        while true {
            let id = try await readID()
            if id == "FAIL" { throw try await readFailure("sync 失败：") }
            let head = Fields(try await stream.readExactly(v2 ? 72 : 16))
            if id == "DONE" { return result }
            guard id == entryID else { throw Self.unexpected(id) }
            let mode: UInt32, size: UInt64, mtime: Int64, nameLength: Int
            if v2 {
                // DNT2 与 STA2 同布局（含 error），其后是 namelen。
                (mode, size, mtime, nameLength) = (head.u32(20), head.u64(36), head.i64(52), Int(head.u32(68)))
            } else {
                (mode, size, mtime, nameLength) = (head.u32(0), UInt64(head.u32(4)), Int64(head.u32(8)), Int(head.u32(12)))
            }
            guard nameLength <= Self.maxNameLength else { throw Self.unexpected("namelen \(nameLength)") }
            let name = String(decoding: try await stream.readExactly(nameLength), as: UTF8.self)
            if name == "." || name == ".." { continue }
            result.append(Self.file(path: Self.join(path, name), mode: mode, size: size, mtime: mtime))
        }
    }

    /// 推送：`read` 按需给出至多 64 KB 的块，返回 nil 表示结束；`progress` 收到累计字节数。
    public func send(
        _ path: String, mode: UInt32, mtime: Date,
        read: (Int) throws -> Data?, progress: (UInt64) -> Void
    ) async throws {
        try await transfer {
            try await sendRequest("SEND", "\(path),\(mode)")
            var total: UInt64 = 0
            while let chunk = try read(Self.chunkSize) {
                try Task.checkCancellation()
                guard chunk.count <= Self.chunkSize else { throw Self.unexpected("DATA \(chunk.count)") }
                if chunk.isEmpty { continue }
                try await stream.write(Data("DATA".utf8) + Self.le32(UInt32(chunk.count)) + chunk)
                total += UInt64(chunk.count)
                progress(total)
            }
            try Task.checkCancellation()
            let seconds = UInt32(clamping: max(0, Int64(mtime.timeIntervalSince1970)))
            try await stream.write(Data("DONE".utf8) + Self.le32(seconds))
            let id = try await readID()
            let word = try await stream.readExactly(4)
            switch id {
            case "OKAY": return
            case "FAIL": throw try await readFailure("推送失败：", length: word)
            default: throw Self.unexpected(id)
            }
        }
    }

    /// 拉取：逐块回调 `write`，`progress` 收到累计字节数。
    public func recv(_ path: String, write: (Data) throws -> Void, progress: (UInt64) -> Void) async throws {
        try await transfer {
            try await sendRequest("RECV", path)
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let id = try await readID()
                let word = try await stream.readExactly(4)
                switch id {
                case "DATA":
                    let length = Int(Fields(word).u32(0))
                    guard length <= Self.chunkSize else { throw Self.unexpected("DATA \(length)") }
                    try write(try await stream.readExactly(length))
                    total += UInt64(length)
                    progress(total)
                case "DONE": return
                case "FAIL": throw try await readFailure("拉取失败：", length: word)
                default: throw Self.unexpected(id)
                }
            }
        }
    }

    /// 告知对端结束并关闭连接。
    public func quit() {
        let stream = stream
        Task {
            try? await stream.write(Data("QUIT".utf8) + Data(count: 4))
            stream.close()
        }
    }

    // MARK: 内部

    func sendRequest(_ id: String, _ path: String) async throws {
        let bytes = Data(path.utf8)
        var packet = Data(id.utf8)
        packet.append(Self.le32(UInt32(bytes.count)))
        packet.append(bytes)
        try await stream.write(packet)
    }

    static let chunkSize = 65536
    static let maxNameLength = 4096

    func readID() async throws -> String {
        String(decoding: try await stream.readExactly(4), as: UTF8.self)
    }

    /// 读 `FAIL` 之后的长度与原因；`length` 已读出时直接传入。
    func readFailure(_ prefix: String, length: Data? = nil) async throws -> DeviceError {
        let raw: Data
        if let length { raw = length } else { raw = try await stream.readExactly(4) }
        let n = Int(Fields(raw).u32(0))
        guard n <= Self.chunkSize else { throw Self.unexpected("FAIL \(n)") }
        let reason = String(decoding: try await stream.readExactly(n), as: UTF8.self)
        return DeviceError(code: .CONNECTION_FAILED, message: prefix + reason)
    }

    /// 传输外壳：取消时关闭流并抛 CancellationError，中途断流报「连接中断」。
    private func transfer(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch is CancellationError {
            stream.close()
            throw CancellationError()
        } catch ByteStreamError.closed {
            stream.close()
            if Task.isCancelled { throw CancellationError() }
            throw DeviceError(code: .CONNECTION_FAILED, message: "连接中断")
        }
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func unexpected(_ id: String) -> DeviceError {
        DeviceError.connectionFailed("sync 应答异常：\(id)")
    }

    /// 父路径与名称拼接，处理父路径末尾的 `/`。
    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    private static func file(path: String, mode: UInt32, size: UInt64, mtime: Int64) -> RemoteFile {
        let kind: RemoteFile.Kind
        switch mode & 0o170000 {
        case 0o100000: kind = .file
        case 0o040000: kind = .directory
        case 0o120000: kind = .symlink
        default: kind = .other
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return RemoteFile(name: name, path: path, kind: kind, size: size,
                          modified: Date(timeIntervalSince1970: TimeInterval(mtime)))
    }

    /// 按偏移读取小端整数的只读视图。
    struct Fields {
        private let bytes: [UInt8]
        init(_ data: Data) { bytes = [UInt8](data) }

        func u32(_ at: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
        }

        func u64(_ at: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
        }

        func i64(_ at: Int) -> Int64 { Int64(bitPattern: u64(at)) }
    }
}
