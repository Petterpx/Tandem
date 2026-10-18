import Foundation

/// 按字节 0x0A 切分流数据。按字节处理，所以多字节 UTF-8 字符被拆在两次读取之间也安全。
public struct LineReader {
    private var buffer = Data()
    public init() {}

    /// 追加数据，返回其中已完整的行（去掉结尾 \r，丢弃空行）；余下部分留到下次。
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
