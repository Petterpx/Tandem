import Foundation

/// Keeps one native input operation open while acknowledging each delivered primitive.
/// The consumer requests its next element only after delivery of the previous one
/// returns. In SimulatorHID this includes the transport's XPC send barrier.
@MainActor
final class AcknowledgedEventStream<Event: Sendable> {
    struct Events: AsyncSequence, Sendable {
        typealias Element = Event
        let input: AsyncStream<Event>
        let acknowledgements: Acknowledgements

        struct AsyncIterator: AsyncIteratorProtocol {
            var input: AsyncStream<Event>.AsyncIterator
            let acknowledgements: Acknowledgements
            private var hasPrevious = false
            init(input: AsyncStream<Event>.AsyncIterator, acknowledgements: Acknowledgements) {
                self.input = input
                self.acknowledgements = acknowledgements
            }
            mutating func next() async -> Event? {
                if hasPrevious { await acknowledgements.delivered() }
                let event = await input.next()
                hasPrevious = event != nil
                return event
            }
        }
        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(input: input.makeAsyncIterator(), acknowledgements: acknowledgements)
        }
    }

    @MainActor final class Acknowledgements {
        var pending: CheckedContinuation<Void, Error>?
        var completion: Result<Void, Error>?
        func delivered() {
            pending?.resume()
            pending = nil
        }
        func complete(_ result: Result<Void, Error>) {
            completion = result
            pending?.resume(with: result)
            pending = nil
        }
    }

    private let acknowledgements = Acknowledgements()
    private let input: AsyncStream<Event>.Continuation
    private let operation: Task<Void, Error>
    private var ended = false

    init(deliver: @escaping @Sendable (Events) async throws -> Void) {
        let (events, input) = AsyncStream<Event>.makeStream()
        self.input = input
        let acknowledgements = acknowledgements
        operation = Task {
            do {
                try await deliver(Events(input: events, acknowledgements: acknowledgements))
                acknowledgements.complete(.success(()))
            } catch {
                acknowledgements.complete(.failure(error))
                throw error
            }
        }
    }

    func send(_ event: Event) async throws {
        try Task.checkCancellation()
        if let completion = acknowledgements.completion { try completion.get() }
        guard !ended else { throw CancellationError() }
        // Helper requests are processed serially; there is one outstanding ACK.
        precondition(acknowledgements.pending == nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                acknowledgements.pending = continuation
                input.yield(event)
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.cancel() }
        }
    }

    /// Includes the operation's drain and final display validation.
    func finish() async throws {
        ended = true
        input.finish()
        try await operation.value
    }

    /// Joins native cleanup, including release on the original display.
    func cancel() async {
        ended = true
        operation.cancel()
        input.finish()
        _ = await operation.result
    }
}
