import Foundation

/// Streaming OpenAI Chat Completions client. One instance per request;
/// it holds no connection state between calls.
struct OpenAICompatibleService: QuickService, @unchecked Sendable {
    let baseURL: URL
    let modelName: String
    let apiKey: String?
    let systemPrompt: String
    private let session: URLSession

    static let systemPrompt = QuickSettings.defaultSystemPrompt

    /// `baseURL` is used as given; providers include `/v1` themselves when
    /// their endpoint needs it.
    init(
        baseURL: URL,
        modelName: String,
        apiKey: String? = nil,
        systemPrompt: String = QuickSettings.defaultSystemPrompt,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.session = session
    }

    func buildRequest(prompt: String) throws -> URLRequest {
        try buildRequest(messages: [QuickMessage(role: .user, content: prompt)])
    }

    func buildRequest(messages: [QuickMessage]) throws -> URLRequest {
        try buildRequest(messages: messages, images: [])
    }

    func buildRequest(
        messages: [QuickMessage],
        image: QuickImageAttachment?
    ) throws -> URLRequest {
        try buildRequest(messages: messages, images: image.map { [$0] } ?? [])
    }

    func buildRequest(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var wireMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for (index, message) in messages.enumerated() {
            let isLastUserMessage = index == messages.indices.last && message.role == .user
            if isLastUserMessage, !images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": message.content]]
                for image in images {
                    parts.append(["type": "image_url", "image_url": ["url": image.dataURL]])
                }
                wireMessages.append([
                    "role": message.role.rawValue,
                    "content": parts,
                ])
            } else {
                wireMessages.append([
                    "role": message.role.rawValue,
                    "content": message.content,
                ])
            }
        }
        let body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": wireMessages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: [])
    }

    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, images: images)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw QuickServiceError.connectionFailed("Invalid HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw QuickServiceError.serverError("HTTP \(http.statusCode)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let choice = choices.first
                        else { continue }
                        let delta = choice["delta"] as? [String: Any]
                        let text = delta?["content"] as? String
                        let finishReason = choice["finish_reason"] as? String
                        if text != nil || finishReason != nil {
                            continuation.yield(StreamDelta(text: text, finishReason: finishReason))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

enum QuickServiceError: LocalizedError {
    case serverError(String)
    case streamError(String)
    case connectionFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let message), .streamError(let message),
             .connectionFailed(let message), .commandFailed(let message):
            return message
        }
    }
}
