import Foundation

protocol QuickService: Sendable {
    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error>
    func send(
        messages: [QuickMessage],
        image: QuickImageAttachment?
    ) -> AsyncThrowingStream<StreamDelta, Error>
    func healthCheck() async throws -> Bool
}

extension QuickService {
    func send(
        messages: [QuickMessage],
        image: QuickImageAttachment?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages)
    }

    func send(prompt: String) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: [QuickMessage(role: .user, content: prompt)])
    }
}
