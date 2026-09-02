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
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: url,
                arguments: argv,
                currentDirectory: FileManager.default.temporaryDirectory
            )
        } catch let error as ProcessRunnerError {
            throw QuickServiceError.commandFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw QuickServiceError.commandFailed(
                result.trimmedStderr ?? "Command exited with status \(result.status)"
            )
        }
        var text = String(data: result.stdout, encoding: .utf8) ?? ""
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
