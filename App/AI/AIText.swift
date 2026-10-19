import Foundation

/// 返回给 AI 的文本的共用截断辅助。
enum AIText {
    /// 超过 limit 字节时截断，截断说明也计入 limit；说明里的 N 是截断前的总字节数。
    static func truncated(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        let note = "\n…（输出已截断，共 \(total) 字节）"
        return prefix(text, bytes: limit - note.utf8.count) + note
    }

    /// 不超过 bytes 个 UTF-8 字节的最长前缀，在字符边界处截断。
    static func prefix(_ s: String, bytes: Int) -> String {
        var used = 0
        var end = s.startIndex
        for i in s.indices {
            used += s[i].utf8.count
            if used > bytes { break }
            end = s.index(after: i)
        }
        return String(s[..<end])
    }
}
