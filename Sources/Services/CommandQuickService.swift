import Foundation

/// Runs a one-shot CLI provider directly, never through a shell. The prompt is
/// sent on stdin so user text cannot become command arguments.
struct CommandQuickService: QuickService, @unchecked Sendable {
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

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = Self.expandedArguments(
                arguments,
                model: model,
                systemPrompt: systemPrompt
            )
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let task = Task.detached(priority: .userInitiated) {
                do {
                    try process.run()
                    let prompt = Self.flatten(messages)
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    try? input.fileHandleForWriting.close()

                    while true {
                        try Task.checkCancellation()
                        let data = output.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            continuation.yield(StreamDelta(text: text, finishReason: nil))
                        }
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let data = errors.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw QuickServiceError.commandFailed(
                            message?.isEmpty == false ? message! : "Command exited with status \(process.terminationStatus)"
                        )
                    }
                    continuation.yield(StreamDelta(text: nil, finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    if process.isRunning { process.terminate() }
                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
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
