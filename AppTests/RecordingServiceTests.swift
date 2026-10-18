import AppKit
import AVFoundation
import DeviceCore
import Foundation
import MediaKit
import Testing
@testable import Tandem

@MainActor
@Suite struct RecordingServiceTests {
    private let size = CGSize(width: 64, height: 48)

    private func make(fixedNow: Bool = false) -> (RecordingService, CaptureStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pb = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var tick = 0.0
        let store = CaptureStore(pasteboard: pb, defaults: defaults, home: home, now: {
            if !fixedNow { tick += 1 }
            return Date(timeIntervalSince1970: 1_760_000_000 + tick)
        })
        return (RecordingService(store: store), store)
    }

    @Test func recordsFramesIntoStore() async throws {
        let (service, store) = make()
        let fake = FakeDeviceSession()
        try service.start("a", deviceName: "P", session: fake, origin: .workspace)
        #expect(service.isRecording("a"))
        await fake.pushFrames(count: 30, size: size, fps: 30)
        let item = try await service.stop("a")
        #expect(item.kind == .recording && item.duration != nil && FileManager.default.fileExists(atPath: item.url.path))
        #expect(item.url.deletingLastPathComponent().path.hasSuffix("Movies/Tandem"))
        #expect(store.recent.first == item && !service.isRecording("a"))
        #expect(fake.observerCount == 0)
    }

    @Test func stopWithoutFramesReportsNoFrames() async {
        let (service, store) = make()
        let fake = FakeDeviceSession()
        try? service.start("a", deviceName: "P", session: fake, origin: .workspace)
        await #expect(throws: RecordingError.noFrames) { try await service.stop("a") }
        #expect(store.recent.isEmpty && !service.isRecording("a"))
    }

    @Test func recordingSurvivesViewObserverRemoval() async throws {
        let (service, _) = make()
        let fake = FakeDeviceSession()
        try service.start("a", deviceName: "P", session: fake, origin: .workspace)
        let viewToken = fake.addFrameObserver { _ in }
        await fake.pushFrames(count: 30, size: size, fps: 30)
        fake.removeFrameObserver(viewToken)
        await fake.pushFrames(count: 30, size: size, fps: 30)
        let item = try await service.stop("a")
        #expect(abs((item.duration ?? 0) - 2.0) < 0.15)
    }

    @Test func stopAllFinalizesEveryRecording() async throws {
        let (service, store) = make()
        let f1 = FakeDeviceSession(), f2 = FakeDeviceSession()
        try service.start("a", deviceName: "A", session: f1, origin: .workspace)
        try service.start("b", deviceName: "B", session: f2, origin: .popup("b"))
        await f1.pushFrames(count: 10, size: size, fps: 30)
        await f2.pushFrames(count: 10, size: size, fps: 30)
        let results = await service.stopAll()
        #expect(results.count == 2)
        for id in ["a", "b"] {
            guard case .success(let item)? = results[id] else { Issue.record("\(id) 未成功"); continue }
            #expect(FileManager.default.fileExists(atPath: item.url.path))
        }
        #expect(service.active.isEmpty && store.recent.count == 2)
    }

    @Test func doubleStartThrows() async throws {
        let (service, _) = make()
        let fake = FakeDeviceSession()
        try service.start("a", deviceName: "P", session: fake, origin: .workspace)
        #expect(throws: DeviceError(code: .UNSUPPORTED, message: "该设备正在录屏")) {
            try service.start("a", deviceName: "P", session: fake, origin: .workspace)
        }
        #expect(fake.observerCount == 1 && service.isRecording("a"))
        await fake.pushFrames(count: 5, size: size, fps: 30)
        _ = try await service.stop("a")
    }

    @Test func stopWhenNotRecordingThrows() async {
        let (service, _) = make()
        await #expect(throws: DeviceError(code: .UNSUPPORTED, message: "该设备未在录屏")) { try await service.stop("x") }
    }

    @Test func concurrentSecondStopThrows() async throws {
        let (service, _) = make()
        let fake = FakeDeviceSession()
        try service.start("a", deviceName: "P", session: fake, origin: .workspace)
        await fake.pushFrames(count: 10, size: size, fps: 30)
        let first = Task { try await service.stop("a") }
        let second = Task { try await service.stop("a") }
        let results = [await first.result, await second.result]
        // 同步摘除：并发的两次 stop 恰有一次成功，另一次抛"未在录屏"，不会重复收尾。
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        let failures = results.compactMap { r -> DeviceError? in
            if case .failure(let e) = r { e as? DeviceError } else { nil }
        }
        #expect(failures == [DeviceError(code: .UNSUPPORTED, message: "该设备未在录屏")])
    }

    @Test func sameNameSameSecondGetsDistinctURLs() async throws {
        let (service, _) = make(fixedNow: true)
        let f1 = FakeDeviceSession(), f2 = FakeDeviceSession()
        try service.start("a", deviceName: "P", session: f1, origin: .workspace)
        try service.start("b", deviceName: "P", session: f2, origin: .workspace)
        await f1.pushFrames(count: 10, size: size, fps: 30)
        await f2.pushFrames(count: 10, size: size, fps: 30)
        let a = try await service.stop("a")
        let b = try await service.stop("b")
        #expect(a.url != b.url)
        #expect(FileManager.default.fileExists(atPath: a.url.path) && FileManager.default.fileExists(atPath: b.url.path))
    }
}
