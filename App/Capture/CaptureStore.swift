import AppKit
import Foundation
import MediaKit
import Observation

/// 一条截图或录屏记录。
struct CaptureItem: Identifiable, Equatable {
    enum Kind { case screenshot, recording }
    let id: UUID
    let kind: Kind
    let url: URL
    let deviceName: String
    let date: Date
    let duration: Double?
    let fileSize: Int64
    let thumbnailPNG: Data?
}

enum CaptureError: LocalizedError {
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let url): "无法写入 \(url.path)"
        }
    }

    var recoverySuggestion: String? { "请在设置中更换保存目录" }
}

/// 截图与录屏的保存位置、命名与最近记录。
@MainActor @Observable
final class CaptureStore {
    static let recentLimit = 50

    private let pasteboard: MacPasteboard
    private let defaults: UserDefaults
    private let now: () -> Date

    var screenshotDirectory: URL {
        didSet { defaults.set(screenshotDirectory.path, forKey: "screenshotDirectory") }
    }
    var recordingDirectory: URL {
        didSet { defaults.set(recordingDirectory.path, forKey: "recordingDirectory") }
    }
    /// 最新在前。
    private(set) var recent: [CaptureItem] = []

    init(
        pasteboard: MacPasteboard, defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.now = now
        screenshotDirectory = defaults.string(forKey: "screenshotDirectory").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Pictures/Tandem")
        recordingDirectory = defaults.string(forKey: "recordingDirectory").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Movies/Tandem")
    }

    /// 写入文件 → 加入最近记录 → 写入 Mac 剪贴板。目录或写入失败统一抛 `cannotWrite`。
    func saveScreenshot(_ png: Data, deviceName: String) throws -> CaptureItem {
        let date = now()
        let url = try freshURL(in: screenshotDirectory, deviceName: deviceName, date: date, ext: "png")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.cannotWrite(url)
        }
        let item = CaptureItem(
            id: UUID(), kind: .screenshot, url: url, deviceName: deviceName, date: date,
            duration: nil, fileSize: Int64(png.count), thumbnailPNG: nil)
        append(item)
        pasteboard.writeImage(png: png, fileURL: url)
        return item
    }

    /// 建好目录并返回不重名的 `.mp4` 路径。
    func nextRecordingURL(deviceName: String) throws -> URL {
        try freshURL(in: recordingDirectory, deviceName: deviceName, date: now(), ext: "mp4")
    }

    func addRecording(_ summary: RecordingSummary, deviceName: String) -> CaptureItem {
        let item = CaptureItem(
            id: UUID(), kind: .recording, url: summary.url, deviceName: deviceName, date: now(),
            duration: summary.duration, fileSize: summary.fileSize, thumbnailPNG: summary.thumbnailPNG)
        append(item)
        return item
    }

    func copy(_ item: CaptureItem) {
        pasteboard.writeFileURL(item.url)
    }

    func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func fileExists(_ item: CaptureItem) -> Bool {
        FileManager.default.fileExists(atPath: item.url.path)
    }

    /// 只清空列表，不删文件。
    func clear() { recent.removeAll() }

    private func append(_ item: CaptureItem) {
        recent.insert(item, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// 确保目录存在（含被删除后重建），并探测其可写，返回不重名的目标路径。
    private func freshURL(in dir: URL, deviceName: String, date: Date, ext: String) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            throw CaptureError.cannotWrite(dir)
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.cannotWrite(dir)
        }
        guard fm.isWritableFile(atPath: dir.path) else { throw CaptureError.cannotWrite(dir) }
        let name = CaptureNaming.fileName(deviceName: deviceName, date: date, ext: ext) {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }
}
