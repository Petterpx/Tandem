import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Tandem

@MainActor
struct PasteFileResolverTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-18 22:01:02 UTC
    private var now: Date {
        var c = DateComponents(year: 2026, month: 10, day: 18, hour: 22, minute: 1, second: 2)
        c.timeZone = utc
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func board() -> NSPasteboard { NSPasteboard(name: .init(UUID().uuidString)) }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString)")
    }

    private func resolve(_ board: NSPasteboard, _ dir: URL) throws -> PasteContent {
        try PasteFileResolver.resolve(board, tempDir: dir, now: now, timeZone: utc)
    }

    /// 1x1 红色图片，按指定类型编码。
    private func imageData(_ type: UTType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let kind: NSBitmapImageRep.FileType = type == .jpeg ? .jpeg : type == .png ? .png : .tiff
        return rep.representation(using: kind, properties: [:])!
    }

    @Test func textStaysText() throws {
        let b = board()
        b.setString("hello", forType: .string)
        #expect(try resolve(b, tempDir()) == .text("hello"))
    }

    @Test func emptyIsNone() throws {
        #expect(try resolve(board(), tempDir()) == .none)
    }

    @Test func fileURLWins() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.png")
        try imageData(.png).write(to: file)
        let b = board()
        b.writeObjects([file as NSURL])
        b.setString("text", forType: .string)
        guard case .files(let files) = try resolve(b, tempDir()) else { Issue.record("not files"); return }
        #expect(files.count == 1)
        #expect(files[0].origin == .file)
        #expect(files[0].isTemporary == false)
        #expect(files[0].name == "a.png")
        #expect(files[0].format == "PNG")
    }

    @Test func firstNonTIFFImageIsKeptRaw() throws {
        let jpeg = imageData(.jpeg)
        let item = NSPasteboardItem()
        item.setData(imageData(.tiff), forType: NSPasteboard.PasteboardType("public.tiff"))
        item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        let b = board()
        b.writeObjects([item])
        guard case .files(let files) = try resolve(b, tempDir()) else { Issue.record("not files"); return }
        #expect(files.count == 1)
        #expect(files[0].url.pathExtension == "jpg")
        #expect(files[0].origin == .rawData)
        #expect(files[0].isTemporary)
        #expect(files[0].format == "JPEG")
        #expect(try Data(contentsOf: files[0].url) == jpeg)
    }

    @Test func tiffOnlyBecomesPNG() throws {
        let item = NSPasteboardItem()
        item.setData(imageData(.tiff), forType: NSPasteboard.PasteboardType("public.tiff"))
        let b = board()
        b.writeObjects([item])
        guard case .files(let files) = try resolve(b, tempDir()) else { Issue.record("not files"); return }
        #expect(files[0].url.pathExtension == "png")
        #expect(files[0].origin == .tiffConverted)
        let bytes = try Data(contentsOf: files[0].url)
        #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test func pasteFileName() throws {
        let item = NSPasteboardItem()
        item.setData(imageData(.jpeg), forType: NSPasteboard.PasteboardType("public.jpeg"))
        let b = board()
        b.writeObjects([item])
        guard case .files(let files) = try resolve(b, tempDir()) else { Issue.record("not files"); return }
        #expect(files[0].name == "paste_20261018_220102.jpg")
    }

    @Test func multipleItemsGetSuffix() throws {
        let items = (0..<3).map { _ -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(imageData(.png), forType: NSPasteboard.PasteboardType("public.png"))
            return item
        }
        let b = board()
        b.writeObjects(items)
        guard case .files(let files) = try resolve(b, tempDir()) else { Issue.record("not files"); return }
        #expect(files.map(\.name) == [
            "paste_20261018_220102.png", "paste_20261018_220102_2.png", "paste_20261018_220102_3.png"])
    }

    @Test func heicConvertsToJPEG() throws {
        // 用 ImageIO 生成真实 HEIC；系统不支持编码时跳过
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let heic = dir.appendingPathComponent("p.heic")
        let png = CGImageSourceCreateWithData(imageData(.png) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(png, 0, nil)!
        guard let dest = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        let file = PasteFile(url: heic, name: "p.heic", size: 1, format: "HEIC", origin: .file, isTemporary: false)
        let out = try PasteFileResolver.convertHEICToJPEG(file, tempDir: dir)
        #expect(out.name == "p.jpg")
        #expect(out.isTemporary)
        #expect(Array(try Data(contentsOf: out.url).prefix(2)) == [0xFF, 0xD8])
    }

    @Test func conversionKeepsOrientation() throws {
        // HEIC 编码可能不可用，方向保留用带方向属性的 JPEG 源检查（转换对格式无关）
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("o.jpg")
        let png = CGImageSourceCreateWithData(imageData(.png) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(png, 0, nil)!
        let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let file = PasteFile(url: src, name: "o.heic", size: 1, format: "HEIC", origin: .file, isTemporary: false)
        let out = try PasteFileResolver.convertHEICToJPEG(file, tempDir: dir)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out.url as CFURL, nil)!, 0, nil)
            as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] as? Int == 6)
    }

    /// 文件夹大小遍历有上限：超过即停止，大小标为下限，确认框显示「≥ …」。
    @Test func directorySizeIsBounded() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 { try Data(count: 10).write(to: dir.appendingPathComponent("f\(i)")) }
        let all = PasteFileResolver.directorySize(dir)
        #expect(all.size == 50 && !all.isLowerBound)
        let capped = PasteFileResolver.directorySize(dir, entryCap: 3)
        #expect(capped.size == 30 && capped.isLowerBound)

        var file = PasteFile(url: dir, name: "d", size: 2048, format: "文件夹", origin: .file, isTemporary: false)
        #expect(!PasteFilesSheet.detail(file).hasPrefix("≥"))
        file.sizeIsLowerBound = true
        #expect(PasteFilesSheet.detail(file).hasPrefix("≥ "))
    }
}
