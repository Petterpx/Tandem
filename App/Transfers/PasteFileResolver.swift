import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板里可粘贴的一个文件（可能是剪贴板数据写出的临时文件）。
struct PasteFile: Equatable {
    enum Origin: Equatable { case file, rawData, tiffConverted }

    var url: URL
    var name: String
    var size: UInt64
    /// 文件夹太大、遍历中途停止时为 true：`size` 只是已统计部分，显示为「≥ 大小」。
    var sizeIsLowerBound = false
    /// 简短格式名，如 JPEG、PNG、HEIC、MPEG-4；文件夹为「文件夹」。
    var format: String
    var origin: Origin
    var isTemporary: Bool
}

enum PasteContent: Equatable {
    case text(String)
    case files([PasteFile])
    case none
}

/// 把 Mac 剪贴板分类为 ⌘V 的内容：文件 URL → 图片 / 视频数据 → 文本。
/// 数据项写入调用方给的 tempDir，这里不删除（生命周期由调用方管理）。
enum PasteFileResolver {
    static func resolve(
        _ pasteboard: NSPasteboard, tempDir: URL, now: Date, timeZone: TimeZone = .current
    ) throws -> PasteContent {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls.map(fileEntry))
        }
        var files: [PasteFile] = []
        let base = baseName(now, timeZone)
        for item in pasteboard.pasteboardItems ?? [] {
            let index = files.count + 1
            let name = index == 1 ? base : "\(base)_\(index)"
            if let file = try writeItem(item, name: name, tempDir: tempDir) { files.append(file) }
        }
        if !files.isEmpty { return .files(files) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
        return .none
    }

    /// HEIC 转 JPEG（质量 0.9），写入 tempDir；文件名换扩展名。
    static func convertHEICToJPEG(_ file: PasteFile, tempDir: URL) throws -> PasteFile {
        guard let source = CGImageSource.fromURL(file.url)
        else { throw ResolveError.unreadable(file.name) }
        let name = (file.name as NSString).deletingPathExtension + ".jpg"
        let out = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ResolveError.encodeFailed(name) }
        // 从源复制，保留 EXIF 方向等属性（否则竖拍的 HEIC 会转成横的）
        CGImageDestinationAddImageFromSource(
            dest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ResolveError.encodeFailed(name) }
        return PasteFile(
            url: out, name: name, size: fileSize(out), format: "JPEG", origin: file.origin, isTemporary: true)
    }

    enum ResolveError: Error, Equatable {
        case unreadable(String)
        case encodeFailed(String)
    }

    // MARK: 内部

    private static func baseName(_ now: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "paste_" + formatter.string(from: now)
    }

    private static func fileEntry(_ url: URL) -> PasteFile {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let format = isDir ? "文件夹" : formatName(UTType(filenameExtension: url.pathExtension), ext: url.pathExtension)
        let (size, partial) = isDir ? directorySize(url) : (fileSize(url), false)
        return PasteFile(
            url: url, name: url.lastPathComponent, size: size, sizeIsLowerBound: partial,
            format: format, origin: .file, isTemporary: false)
    }

    /// 取第一个非 TIFF 的图片 / 视频类型原样写出；只有 TIFF 时无损转 PNG。
    private static func writeItem(_ item: NSPasteboardItem, name: String, tempDir: URL) throws -> PasteFile? {
        let types = item.types.compactMap { type in UTType(type.rawValue).map { (type, $0) } }
        let isMedia: (UTType) -> Bool = { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        if let (type, ut) = types.first(where: { isMedia($0.1) && !$0.1.conforms(to: .tiff) }),
           let data = item.data(forType: type) {
            let ext = fileExtension(ut)
            return try write(data, name: "\(name).\(ext)", tempDir: tempDir, format: formatName(ut, ext: ext), origin: .rawData)
        }
        if let (type, _) = types.first(where: { $0.1.conforms(to: .tiff) }), let data = item.data(forType: type) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let buffer = Optional(NSMutableData()),
                  let dest = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)
            else { throw ResolveError.unreadable(name) }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw ResolveError.encodeFailed(name) }
            return try write(
                buffer as Data, name: "\(name).png", tempDir: tempDir, format: "PNG", origin: .tiffConverted)
        }
        return nil
    }

    private static func write(_ data: Data, name: String, tempDir: URL, format: String, origin: PasteFile.Origin) throws
        -> PasteFile {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return PasteFile(url: url, name: name, size: UInt64(data.count), format: format, origin: origin, isTemporary: true)
    }

    private static func fileExtension(_ type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "dat"
        return ext == "jpeg" ? "jpg" : ext
    }

    private static func formatName(_ type: UTType?, ext: String) -> String {
        switch type {
        case UTType.jpeg: return "JPEG"
        case UTType.png: return "PNG"
        case UTType.heic: return "HEIC"
        case UTType.gif: return "GIF"
        case UTType.tiff: return "TIFF"
        case UTType.webP: return "WebP"
        case UTType.mpeg4Movie: return "MPEG-4"
        case UTType.quickTimeMovie: return "QuickTime"
        default: return ext.isEmpty ? "文件" : ext.uppercased()
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// 遍历文件夹最多访问的条目数（与 AI 传输超时的估算一致），避免粘贴超大文件夹时卡住主线程。
    static let directoryEntryCap = 20_000

    /// 文件夹内普通文件的总字节数；访问条目超过 `entryCap` 即停止，返回已统计部分并标记为下限。
    static func directorySize(_ url: URL, entryCap: Int = directoryEntryCap) -> (size: UInt64, isLowerBound: Bool) {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, false) }
        var total: UInt64 = 0, visited = 0
        for case let child as URL in walker {
            visited += 1
            if visited > entryCap { return (total, true) }
            total += fileSize(child)
        }
        return (total, false)
    }
}

private extension CGImageSource {
    static func fromURL(_ url: URL) -> CGImageSource? { CGImageSourceCreateWithURL(url as CFURL, nil) }
}
