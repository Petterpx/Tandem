import Foundation

/// scrcpy 视频流 codec id（4 字节大端），见 doc/develop.md。
enum VideoCodecId {
    static let h264: UInt32 = 0x68323634
    static let disabled: UInt32 = 0
    static let configError: UInt32 = 1
}

/// 12 字节视频包头：session 包（最高位为 1）或 media 包。
enum VideoHeader: Equatable, Sendable {
    case session(width: Int, height: Int)
    case media(config: Bool, keyFrame: Bool, pts: UInt64, size: Int)

    static let length = 12

    /// 长度不是 12 字节时返回 nil。
    static func parse(_ header: Data) -> VideoHeader? {
        guard header.count == length else { return nil }
        let b = [UInt8](header)
        func be(_ from: Int, _ to: Int) -> UInt64 {
            b[from..<to].reduce(0) { $0 << 8 | UInt64($1) }
        }
        if b[0] & 0x80 != 0 {
            return .session(width: Int(be(4, 8)), height: Int(be(8, 12)))
        }
        return .media(config: b[0] & 0x40 != 0,
                      keyFrame: b[0] & 0x20 != 0,
                      pts: be(0, 8) & 0x1FFF_FFFF_FFFF_FFFF,
                      size: Int(be(8, 12)))
    }
}
