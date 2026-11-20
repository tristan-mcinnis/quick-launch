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

    /// Splits the Arguments field into argv elements the way a shell reads a
    /// line, without being one: whitespace separates, single or double quotes
    /// keep spaces inside one argument, and a backslash keeps the next
    /// character. Nothing is expanded. A quote left open runs to the end.
    static func splitArguments(_ line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false
        // macOS may turn typed quotes into curly ones; they mean the same.
        let straightened = line
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        for character in straightened {
            if escaped {
                // Inside double quotes a backslash escapes only a quote or
                // another backslash, as in a shell, so "\d+" keeps its
                // backslash.
                if quote == "\"", character != "\"", character != "\\" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
            } else if character.isWhitespace {
                if hasCurrent || !current.isEmpty { arguments.append(current) }
                current = ""
                hasCurrent = false
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if hasCurrent || !current.isEmpty { arguments.append(current) }
        return arguments
    }

    /// The Arguments field's text for stored argv elements: the inverse of
    /// `splitArguments`, quoting only what needs it.
    static func joinArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            let needsQuotes = argument.isEmpty
                || argument.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }
            guard needsQuotes else { return argument }
            let escaped = argument
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }.joined(separator: " ")
    }

    /// How long a command action may run. A hung tool used to run until
    /// Escape; a tool that really needs longer belongs in a terminal.
    static let timeout: TimeInterval = 300

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
                // The home folder, so a relative path in an argument means
                // what it means in a terminal.
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: timeout
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
