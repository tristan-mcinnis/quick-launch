import Foundation
import Synchronization
@testable import QuickLaunch

/// A model whose first answer streams in two steps the test controls: it
/// sends `head`, then holds the stream open until `release()` (sends `tail`
/// and finishes) or `fail()` (throws). Every later call answers `followUp`
/// at once. Lets a test look at, stop, or queue behind an answer that is
/// still streaming. A consumer that stops listening (Stop) ends the hold.
final class GatedQuickService: QuickService {
    let head: String
    let tail: String
    let followUp: String

    /// Everything the test and the streams share, behind one lock.
    private struct State {
        var sendCallCount = 0
        var sentMessages: [[QuickMessage]] = []
        /// The first answer's outcome once decided: true sends the tail.
        var outcome: Bool?
        var gate: CheckedContinuation<Bool, Never>?
        var holdWaiters: [CheckedContinuation<Void, Never>] = []
        var isHolding = false
    }

    private let state = Mutex(State())

    init(head: String, tail: String = "", followUp: String = "The follow-up answer.") {
        self.head = head
        self.tail = tail
        self.followUp = followUp
    }

    var sendCallCount: Int { state.withLock { $0.sendCallCount } }
    /// What each call sent, in order.
    var sentMessages: [[QuickMessage]] { state.withLock { $0.sentMessages } }

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: [])
    }

    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let call = state.withLock { state in
            state.sendCallCount += 1
            state.sentMessages.append(messages)
            return state.sendCallCount
        }
        return AsyncThrowingStream { continuation in
            guard call == 1 else {
                continuation.yield(StreamDelta(text: followUp, finishReason: "stop"))
                continuation.finish()
                return
            }
            let producer = Task { [head, tail] in
                continuation.yield(StreamDelta(text: head, finishReason: nil))
                if await self.hold() {
                    if !tail.isEmpty { continuation.yield(StreamDelta(text: tail, finishReason: "stop")) }
                    continuation.finish()
                } else {
                    continuation.finish(throwing: MockQuickService.MockError.intentional)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.resolve(false)
                producer.cancel()
            }
        }
    }

    func healthCheck() async throws -> Bool { true }

    /// Returns once the first answer has sent its head and is held open.
    func waitUntilHolding() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.isHolding || state.outcome != nil { return true }
                state.holdWaiters.append(waiter)
                return false
            }
            if ready { waiter.resume() }
        }
    }

    /// Sends the tail and ends the first answer.
    func release() { resolve(true) }

    /// Ends the first answer with an error.
    func fail() { resolve(false) }

    private func hold() async -> Bool {
        await withCheckedContinuation { (gate: CheckedContinuation<Bool, Never>) in
            let (decided, waiters) = state.withLock { state -> (Bool?, [CheckedContinuation<Void, Never>]) in
                state.isHolding = true
                let waiters = state.holdWaiters
                state.holdWaiters.removeAll()
                if state.outcome == nil { state.gate = gate }
                return (state.outcome, waiters)
            }
            for waiter in waiters { waiter.resume() }
            if let decided { gate.resume(returning: decided) }
        }
    }

    private func resolve(_ released: Bool) {
        let gate = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = released
            let gate = state.gate
            state.gate = nil
            return gate
        }
        gate?.resume(returning: released)
    }
}
