import DeviceCore
import Foundation

struct SimulatorMessage: Decodable, Sendable {
    let event: String?
    let id: Int?
    let ok: Bool?
    let code: String?
    let error: String?
    let text: String?
    let jpeg: String?
    let width: Int?
    let height: Int?
    let stats: [String: UInt64]?

    var deviceError: DeviceError? {
        guard ok == false || event == "error" else { return nil }
        return DeviceError(code: code.flatMap(DeviceError.Code.init(rawValue:)) ?? .CONNECTION_FAILED,
                           message: error ?? "模拟器 helper 操作失败")
    }
}

struct SimulatorMessageDecoder {
    private var buffer = Data()
    let maxLineSize: Int
    init(maxLineSize: Int = 32 * 1024 * 1024) { self.maxLineSize = maxLineSize }

    mutating func append(_ data: Data) throws -> [SimulatorMessage] {
        buffer.append(data)
        var messages: [SimulatorMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= maxLineSize else { throw invalid("消息超过 32 MiB") }
            let line = buffer[buffer.startIndex..<newline]
            guard !line.isEmpty else { throw invalid("空消息") }
            do { messages.append(try JSONDecoder().decode(SimulatorMessage.self, from: line)) }
            catch { throw invalid("JSON 消息无效") }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        guard buffer.count <= maxLineSize else { throw invalid("消息超过 32 MiB") }
        return messages
    }

    func finish() throws {
        guard buffer.isEmpty else { throw invalid("消息被截断") }
    }
    private func invalid(_ detail: String) -> DeviceError {
        DeviceError(code: .CONNECTION_FAILED, message: "模拟器 IPC：\(detail)")
    }
}

struct SimulatorRequest: Codable, Sendable {
    var id = 0
    var command: String
    var phase: String?
    var x: Double?
    var y: Double?
    var pointer: String?
    var key: String?
    var text: String?
    var paste: Bool?
}
