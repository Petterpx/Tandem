import AppKit
import Foundation
import CoreGraphics
import MediaKit
import os
import Testing
@testable import Tandem

@MainActor
@Suite struct CaptureStoreTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    private func makeStore(
        now: (() -> Date)? = nil, onPrepare: @escaping @Sendable () -> Void = {}
    ) -> (CaptureStore, MacPasteboard, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pb = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var tick = 0.0
        let store = CaptureStore(pasteboard: pb, defaults: defaults, home: home, now: now ?? {
            tick += 1
            return Date(timeIntervalSince1970: 1_760_000_000 + tick)
        }, onPrepare: onPrepare)
        return (store, pb, home)
    }

    @Test func saveScreenshotWritesFileRecentsAndPasteboard() async throws {
        let (store, pb, _) = makeStore()
        let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
        #expect(FileManager.default.contents(atPath: item.url.path) == png)
        #expect(item.url.deletingLastPathComponent().path.hasSuffix("Pictures/Tandem"))
        #expect(store.recent.first == item)
        #expect(pb.isOwnChange(pb.changeCount))
    }

    @Test func recentIsCappedAtFifty() async throws {
        let (store, _, _) = makeStore()
        var first: CaptureItem?
        for i in 0...CaptureStore.recentLimit {
            let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
            if i == 0 { first = item }
        }
        #expect(store.recent.count == 50)
        #expect(!store.recent.contains(first!))
    }

    @Test func unwritableDirectoryThrowsReadableError() async throws {
        let (store, _, home) = makeStore()
        let file = home.appendingPathComponent("blocker")
        try Data().write(to: file)
        store.screenshotDirectory = file
        store.recordingDirectory = file
        do {
            _ = try await store.saveScreenshot(.png(png), deviceName: "P")
            Issue.record("应当抛错")
        } catch let e as CaptureError {
            #expect(e.errorDescription?.hasPrefix("无法写入") == true)
            #expect(e.recoverySuggestion == "请在设置中更换保存目录")
        }
        #expect(store.recent.isEmpty)
        #expect(throws: CaptureError.self) { _ = try store.nextRecordingURL(deviceName: "P") }
    }

    @Test func writeFailureInExistingDirectoryThrows() async throws {
        let (store, pb, _) = makeStore()
        let dir = store.screenshotDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let before = pb.changeCount
        await #expect(throws: CaptureError.self) { _ = try await store.saveScreenshot(.png(png), deviceName: "P") }
        #expect(store.recent.isEmpty)
        #expect(pb.changeCount == before)
    }

    @Test func deletedDirectoryIsRecreated() async throws {
        let (store, _, _) = makeStore()
        let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
        try FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        let again = try await store.saveScreenshot(.png(png), deviceName: "P").item
        #expect(FileManager.default.fileExists(atPath: again.url.path))
    }

    @Test func deletedFileIsReported() async throws {
        let (store, _, _) = makeStore()
        let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
        try FileManager.default.removeItem(at: item.url)
        #expect(store.fileExists(item) == false)
    }

    @Test func clearKeepsFiles() async throws {
        let (store, _, _) = makeStore()
        let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
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

    @Test func isOwnChangeCoversAllWrites() async throws {
        let (store, pb, _) = makeStore()
        pb.writeString("hi")
        let c1 = pb.changeCount
        #expect(pb.isOwnChange(c1) && pb.string() == "hi")
        let item = try await store.saveScreenshot(.png(png), deviceName: "P").item
        let c2 = pb.changeCount
        store.copy(item)
        let c3 = pb.changeCount
        #expect(pb.isOwnChange(c2) && pb.isOwnChange(c3))
        #expect(c1 != c2 && c2 != c3)
        // 外部写入不算自己的
        pb.pasteboard.clearContents()
        #expect(!pb.isOwnChange(pb.changeCount))
    }

    @Test func framePayloadIsSavedAtNativeSizeWithThumbnail() async throws {
        let (store, _, _) = makeStore()
        let saved = try await store.saveScreenshot(.frame(FakeDeviceSession.makeFrame(size: CGSize(width: 64, height: 48), pts: .zero)), deviceName: "P")
        #expect(saved.width == 64 && saved.height == 48)
        let file = try #require(FileManager.default.contents(atPath: saved.item.url.path))
        #expect(ScreenshotEncoder.pixelSize(ofPNG: file).map { [$0.width, $0.height] } == [64, 48])
        #expect(saved.item.thumbnailPNG != nil)
    }

    @Test func pngPayloadGetsLongEdge256Thumbnail() async throws {
        let (store, _, _) = makeStore()
        let saved = try await store.saveScreenshot(.png(AIEnv.png(width: 1080, height: 2400)), deviceName: "P")
        let thumb = try #require(saved.item.thumbnailPNG)
        #expect(ScreenshotEncoder.pixelSize(ofPNG: thumb)?.height == 256)
        #expect(saved.width == 1080 && saved.height == 2400)
    }

    @Test func invalidPNGIsSavedWithoutThumbnail() async throws {
        let (store, _, _) = makeStore()
        let saved = try await store.saveScreenshot(.png(png), deviceName: "P")
        #expect(saved.item.thumbnailPNG == nil && saved.width == nil)
    }

    @Test func preparationRunsOffMain() async throws {
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let (store, _, _) = makeStore(onPrepare: { onMain.withLock { $0 = Thread.isMainThread } })
        _ = try await store.saveScreenshot(.png(png), deviceName: "P")
        #expect(onMain.withLock { $0 } == false)
    }

    @Test func simultaneousSavesDoNotOverwrite() async throws {
        let fixed = Date(timeIntervalSince1970: 1_760_000_000)
        let (store, _, _) = makeStore(now: { fixed })
        let a = AIEnv.png(width: 10, height: 10), b = AIEnv.png(width: 20, height: 20)
        async let x = store.saveScreenshot(.png(a), deviceName: "P")
        async let y = store.saveScreenshot(.png(b), deviceName: "P")
        let (sx, sy) = try await (x, y)
        #expect(sx.item.url != sy.item.url)
        #expect(Set([FileManager.default.contents(atPath: sx.item.url.path), FileManager.default.contents(atPath: sy.item.url.path)]) == Set([a, b]))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.screenshotDirectory.path)
        #expect(names.filter { $0.hasPrefix(".") }.isEmpty)
    }

    @Test func nameTakenRecognisesExistsErrors() {
        #expect(CaptureStore.isNameTaken(CocoaError(.fileWriteFileExists)))
        #expect(CaptureStore.isNameTaken(POSIXError(.EEXIST)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)),
        ])
        #expect(CaptureStore.isNameTaken(wrapped))
        #expect(!CaptureStore.isNameTaken(POSIXError(.ENOTSUP)))
    }

    @Test func unsupportedLinkFallsBackToExclusiveWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let a = AIEnv.png(width: 10, height: 10), b = AIEnv.png(width: 20, height: 20)
        let unsupported: (URL, URL) throws -> Void = { _, _ in throw POSIXError(.ENOTSUP) }
        let first = try CaptureStore.prepareScreenshot(.png(a), in: dir, deviceName: "P", date: date, link: unsupported)
        let second = try CaptureStore.prepareScreenshot(.png(b), in: dir, deviceName: "P", date: date, link: unsupported)
        #expect(first.url != second.url)
        #expect(FileManager.default.contents(atPath: first.url.path) == a)
        #expect(FileManager.default.contents(atPath: second.url.path) == b)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasPrefix(".") }.isEmpty)
    }
}
