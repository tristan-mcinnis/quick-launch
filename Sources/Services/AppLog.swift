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
