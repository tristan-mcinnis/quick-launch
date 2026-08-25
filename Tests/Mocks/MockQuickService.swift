import Foundation
@testable import QuickLaunch

actor MockQuickService: QuickService {
    var responses: [StreamDelta] = []
    var shouldThrow: Bool = false
    var delay: Duration = .zero
    var sendCallCount: Int = 0
    var lastPrompt: String?
    var lastMessages: [QuickMessage] = []
    var lastImage: QuickImageAttachment? { lastImages.last }
    var lastImages: [QuickImageAttachment] = []

    nonisolated func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: [])
    }

    nonisolated func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        // Capture needed state before entering actor context
        AsyncThrowingStream { continuation in
            let producer = Task {
                let responses = await self.responses
                let shouldThrow = await self.shouldThrow
                let delay = await self.delay
                await self.recordCall(messages: messages, images: images)
                if shouldThrow {
                    continuation.finish(throwing: MockError.intentional)
                    return
                }
                for delta in responses {
                    if delay != .zero {
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            // Consumer cancelled: stop delivering, like a
                            // real HTTP stream torn down mid-flight.
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(delta)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func recordCall(messages: [QuickMessage], images: [QuickImageAttachment]) {
        sendCallCount += 1
        lastMessages = messages
        lastPrompt = messages.last(where: { $0.role == .user })?.content
        lastImages = images
    }

    nonisolated func healthCheck() async throws -> Bool { true }

    enum MockError: Error {
        case intentional
    }
}
