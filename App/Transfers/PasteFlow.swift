import AppKit
import Foundation
import Observation

/// ⌘V 的处理结果。
enum PasteAction: Equatable {
    /// 文本：由调用方写入设备剪贴板并粘贴（现有行为）。
    case text(String)
    /// 需要确认：视图弹出确认框。
    case confirm([PasteFile])
    /// 已按记住的选择入队，只显示进度栏。
    case pushedDirectly
    case nothing
}

/// 等待确认的一次粘贴。
struct PendingPaste: Identifiable {
    let id = UUID()
    let files: [PasteFile]
}

/// 一个 MirrorView 一个：把剪贴板内容分流为文本 / 确认框 / 直接推送。
/// 临时文件放在 `tempDir` 下每次粘贴独立的子目录，由传输任务结束时删除（TransferJob.cleanup）。
@MainActor @Observable
final class PasteFlow {
    /// 非 nil 时视图显示确认框。
    var pending: PendingPaste?

    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let commands: DeviceCommands
    @ObservationIgnored private let store: FileTransferStore
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let tempDir: URL
    @ObservationIgnored private let origin: ToastOrigin

    init(
        deviceID: String, commands: DeviceCommands, store: FileTransferStore, pasteboard: NSPasteboard = .general,
        tempDir: URL, origin: ToastOrigin = .workspace
    ) {
        self.deviceID = deviceID
        self.commands = commands
        self.store = store
        self.pasteboard = pasteboard
        self.tempDir = tempDir
        self.origin = origin
    }

    func paste() -> PasteAction {
        // 确认框还开着时不再处理新的粘贴
        guard pending == nil else { return .nothing }
        let content: PasteContent
        do {
            content = try PasteFileResolver.resolve(pasteboard, tempDir: freshDirectory(), now: Date())
        } catch {
            NSLog("Tandem: 读取剪贴板失败: \(error)")
            return .nothing
        }
        switch content {
        case .none: return .nothing
        case .text(let text): return .text(text)
        case .files(let all):
            // 按设备能力过滤：没有 files 只能安装 APK，没有 apps 不能安装
            let files = all.filter { canFiles || (canInstall && Self.isAPK($0)) }
            TransferQueue.removeTemporaries(all.filter { f in f.isTemporary && !files.contains(f) }.map(\.url))
            guard !files.isEmpty else { return .nothing }
            if let choice = store.rememberedPaste {
                enqueue(files, choice: choice)
                return .pushedDirectly
            }
            pending = PendingPaste(files: files)
            return .confirm(files)
        }
    }

    /// 设备支持安装 APK（apps）；确认框据此显示 APK 选项。
    var canInstall: Bool { commands.can(.apps, deviceID) }
    private var canFiles: Bool { commands.can(.files, deviceID) }

    static func isAPK(_ file: PasteFile) -> Bool {
        file.format != "文件夹" && file.url.pathExtension.lowercased() == "apk"
    }

    /// 确认框点「推送」。
    func confirm(_ files: [PasteFile], choice: PasteChoice, remember: Bool) {
        pending = nil
        store.recordDirectory(choice.dest)
        if remember { store.rememberedPaste = choice }
        enqueue(files, choice: choice)
    }

    /// 确认框点「取消」：立即删除临时文件。
    func cancel(_ files: [PasteFile]) {
        pending = nil
        TransferQueue.removeTemporaries(files.filter(\.isTemporary).map(\.url))
    }

    // MARK: 内部

    private func enqueue(_ files: [PasteFile], choice: PasteChoice) {
        var choice = choice
        // 没有 apps 能力时 APK 只能作为普通文件推送；只有 apps 时只能安装
        choice.installAPK = canInstall && (choice.installAPK || !canFiles)
        var urls: [URL] = []
        var temporary: Set<URL> = []
        for file in files {
            var file = file
            if choice.heicToJPEG, file.format == "HEIC" {
                do {
                    let converted = try PasteFileResolver.convertHEICToJPEG(file, tempDir: freshDirectory())
                    if file.isTemporary { TransferQueue.removeTemporaries([file.url]) }
                    file = converted
                } catch {
                    NSLog("Tandem: HEIC 转 JPEG 失败，按原文件推送: \(error)")
                }
            }
            urls.append(file.url)
            if file.isTemporary { temporary.insert(file.url) }
        }
        commands.pushFiles(
            deviceID, urls, dest: choice.dest, conflict: choice.conflict, mediaScan: choice.mediaScan,
            installAPKs: choice.installAPK, cleanup: temporary, origin: origin)
    }

    private func freshDirectory() -> URL { tempDir.appendingPathComponent(UUID().uuidString) }
}
