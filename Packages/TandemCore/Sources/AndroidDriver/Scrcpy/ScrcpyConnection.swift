import DeviceCore
import Foundation

/// scrcpy 的视频 + 控制两条 socket（audio=false 时只有这两条）。
public struct ScrcpyConnection: Sendable {
    public var deviceName: String
    public var video: any ByteStream
    public var control: any ByteStream

    static let deviceNameLength = 64

    public init(deviceName: String, video: any ByteStream, control: any ByteStream) {
        self.deviceName = deviceName
        self.video = video
        self.control = control
    }

    /// forward 隧道握手：服务端就绪前，adb 会接受连接但立即关闭，所以要等到读到 dummy byte 为止。
    /// 之后连接控制 socket，再从视频 socket 读 64 字节设备名——服务端（DesktopConnection.open）accept 完
    /// 所有 socket 才发设备名，先读设备名会死锁（与 scrcpy 客户端 server.c 的顺序一致）。
    public static func open(port: UInt16, connect: @Sendable (UInt16) async throws -> any ByteStream,
                            retries: Int = 100, retryDelay: Duration = .milliseconds(100)) async throws -> ScrcpyConnection {
        var video: (any ByteStream)?
        for attempt in 1...max(1, retries) {
            try Task.checkCancellation()
            if let stream = try? await connect(port) {
                if (try? await stream.readExactly(1)) != nil {
                    video = stream
                    break
                }
                stream.close()
            }
            if attempt < retries { try await Task.sleep(for: retryDelay) }
        }
        guard let video else {
            throw DeviceError.connectionFailed("无法连接 scrcpy 服务（端口 \(port)）")
        }

        var control: (any ByteStream)?
        do {
            let connected = try await connect(port)
            control = connected
            let raw = try await video.readExactly(deviceNameLength)
            let name = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return ScrcpyConnection(deviceName: name, video: video, control: connected)
        } catch {
            video.close()
            control?.close()
            if error is CancellationError { throw error }
            throw error as? DeviceError ?? DeviceError.connectionFailed("scrcpy 握手失败：\(error)")
        }
    }
}
