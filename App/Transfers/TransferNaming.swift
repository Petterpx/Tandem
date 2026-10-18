import Foundation

/// 传输的同名处理：`a.jpg` → `a (1).jpg` → `a (2).jpg`…
enum TransferNaming {
    /// 第 n 个候选名；n 为 0 时即原名。扩展名只取最后一段（`a.tar.gz` → `a.tar (1).gz`）。
    static func candidate(_ name: String, _ n: Int) -> String {
        guard n > 0 else { return name }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) (\(n))" }
        return "\((name as NSString).deletingPathExtension) (\(n)).\(ext)"
    }

    /// Mac 目录中第一个不存在的候选路径。
    static func uniqueLocal(in dir: URL, name: String) -> URL {
        var n = 0
        while true {
            let url = dir.appendingPathComponent(candidate(name, n))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
