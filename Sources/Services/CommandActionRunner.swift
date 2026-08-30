import Foundation

/// Runs a saved command action directly, never through a shell. `{input}` is
/// substituted inside individual argv elements, so user text always stays a
/// single argument and can never become extra arguments or shell syntax.
enum CommandActionRunner {

    /// Replace `{input}` inside each argv element with the user's text.
    static func substitutedArguments(
        _ arguments: [String],
        input: String
    ) -> [String] {
        arguments.map { $0.replacingOccurrences(of: "{input}", with: input) }
    }

    /// Run `executable` with `arguments` (after `{input}` substitution) and
    /// return its stdout. A non-zero exit throws with the command's stderr;
    /// stdout from a failed command is never surfaced as a result.
    static func run(
        executable: String,
        arguments: [String],
        input: String
    ) async throws -> String {
        guard let url = ExecutableResolver.resolve(executable) else {
            throw QuickServiceError.commandFailed("\(executable) is not installed")
        }
        let argv = substitutedArguments(arguments, input: input)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = url
            process.arguments = argv
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw QuickServiceError.commandFailed(
                    message?.isEmpty == false
                        ? message!
                        : "Command exited with status \(process.terminationStatus)"
                )
            }
            var text = String(data: outputData, encoding: .utf8) ?? ""
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }.value
    }
}
