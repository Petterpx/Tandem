import Foundation

/// 从 APK 的二进制 AndroidManifest.xml（AXML）里读取包名。
/// 所有读取都做边界检查；格式不符一律返回 nil。
public enum ApkManifest {
    private static let chunkXML: UInt16 = 0x0003
    private static let chunkStringPool: UInt16 = 0x0001
    private static let chunkStartElement: UInt16 = 0x0102

    public static func packageName(apk: URL, runner: any ProcessRunner) async -> String? {
        guard let result = try? await runner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", apk.path, "AndroidManifest.xml"], timeout: .seconds(10)),
            result.exitCode == 0 else { return nil }
        return packageName(result.stdout)
    }

    public static func packageName(_ axml: Data) -> String? {
        let d = [UInt8](axml)
        guard u16(d, 0) == chunkXML, let headerSize = u16(d, 2), let total = u32(d, 4),
              Int(total) <= d.count else { return nil }  // 声明长度超出实际数据即视为截断
        let end = Int(total)
        var pos = Int(headerSize)
        var pool: Pool?
        while pos + 8 <= end {
            guard let type = u16(d, pos), let size32 = u32(d, pos + 4) else { return nil }
            let size = Int(size32)
            guard size >= 8, pos + size <= end else { return nil }
            switch type {
            case chunkStringPool:
                pool = parsePool(d, at: pos, size: size)
                if pool == nil { return nil }
            case chunkStartElement:
                guard let pool else { return nil }
                return packageAttribute(d, at: pos, size: size, pool: pool)
            default: break
            }
            pos += size
        }
        return nil
    }

    /// 字符串池：只记录位置，按需解码单个字符串（避免恶意清单造成内存放大）。
    private struct Pool {
        let d: [UInt8]
        let count: Int
        let utf8: Bool
        let offsets: Int
        let dataStart: Int
        let limit: Int

        func string(_ i: UInt32) -> String? {
            let i = Int(i)
            guard i < count, let off = ApkManifest.u32(d, offsets + i * 4, limit: limit) else { return nil }
            let p = dataStart + Int(off)
            guard p < limit else { return nil }
            return utf8 ? ApkManifest.readUTF8(d, p, limit) : ApkManifest.readUTF16(d, p, limit)
        }
    }

    /// 解析首个起始元素：必须是 `manifest`，返回其 `package` 属性。
    private static func packageAttribute(_ d: [UInt8], at pos: Int, size: Int, pool: Pool) -> String? {
        let limit = pos + size
        // 头 16 字节后依次为：ns、name、attributeStart、attributeSize、attributeCount …
        guard let nameIdx = u32(d, pos + 20, limit: limit), let attrStart = u16(d, pos + 24, limit: limit),
              let attrSize = u16(d, pos + 26, limit: limit), let attrCount = u16(d, pos + 28, limit: limit),
              pool.string(nameIdx) == "manifest", attrSize >= 20 else { return nil }
        let base = pos + 16 + Int(attrStart)
        for i in 0..<Int(attrCount) {
            let a = base + i * Int(attrSize)
            guard let attrName = u32(d, a + 4, limit: limit), let raw = u32(d, a + 8, limit: limit) else { return nil }
            if pool.string(attrName) == "package" {
                return raw == 0xFFFF_FFFF ? nil : pool.string(raw)
            }
        }
        return nil
    }

    private static func parsePool(_ d: [UInt8], at pos: Int, size: Int) -> Pool? {
        let limit = pos + size
        guard let count32 = u32(d, pos + 8, limit: limit), let flags = u32(d, pos + 16, limit: limit),
              let start32 = u32(d, pos + 20, limit: limit) else { return nil }
        let count = Int(count32)
        guard count <= size / 4 else { return nil }
        return Pool(d: d, count: count, utf8: flags & 0x100 != 0, offsets: pos + 28,
                    dataStart: pos + Int(start32), limit: limit)
    }

    private static func readUTF16(_ d: [UInt8], _ p: Int, _ limit: Int) -> String? {
        guard let first = u16(d, p, limit: limit) else { return nil }
        var n = Int(first)
        var q = p + 2
        if first & 0x8000 != 0 {
            guard let lo = u16(d, q, limit: limit) else { return nil }
            n = (n & 0x7FFF) << 16 | Int(lo)
            q += 2
        }
        let len = n * 2
        guard q + len <= limit else { return nil }
        return String(data: Data(d[q..<q + len]), encoding: .utf16LittleEndian)
    }

    private static func readUTF8(_ d: [UInt8], _ p: Int, _ limit: Int) -> String? {
        var q = p
        // 先是 UTF-16 字符数，再是 UTF-8 字节数；各 1 或 2 字节。
        guard q < limit else { return nil }
        q += d[q] & 0x80 != 0 ? 2 : 1
        guard q < limit else { return nil }
        var len = Int(d[q])
        if d[q] & 0x80 != 0 {
            guard q + 1 < limit else { return nil }
            len = (len & 0x7F) << 8 | Int(d[q + 1])
            q += 2
        } else { q += 1 }
        guard q + len <= limit else { return nil }
        return String(data: Data(d[q..<q + len]), encoding: .utf8)
    }

    private static func u16(_ d: [UInt8], _ i: Int, limit: Int? = nil) -> UInt16? {
        guard i >= 0, i + 2 <= min(limit ?? d.count, d.count) else { return nil }
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    private static func u32(_ d: [UInt8], _ i: Int, limit: Int? = nil) -> UInt32? {
        guard i >= 0, i + 4 <= min(limit ?? d.count, d.count) else { return nil }
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
