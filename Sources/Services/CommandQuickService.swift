import Foundation

/// Runs a one-shot CLI provider directly, never through a shell. The prompt is
/// sent on stdin so user text cannot become command arguments.
struct CommandQuickService: QuickService, Sendable {
    let executable: URL
    let arguments: [String]
    let model: String
    let systemPrompt: String

    init?(
        configuration: CommandConfiguration,
        model: String,
        systemPrompt: String
    ) {
        guard let executable = ExecutableResolver.resolve(configuration.executable) else {
            return nil
        }
        self.executable = executable
        self.arguments = configuration.arguments
        self.model = model
        self.systemPrompt = systemPrompt
    }

    static func expandedArguments(
        _ arguments: [String],
        model: String,
        systemPrompt: String
    ) -> [String] {
        arguments.map {
            $0.replacingOccurrences(of: "{{model}}", with: model)
                .replacingOccurrences(of: "{{systemPrompt}}", with: systemPrompt)
        }
    }

    /// The argv and stdin for one request. A `.system` message (an
    /// assistant's instructions and context skills) goes in front of this
    /// service's system prompt in `{{systemPrompt}}`; a command whose
    /// arguments have no such placeholder gets it at the top of stdin
    /// instead, so the instructions are never dropped.
    static func invocation(
        arguments: [String],
        model: String,
        systemPrompt: String,
        messages: [QuickMessage]
    ) -> (arguments: [String], stdin: String) {
        let extra = messages.filter { $0.role == .system }.map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let turns = messages.filter { $0.role != .system }
        let takesSystemPrompt = arguments.contains { $0.contains("{{systemPrompt}}") }
        let system = (extra + [systemPrompt])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        var stdin = flatten(turns)
        if !takesSystemPrompt, !extra.isEmpty {
            stdin = extra.joined(separator: "\n\n") + "\n\n" + stdin
        }
        return (
            expandedArguments(arguments, model: model, systemPrompt: system),
            stdin
        )
    }

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        let invocation = Self.invocation(
            arguments: arguments,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages
        )
        let chunks = ProcessRunner.stream(
            executable: executable,
            arguments: invocation.arguments,
            stdin: Data(invocation.stdin.utf8),
            currentDirectory: FileManager.default.temporaryDirectory,
            onFailure: { status, stderr in
                let message = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return QuickServiceError.commandFailed(
                    message?.isEmpty == false ? message! : "Command exited with status \(status)"
                )
            }
        )
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await data in chunks {
                        try Task.checkCancellation()
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            continuation.yield(StreamDelta(text: text, finishReason: nil))
                        }
                    }
                    continuation.yield(StreamDelta(text: nil, finishReason: "stop"))
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
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    static func flatten(_ messages: [QuickMessage]) -> String {
        if messages.count == 1, let message = messages.first {
            return message.content
        }
        return messages.map { message in
            let label = message.role == .user ? "User" : "Assistant"
            return "\(label): \(message.content)"
        }.joined(separator: "\n\n") + "\n\nAssistant:"
    }
}
