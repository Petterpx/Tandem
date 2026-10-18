import Foundation

/// 按字节 0x0A 切分流数据。按字节处理，所以多字节 UTF-8 字符被拆在两次读取之间也安全。
public struct LineReader {
    private var buffer = Data()
    public init() {}

    /// 追加数据，返回其中已完整的行（去掉结尾 \r，丢弃空行）；余下部分留到下次。
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        // 用下标扫描，每次 append 只在最后截掉一次已消费的部分。
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start && buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(Data(buffer[start..<end])) }
            start = nl + 1
        }
        if start > buffer.startIndex { buffer = Data(buffer[start...]) }
        return lines
    }
}
