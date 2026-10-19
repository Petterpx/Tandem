import Foundation

/// 日志导出的文件名（spec §3.6）：`<设备名>_<包名或all>_yyyyMMdd_HHmmss.txt`。
enum LogExport {
    /// 导出与复制共用的行格式：`time pid tid L tag: message`，分隔行原样；每行以换行结尾。
    static func text(_ lines: [LogLine]) -> String {
        lines.map { line in
            switch line {
            case .entry(let e, _): "\(e.time) \(e.pid) \(e.tid) \(e.level.rawValue) \(e.tag): \(e.message)\n"
            case .separator(let text, _): text + "\n"
            }
        }.joined()
    }

    /// 视口底边离内容底边不超过一行高度即视为在底部（跟随模式）。
    static func isAtBottom(contentHeight: CGFloat, visibleMaxY: CGFloat, rowHeight: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - rowHeight
    }

    static func fileName(device: String, target: LogTarget, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d_%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(sanitize(device))_\(target.package ?? "all")_\(stamp).txt"
    }

    /// 设备名里的路径分隔符与冒号换成下划线，避免保存面板把它当成目录。
    private static func sanitize(_ name: String) -> String {
        let cleaned = String(name.map { "/:\\".contains($0) ? "_" : $0 })
        return cleaned.isEmpty ? "device" : cleaned
    }
}
