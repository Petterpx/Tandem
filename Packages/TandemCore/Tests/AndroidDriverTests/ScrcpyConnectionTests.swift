import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct ScrcpyConnectionTests {
    @Test func handshakeRetriesUntilDummyByte() async throws {
        let first = InMemoryByteStream(), second = InMemoryByteStream()
        first.finish()
        second.finish()
        let video = InMemoryByteStream(Data([0x00]) + Data("Pixel 8".utf8) + Data(count: 64 - 7))
        let control = InMemoryByteStream()
        let streams = [first, second, video, control]
        let attempts = Recorder<UInt16>()

        let connection = try await ScrcpyConnection.open(port: 27183, connect: { port in
            streams[attempts.append(port) - 1]
        }, retryDelay: .milliseconds(1))

        #expect(connection.deviceName == "Pixel 8")
        #expect(attempts.values.count == 4)  // 3 次视频 + 1 次控制
        #expect(first.isClosed && second.isClosed)
        #expect((connection.video as? InMemoryByteStream) === video)
        #expect((connection.control as? InMemoryByteStream) === control)
    }

    @Test func handshakeRetriesWhenConnectThrows() async throws {
        struct Refused: Error {}
        let video = InMemoryByteStream(Data([0x00]) + Data(count: 64))
        let attempts = Recorder<UInt16>()
        let connection = try await ScrcpyConnection.open(port: 1, connect: { port in
            let n = attempts.append(port)
            if n == 1 { throw Refused() }
            return n == 2 ? video : InMemoryByteStream()
        }, retryDelay: .milliseconds(1))
        #expect(connection.deviceName == "")
        #expect(attempts.values.count == 3)
    }

    @Test func handshakeGivesUpAfterRetries() async {
        let attempts = Recorder<UInt16>()
        let error = await #expect(throws: DeviceError.self) {
            _ = try await ScrcpyConnection.open(port: 1, connect: { port in
                attempts.append(port)
                let s = InMemoryByteStream()
                s.finish()
                return s
            }, retries: 3, retryDelay: .milliseconds(1))
        }
        #expect(error?.code == .CONNECTION_FAILED)
        #expect(attempts.values.count == 3)
    }

    /// 真实 scrcpy-server 在 accept 完所有 socket 之后才发设备名，所以必须先连控制 socket 再读设备名。
    @Test func deviceNameIsReadAfterControlSocketConnects() async throws {
        let video = InMemoryByteStream(Data([0x00]))
        let control = InMemoryByteStream()
        let attempts = Recorder<UInt16>()
        let open = Task {
            try await ScrcpyConnection.open(port: 1, connect: { port in
                if attempts.append(port) == 1 { return video }
                video.feed(Data("SM-G9730".utf8) + Data(count: 64 - 8))  // 控制 socket 连上后服务端才发设备名
                return control
            })
        }
        let finished = await eventually { attempts.values.count == 2 }
        if !finished { open.cancel(); video.finish() }
        #expect(finished, "握手在连控制 socket 之前就阻塞在读设备名上")
        let connection = try await open.value
        #expect(connection.deviceName == "SM-G9730")
    }

    @Test func deviceNameIsTruncatedAtFirstNul() async throws {
        var name = Data("Pixel".utf8) + Data([0]) + Data("junk".utf8)
        name += Data(count: 64 - name.count)
        let video = InMemoryByteStream(Data([0]) + name)
        let attempts = Recorder<UInt16>()
        let connection = try await ScrcpyConnection.open(port: 1, connect: { port in
            attempts.append(port) == 1 ? video : InMemoryByteStream()
        })
        #expect(connection.deviceName == "Pixel")
    }
}
