import Darwin
import Foundation

/// Why the root lock could not be taken.
public enum ArchiveRootLockError: Error, Sendable, Equatable, LocalizedError {
    case invalidRoot(String)
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): "Root lock needs a usable root: \(path)"
        case .openFailed(let path, let code): "Could not open the root lock \(path) (errno \(code))"
        case .lockFailed(let path, let code): "Could not take the root lock \(path) (errno \(code))"
        }
    }
}

/// An advisory exclusive lock over one archive root, shared by every
/// coordinator and every process that writes that root.
///
/// `flock(2)` on `<root>/.house-chat.lock`, taken for the duration of one call
/// and released when the descriptor closes, so:
/// - two `ArchiveRootLock` values for the same root contend, in one process or
///   across two;
/// - a crash releases the lock when the process's descriptors close;
/// - nothing has to be remembered between calls, which is why this is a value
///   type holding only the root.
///
/// The critical sections are short: one commit (store the bytes, then save the
/// conversation) and one explicit deletion scan. A waiter sleeps in tiny
/// backoff steps instead of blocking a thread, so the lock can never wedge a
/// concurrency pool: the cost is that a waiter may be delayed a few
/// milliseconds behind a burst of commits, which is the right trade for a
/// safety lock.
///
/// The lock is advisory: it only protects callers that take it. Every writer of
/// one root must go through the same coordinator (or the same lock) for the
/// guarantee to hold.
public struct ArchiveRootLock: Sendable {
    /// The directory this lock serializes access to.
    public let root: URL

    /// The lock file's name inside the root.
    public static let fileName = ".house-chat.lock"

    /// Longest pause between acquisition attempts.
    static let maximumBackoffMilliseconds = 25

    public init(root: URL) throws {
        guard root.isFileURL, !root.path.isEmpty, root.path != "/" else {
            throw ArchiveRootLockError.invalidRoot(root.path)
        }
        self.root = root
    }

    public var lockFileURL: URL {
        root.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Runs `body` while holding the exclusive lock, releasing it when `body`
    /// returns or throws.
    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        // The root must be a real directory (never a symlink) before a lock
        // file is created inside it.
        try AtomicFile.ensureDirectory(root, permissions: 0o700)
        let path = lockFileURL.path
        // O_NOFOLLOW: a symlink planted where the lock file belongs is refused,
        // so the lock cannot be moved to another file.
        let descriptor = path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw ArchiveRootLockError.openFailed(path: path, errno: errno)
        }
        do {
            try await Self.acquire(descriptor, path: path)
        } catch {
            close(descriptor)
            throw error
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        return try await body()
    }

    /// Takes the lock without blocking a thread: `LOCK_NB`, then a short sleep
    /// between attempts. Closing the descriptor releases the lock, so a crash
    /// cannot leave it held.
    private static func acquire(_ descriptor: Int32, path: String) async throws {
        var attempts = 0
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw ArchiveRootLockError.lockFailed(path: path, errno: code)
            }
            attempts += 1
            let milliseconds = min(maximumBackoffMilliseconds, 1 + attempts / 4)
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    }
}
