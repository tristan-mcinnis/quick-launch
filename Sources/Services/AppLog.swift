import Foundation
import OSLog

/// One `os.Logger` per subsystem so log lines can be filtered in Console.
///
/// Nothing here leaves the Mac. Messages should name the file or action,
/// never the content of clipboard, chat, or translation data.
enum AppLog {
    static let subsystem = "com.tristanmcinnis.quick-launch"

    /// JSON stores, SQLite, Keychain.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    /// Child processes and one-shot CLIs.
    static let process = Logger(subsystem: subsystem, category: "Process")
    /// Overlay window and panel lifecycle.
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    /// On-device OCR and other Vision work.
    static let recognition = Logger(subsystem: subsystem, category: "Recognition")

    /// Runs `body` and returns its value, or `nil` after logging the failure
    /// as `action`. A missing file is not logged: that is the normal state
    /// before anything has been saved. Use this where the caller can carry
    /// on without the result but the failure must still leave a trace.
    @discardableResult
    static func attempt<T>(
        _ action: String,
        logger: Logger = persistence,
        _ body: () throws -> T
    ) -> T? {
        do {
            return try body()
        } catch {
            if isMissingFile(error) { return nil }
            logger.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `attempt` for async work (child processes, Vision requests).
    @discardableResult
    nonisolated(nonsending)
    static func attemptAsync<T>(
        _ action: String,
        logger: Logger = persistence,
        _ body: () async throws -> T
    ) async -> T? {
        do {
            return try await body()
        } catch {
            if isMissingFile(error) { return nil }
            logger.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// True for "the file is not there yet", which is normal on first launch
    /// and must not fill the log.
    static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }
}
