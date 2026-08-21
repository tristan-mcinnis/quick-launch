import Foundation

protocol QuickService: Sendable {
    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error>
    func healthCheck() async throws -> Bool
}

extension QuickService {
    func send(prompt: String) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: [QuickMessage(role: .user, content: prompt)])
    }
}
