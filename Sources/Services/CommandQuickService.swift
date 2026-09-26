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
                // A read can stop inside a character; decoding each read on
                // its own dropped that whole read.
                var decoder = UTF8ChunkDecoder()
                do {
                    for try await data in chunks {
                        try Task.checkCancellation()
                        let text = decoder.decode(data)
                        if !text.isEmpty {
                            continuation.yield(StreamDelta(text: text, finishReason: nil))
                        }
                    }
                    let tail = decoder.flush()
                    if !tail.isEmpty {
                        continuation.yield(StreamDelta(text: tail, finishReason: nil))
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

/// Decodes UTF-8 that arrives in arbitrary pieces, such as pipe reads. A
/// piece can end partway through a character; those bytes wait for the next
/// piece instead of failing the whole piece's decode.
struct UTF8ChunkDecoder: Sendable {
    private var pending = Data()

    /// The text the bytes so far complete. An incomplete character at the
    /// end is kept for the next call.
    mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        let complete = Self.completeLength(of: pending)
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending = Data(pending.dropFirst(complete))
        return text
    }

    /// Whatever is left when the stream ends, invalid bytes shown as U+FFFD.
    mutating func flush() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// How many leading bytes end on a character boundary: all of them,
    /// unless the last lead byte starts a sequence the bytes do not finish.
    static func completeLength(of bytes: Data) -> Int {
        let count = bytes.count
        var offset = count - 1
        while offset >= 0, count - offset <= 4 {
            let byte = bytes[bytes.startIndex + offset]
            guard byte & 0xC0 == 0x80 else {
                let needed = switch byte {
                case 0xF0...0xF7: 4
                case 0xE0...0xEF: 3
                case 0xC0...0xDF: 2
                default: 1
                }
                return count - offset < needed ? offset : count
            }
            offset -= 1
        }
        return count
    }
}
