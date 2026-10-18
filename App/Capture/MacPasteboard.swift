import AppKit

/// Mac 剪贴板封装：记录自己写入产生的 changeCount，避免剪贴板同步时回环。
@MainActor
final class MacPasteboard {
    let pasteboard: NSPasteboard
    /// 自己最近几次写入后的 changeCount（只保留少量，足够覆盖轮询间隔内的写入）。
    private var ownChanges: [Int] = []

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func string() -> String? { pasteboard.string(forType: .string) }

    func writeString(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
        markOwn()
    }

    /// 同时写入图片数据与文件 URL，粘贴到聊天软件或 Finder 都可用。
    func writeImage(png: Data, fileURL: URL) {
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.writeObjects([fileURL as NSURL])
        markOwn()
    }

    func writeFileURL(_ url: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        markOwn()
    }

    /// changeCount 是否来自 App 自己最近的写入。
    func isOwnChange(_ changeCount: Int) -> Bool {
        ownChanges.contains(changeCount)
    }

    private func markOwn() {
        ownChanges.append(pasteboard.changeCount)
        if ownChanges.count > 16 { ownChanges.removeFirst(ownChanges.count - 16) }
    }
}
