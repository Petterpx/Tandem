import DeviceCore
import Foundation
import Testing
@testable import Tandem

@Suite struct PastePermissionOCRBudgetTests {
    @Test func deadlineReturnsNilWithoutWaitingForSlowWorkerOrItsLatePoint() async throws {
        let gate = PastePermissionResolver.OCRGate()
        let worker = SlowPasteRecognition()
        defer { worker.release.signal() }
        let start = ContinuousClock.now
        let task = Task {
            await gate.run(timeout: 0.08, worker: { worker.recognize() }, cancel: { worker.cancel() })
        }
        try await waitForStart(worker)
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        try await waitForCancellation(worker)
        #expect(worker.cancellations == 1)
        // The old worker is still blocked and would return a valid point, but
        // another call must fall back immediately without starting more OCR.
        let second = await gate.run(timeout: 0.08, worker: {
            worker.recordUnexpectedStart()
            return DeviceCore.NormalizedPoint(x: 0.5, y: 0.6)
        })
        #expect(second == nil)
        #expect(worker.unexpectedStarts == 0)
        worker.release.signal()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await task.value == nil)
    }

    @Test func cancellationReturnsImmediatelyAndKeepsWorkerSlotUntilExit() async throws {
        let gate = PastePermissionResolver.OCRGate()
        let worker = SlowPasteRecognition()
        defer { worker.release.signal() }
        let task = Task {
            await gate.run(timeout: 1, worker: { worker.recognize() }, cancel: { worker.cancel() })
        }
        try await waitForStart(worker)
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .milliseconds(300))
        try await waitForCancellation(worker)
        #expect(worker.cancellations == 1)
        #expect(await gate.run(timeout: 0.01, worker: { DeviceCore.NormalizedPoint(x: 0.5, y: 0.6) }) == nil)
    }

    @Test func completedRecognitionReturnsPointAndDoesNotReceiveTimeoutCancellation() async throws {
        let gate = PastePermissionResolver.OCRGate()
        let worker = SlowPasteRecognition()
        let point = DeviceCore.NormalizedPoint(x: 0.5, y: 0.6)
        let value = await gate.run(timeout: 0.02, worker: { point }, cancel: { worker.cancel() })
        #expect(value == point)
        try await Task.sleep(for: .milliseconds(50))
        #expect(worker.cancellations == 0)
    }

    private func waitForCancellation(_ worker: SlowPasteRecognition) async throws {
        let deadline = ContinuousClock.now + .milliseconds(300)
        while worker.cancellations == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForStart(_ worker: SlowPasteRecognition) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !worker.started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(worker.started)
    }
}

private final class SlowPasteRecognition: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didStart = false
    private var cancelled = 0
    private var extraStarts = 0
    var started: Bool { lock.withLock { didStart } }
    var cancellations: Int { lock.withLock { cancelled } }
    var unexpectedStarts: Int { lock.withLock { extraStarts } }
    func recognize() -> DeviceCore.NormalizedPoint? {
        lock.withLock { didStart = true }
        release.wait()
        return DeviceCore.NormalizedPoint(x: 0.5, y: 0.6)
    }
    func cancel() { lock.withLock { cancelled += 1 } }
    func recordUnexpectedStart() { lock.withLock { extraStarts += 1 } }
}
