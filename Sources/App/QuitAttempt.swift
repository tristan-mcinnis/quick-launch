import Foundation

/// The identity of one quit attempt, and the one reply it may send.
///
/// AppKit's termination is a single pending request: returning
/// `.terminateLater` and replying once releases it. A second request while one
/// is running is coalesced into it, never answered twice. The phase moves
/// before the caller replies, so a reentrant quit during the reply cannot see
/// a live attempt, and a stale result cannot reset a newer one.
@MainActor
struct QuitAttempts {
    enum Phase: Equatable {
        case idle
        case waiting(Int)
        /// The quit was allowed; the process is on its way out.
        case finished
    }

    private var phase: Phase = .idle
    private var nextID = 0

    var current: Phase { phase }

    /// A quit is running or allowed. `applicationWillTerminate` uses this to
    /// skip the synchronous fallback after a normal quit.
    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Starts an attempt, or nil when one is already running or already
    /// allowed, so a repeated ⌘Q coalesces instead of replying twice.
    mutating func begin() -> Int? {
        guard case .idle = phase else { return nil }
        nextID &+= 1
        phase = .waiting(nextID)
        return nextID
    }

    /// Resolves the attempt and moves the phase before the caller replies.
    /// True means this call owns the reply; false means it is stale.
    mutating func resolve(_ id: Int, saved: Bool) -> Bool {
        guard case .waiting(let current) = phase, current == id else { return false }
        phase = saved ? .finished : .idle
        return true
    }
}
