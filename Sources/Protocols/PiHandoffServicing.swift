import Foundation

/// What Continue in pi takes from the thread.
struct PiHandoffRequest: Sendable, Equatable {
    /// The chat's title, for the file name.
    var title: String
    /// The thread as `PiHandoffDocument` writes it.
    var markdown: String
    /// Where pi starts. Nil is the home folder: a Quick AI chat has no
    /// working folder of its own.
    var workingDirectory: URL?
}

/// What a hand-off left running.
struct PiHandoffResult: Sendable, Equatable {
    /// The detached tmux session pi runs in, `ql-` and a short id.
    let sessionName: String
    /// The thread file pi was given.
    let threadFile: URL
    /// False when Ghostty did not open. The session still runs; the caller
    /// copies `attachCommand` instead.
    let openedGhostty: Bool

    /// What to type in any terminal to reach the session.
    var attachCommand: String { "tmux attach -t \(sessionName)" }
}

enum PiHandoffError: LocalizedError, Equatable {
    case missingExecutable(String)
    case writeFailed(String)
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            "Continue in pi needs \(name) on this Mac. Install it, then try again."
        case .writeFailed(let reason):
            "Could not write the thread for pi: \(reason)"
        case .sessionFailed(let reason):
            "Could not start pi in tmux: \(reason)"
        }
    }
}

/// Continue in pi: hands the open thread to a new pi session in tmux and
/// opens a terminal on it.
protocol PiHandoffServicing: Sendable {
    func handOff(_ request: PiHandoffRequest) async throws -> PiHandoffResult
}
