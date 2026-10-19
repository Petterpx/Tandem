import AppKit
import DeviceCore
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

/// 待保存的截图来源：镜像帧（原尺寸编码）或设备端 screencap 的 PNG。
enum ScreenshotPayload: Sendable {
    case frame(VideoFrame)
    case png(Data)
}

/// 保存完成的截图：记录加原图像素尺寸（数据无效时为 nil）。
struct SavedScreenshot: Equatable {
    let item: CaptureItem
    let width: Int?
    let height: Int?
}

/// 主线程外准备好的截图：已落盘的路径、PNG 数据与缩略图。
struct PreparedScreenshot: Sendable {
    let url: URL
    let png: Data
    let thumbnailPNG: Data?
    let width: Int?
    let height: Int?
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
    /// 测试探针：在后台任务里、准备开始前调用。
    private let onPrepare: @Sendable () -> Void

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
        now: @escaping () -> Date = Date.init,
        onPrepare: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.now = now
        self.onPrepare = onPrepare
        screenshotDirectory = defaults.string(forKey: "screenshotDirectory").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Pictures/Tandem")
        recordingDirectory = defaults.string(forKey: "recordingDirectory").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Movies/Tandem")
    }

    /// 编码、命名、写文件与缩略图都在后台完成；回到主线程后加入最近记录 → 写入 Mac 剪贴板。
    /// 目录或写入失败统一抛 `cannotWrite`（此时不改最近记录、不写剪贴板）；帧编码失败照常抛 `DeviceError`。
    func saveScreenshot(_ payload: ScreenshotPayload, deviceName: String) async throws -> SavedScreenshot {
        let dir = screenshotDirectory
        let date = now()
        let probe = onPrepare
        let prepared = try await Task.detached {
            probe()
            return try Self.prepareScreenshot(payload, in: dir, deviceName: deviceName, date: date)
        }.value
        let item = CaptureItem(
            id: UUID(), kind: .screenshot, url: prepared.url, deviceName: deviceName, date: date,
            duration: nil, fileSize: Int64(prepared.png.count), thumbnailPNG: prepared.thumbnailPNG)
        append(item)
        pasteboard.writeImage(png: prepared.png, fileURL: prepared.url)
        return SavedScreenshot(item: item, width: prepared.width, height: prepared.height)
    }

    /// 编码 → 读尺寸 → 生成缩略图 → 建目录并写文件。不触碰主线程状态。
    nonisolated static func prepareScreenshot(
        _ payload: ScreenshotPayload, in dir: URL, deviceName: String, date: Date
    ) throws -> PreparedScreenshot {
        let png: Data
        switch payload {
        case .frame(let frame): png = try ScreenshotEncoder.encodeFramePNG(frame.pixelBuffer).data
        case .png(let data): png = data
        }
        let size = ScreenshotEncoder.pixelSize(ofPNG: png)
        let thumbnail = ScreenshotEncoder.thumbnailPNG(png)

        let fm = FileManager.default
        try prepareDirectory(dir)
        // 先写同目录的隐藏临时文件，再用 link() 占名：目标已存在时 link 原子失败（EEXIST），换下一个候选名。
        // 不用 moveItem：它先检查后 rename，并发时会覆盖。
        let temp = dir.appendingPathComponent(".tandem-\(UUID().uuidString).png")
        do {
            try png.write(to: temp, options: .atomic)
        } catch {
            throw CaptureError.cannotWrite(dir)
        }
        defer { try? fm.removeItem(at: temp) }
        var tried: Set<String> = []
        while true {
            let name = CaptureNaming.fileName(deviceName: deviceName, date: date, ext: "png") {
                tried.contains($0) || fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let url = dir.appendingPathComponent(name)
            do {
                try fm.linkItem(at: temp, to: url)
                return PreparedScreenshot(
                    url: url, png: png, thumbnailPNG: thumbnail, width: size?.width, height: size?.height)
            } catch where isNameTaken(error) {
                tried.insert(name)
            } catch {
                throw CaptureError.cannotWrite(url)
            }
        }
    }

    /// link 因目标已存在而失败：Foundation 可能抛 `CocoaError.fileWriteFileExists`，也可能是 POSIX `EEXIST`。
    private nonisolated static func isNameTaken(_ error: Error) -> Bool {
        if (error as? CocoaError)?.code == .fileWriteFileExists { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EEXIST)
        }
        return false
    }

    /// 建好目录并返回不重名的 `.mp4` 路径。
    /// `excluding` 为进行中录屏的路径：录屏器惰性建文件，仅查文件存在会让同名同秒的两路撞车。
    func nextRecordingURL(deviceName: String, excluding: Set<URL> = []) throws -> URL {
        try Self.freshURL(in: recordingDirectory, deviceName: deviceName, date: now(), ext: "mp4", excluding: excluding)
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

    /// 确保目录存在（含被删除后重建），并探测其可写。
    private nonisolated static func prepareDirectory(_ dir: URL) throws {
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
    }

    /// 建好目录并返回不重名的目标路径。
    nonisolated static func freshURL(in dir: URL, deviceName: String, date: Date, ext: String, excluding: Set<URL> = []) throws -> URL {
        let fm = FileManager.default
        try prepareDirectory(dir)
        let name = CaptureNaming.fileName(deviceName: deviceName, date: date, ext: ext) {
            let candidate = dir.appendingPathComponent($0)
            return fm.fileExists(atPath: candidate.path) || excluding.contains(candidate)
        }
        return dir.appendingPathComponent(name)
    }
}
