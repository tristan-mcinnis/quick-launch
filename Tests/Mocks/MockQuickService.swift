import Foundation
@testable import QuickLaunch

actor MockQuickService: QuickService {
    var responses: [StreamDelta] = []
    var shouldThrow: Bool = false
    var delay: Duration = .zero
    var sendCallCount: Int = 0
    var lastPrompt: String?
    var lastMessages: [QuickMessage] = []

    nonisolated func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        // Capture needed state before entering actor context
        AsyncThrowingStream { continuation in
            Task {
                let responses = await self.responses
                let shouldThrow = await self.shouldThrow
                let delay = await self.delay
                await self.recordCall(messages: messages)
                if shouldThrow {
                    continuation.finish(throwing: MockError.intentional)
                    return
                }
                for delta in responses {
                    if delay != .zero {
                        try? await Task.sleep(for: delay)
                    }
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }

    private func recordCall(messages: [QuickMessage]) {
        sendCallCount += 1
        lastMessages = messages
        lastPrompt = messages.last(where: { $0.role == .user })?.content
    }

    nonisolated func healthCheck() async throws -> Bool { true }

    enum MockError: Error {
        case intentional
    }
}
