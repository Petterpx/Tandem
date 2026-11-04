import Foundation
import Testing
@testable import SimulatorHelper

@MainActor
struct AcknowledgedEventStreamTests {
    @Test func acknowledgementWaitsForDeliveryAndAllowsNextEventBeforeStreamFinishes() async throws {
        let started = StreamTestGate()
        let delivery = StreamTestGate()
        let received = StreamTestValues()
        let stream = AcknowledgedEventStream<Int> { events in
            for await event in events {
                await started.open()
                await delivery.wait()
                await received.append(event)
            }
        }
        var acknowledged = false
        let request = Task { try await stream.send(7); acknowledged = true }
        await started.wait()
        #expect(!acknowledged, "Offering an event is not transport delivery")
        delivery.open()
        try await request.value
        #expect(acknowledged)
        try await stream.send(8)
        #expect(received.values == [7, 8])
        try await stream.finish()
    }

    @Test func deliveryFailureFailsPendingAndFutureRequestsWithoutReplay() async throws {
        let received = StreamTestValues()
        let stream = AcknowledgedEventStream<Int> { events in
            for await event in events {
                await received.append(event)
                throw StreamTestFailure.delivery
            }
        }
        await #expect(throws: StreamTestFailure.delivery) { try await stream.send(7) }
        await #expect(throws: StreamTestFailure.delivery) { try await stream.send(8) }
        await #expect(throws: StreamTestFailure.delivery) { try await stream.finish() }
        #expect(received.values == [7])
    }

    @Test func finishingWaitsForTransportDrainInsteadOfOnlyClosingInput() async throws {
        let draining = StreamTestGate()
        let drained = StreamTestGate()
        let stream = AcknowledgedEventStream<Int> { events in
            for await _ in events {}
            await draining.open()
            await drained.wait()
        }
        try await stream.send(7)
        var finished = false
        let completion = Task { try await stream.finish(); finished = true }
        await draining.wait()
        #expect(!finished)
        drained.open()
        try await completion.value
        #expect(finished)
    }

    @Test func cancellationJoinsCleanupAndFailsAnUnacknowledgedEvent() async throws {
        let started = StreamTestGate()
        let received = StreamTestValues()
        let stream = AcknowledgedEventStream<Int> { events in
            do {
                for await _ in events {
                    await started.open()
                    try await Task.sleep(for: .seconds(60))
                }
            } catch {
                await received.append(99) // Original-display release/cleanup completes before cancel returns.
                throw error
            }
        }
        let pending = Task { try await stream.send(7) }
        await started.wait()
        await stream.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(received.values == [99])
    }
}

private enum StreamTestFailure: Error, Equatable { case delivery }

@MainActor private final class StreamTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor private final class StreamTestValues {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
