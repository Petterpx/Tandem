import AppKit
import Foundation
import MediaKit
import Testing
@testable import Tandem

@MainActor
@Suite struct CaptureStoreTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    private func makeStore() -> (CaptureStore, MacPasteboard, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pb = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var tick = 0.0
        let store = CaptureStore(pasteboard: pb, defaults: defaults, home: home, now: {
            tick += 1
            return Date(timeIntervalSince1970: 1_760_000_000 + tick)
        })
        return (store, pb, home)
    }

    @Test func saveScreenshotWritesFileRecentsAndPasteboard() throws {
        let (store, pb, _) = makeStore()
        let item = try store.saveScreenshot(png, deviceName: "P")
        #expect(FileManager.default.contents(atPath: item.url.path) == png)
        #expect(item.url.deletingLastPathComponent().path.hasSuffix("Pictures/Tandem"))
        #expect(store.recent.first == item)
        #expect(pb.isOwnChange(pb.changeCount))
    }

    @Test func recentIsCappedAtFifty() throws {
        let (store, _, _) = makeStore()
        var first: CaptureItem?
        for i in 0...CaptureStore.recentLimit {
            let item = try store.saveScreenshot(png, deviceName: "P")
            if i == 0 { first = item }
        }
        #expect(store.recent.count == 50)
        #expect(!store.recent.contains(first!))
    }

    @Test func unwritableDirectoryThrowsReadableError() throws {
        let (store, _, home) = makeStore()
        let file = home.appendingPathComponent("blocker")
        try Data().write(to: file)
        store.screenshotDirectory = file
        store.recordingDirectory = file
        do {
            _ = try store.saveScreenshot(png, deviceName: "P")
            Issue.record("应当抛错")
        } catch let e as CaptureError {
            #expect(e.errorDescription?.hasPrefix("无法写入") == true)
            #expect(e.recoverySuggestion == "请在设置中更换保存目录")
        }
        #expect(store.recent.isEmpty)
        #expect(throws: CaptureError.self) { _ = try store.nextRecordingURL(deviceName: "P") }
    }

    @Test func writeFailureInExistingDirectoryThrows() throws {
        let (store, pb, _) = makeStore()
        let dir = store.screenshotDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let before = pb.changeCount
        #expect(throws: CaptureError.self) { _ = try store.saveScreenshot(png, deviceName: "P") }
        #expect(store.recent.isEmpty)
        #expect(pb.changeCount == before)
    }

    @Test func deletedDirectoryIsRecreated() throws {
        let (store, _, _) = makeStore()
        let item = try store.saveScreenshot(png, deviceName: "P")
        try FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        let again = try store.saveScreenshot(png, deviceName: "P")
        #expect(FileManager.default.fileExists(atPath: again.url.path))
    }

    @Test func deletedFileIsReported() throws {
        let (store, _, _) = makeStore()
        let item = try store.saveScreenshot(png, deviceName: "P")
        try FileManager.default.removeItem(at: item.url)
        #expect(store.fileExists(item) == false)
    }

    @Test func clearKeepsFiles() throws {
        let (store, _, _) = makeStore()
        let item = try store.saveScreenshot(png, deviceName: "P")
        store.clear()
        #expect(store.recent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test func recordingURLAndAddRecording() throws {
        let (store, _, _) = makeStore()
        let url = try store.nextRecordingURL(deviceName: "P")
        #expect(url.pathExtension == "mp4")
        #expect(url.deletingLastPathComponent().path.hasSuffix("Movies/Tandem"))
        let summary = RecordingSummary(url: url, duration: 3, canvasSize: CGSize(width: 10, height: 20), fileSize: 99, thumbnailPNG: nil)
        let item = store.addRecording(summary, deviceName: "P")
        #expect(item.kind == .recording && item.duration == 3 && item.fileSize == 99)
        #expect(store.recent.first == item)
    }

    @Test func isOwnChangeCoversAllWrites() throws {
        let (store, pb, _) = makeStore()
        pb.writeString("hi")
        let c1 = pb.changeCount
        #expect(pb.isOwnChange(c1) && pb.string() == "hi")
        let item = try store.saveScreenshot(png, deviceName: "P")
        let c2 = pb.changeCount
        store.copy(item)
        let c3 = pb.changeCount
        #expect(pb.isOwnChange(c2) && pb.isOwnChange(c3))
        #expect(c1 != c2 && c2 != c3)
        // 外部写入不算自己的
        pb.pasteboard.clearContents()
        #expect(!pb.isOwnChange(pb.changeCount))
    }
}
