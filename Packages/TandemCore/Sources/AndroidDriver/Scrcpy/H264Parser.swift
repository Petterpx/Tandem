import Foundation

/// H.264 Annex B / AVCC 工具。
enum H264Parser {
    /// 按 00 00 01 / 00 00 00 01 切分，结果不含起始码；首个起始码前的数据与空 NAL 被丢弃。
    static func nalUnits(annexB: Data) -> [Data] {
        let b = [UInt8](annexB)
        var starts: [(code: Int, payload: Int)] = []  // 起始码位置与 NAL 起点
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var result: [Data] = []
        for (n, s) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1].code : b.count
            // 4 字节起始码的前导 0 属于下一个起始码；尾部 trailing_zero 同理剥离
            if n + 1 < starts.count { while end > s.payload, b[end - 1] == 0 { end -= 1 } }
            if end > s.payload { result.append(Data(b[s.payload..<end])) }
        }
        return result
    }

    static func nalType(_ nal: Data) -> UInt8 { nal[nal.startIndex] & 0x1f }

    static func parameterSets(annexB: Data) -> (sps: Data, pps: Data)? {
        let nals = nalUnits(annexB: annexB)
        guard let sps = nals.first(where: { nalType($0) == 7 }),
              let pps = nals.first(where: { nalType($0) == 8 }) else { return nil }
        return (sps, pps)
    }

    /// 每个 NAL 前加 4 字节大端长度。
    static func avcc(fromAnnexB data: Data) -> Data {
        var out = Data()
        for nal in nalUnits(annexB: data) {
            let n = UInt32(nal.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            out.append(nal)
        }
        return out
    }
}
