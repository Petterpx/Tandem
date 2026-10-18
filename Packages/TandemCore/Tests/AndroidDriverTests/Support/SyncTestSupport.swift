import Foundation
import DeviceCore
@testable import AndroidDriver

func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

/// 依次交出预置的流；`failFirst` 为真时第一次调用抛错。
final class StreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [InMemoryByteStream]
    private var failures: Int
    private(set) var made: [InMemoryByteStream] = []
    private(set) var calls = 0

    init(_ streams: [InMemoryByteStream], failures: Int = 0) {
        queue = streams
        self.failures = failures
    }

    struct Refused: Error {}

    func next() throws -> any ByteStream {
        try lock.withLock {
            calls += 1
            if failures > 0 { failures -= 1; throw Refused() }
            let s = queue.removeFirst()
            made.append(s)
            return s
        }
    }
}

let featuresReply = Data("OKAY0003cmd".utf8)

func makeActions(_ runner: FakeProcessRunner, _ factory: StreamFactory) -> AndroidActions {
    AndroidActions(serial: "S", adb: AdbClient(adb: Adb(url: URL(fileURLWithPath: "/fake/adb"), version: "1"), runner: runner),
                   settleDelay: .zero, syncStream: { try factory.next() })
}

/// features 流 + 一条 sync 流（握手两个 OKAY + `body`）。
func streams(_ body: Data) -> [InMemoryByteStream] {
    [InMemoryByteStream(featuresReply), InMemoryByteStream(Data("OKAYOKAY".utf8) + body)]
}

