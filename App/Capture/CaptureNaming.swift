import Foundation

/// 截图 / 录屏文件命名：`<设备名>_yyyyMMdd_HHmmss.<ext>`，同名依次加 `-2`、`-3`。
enum CaptureNaming {
    static func fileName(
        deviceName: String, date: Date, ext: String,
        timeZone: TimeZone = .current, isTaken: (String) -> Bool
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        var name = deviceName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if name.isEmpty { name = "Device" }
        let base = "\(name)_\(formatter.string(from: date))"
        var candidate = "\(base).\(ext)"
        var n = 2
        while isTaken(candidate) {
            candidate = "\(base)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
