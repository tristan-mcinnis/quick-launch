import Foundation

protocol QuickService: Sendable {
    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error>
    /// Images ride on the last user message. Services that cannot send
    /// images ignore them.
    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error>
    func healthCheck() async throws -> Bool
}

extension QuickService {
    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages)
    }

    func send(
        messages: [QuickMessage],
        image: QuickImageAttachment?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: image.map { [$0] } ?? [])
    }

    func send(prompt: String) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: [QuickMessage(role: .user, content: prompt)])
    }
}
