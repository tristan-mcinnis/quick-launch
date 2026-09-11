import Foundation

// The view models reach the Mac through these four seams instead of AppKit
// singletons, so tests can run without touching the real pasteboard, the
// running-app list, Finder, or the display set. `Sources/Services/
// SystemServices.swift` holds the AppKit implementations.

/// The general pasteboard, reduced to plain text.
@MainActor
protocol PasteboardWriting: AnyObject {
    /// The current string item, if any.
    func readString() -> String?
    /// Replaces every item on the pasteboard with `text`: a copy the user
    /// keeps (a snippet, a cleaned link, text from the screen), so the
    /// Clipboard History and other clipboard managers record it.
    func writeString(_ text: String)
    /// Replaces every item on the pasteboard with `text`, marked transient and
    /// auto-generated (nspasteboard.org): an AI answer the app wrote, which
    /// the Clipboard History and other clipboard managers skip. The text is
    /// still one Command-V away.
    func writeTransientString(_ text: String)
}

/// Opens URLs, reveals files, and finds applications.
@MainActor
protocol WorkspaceOpening: AnyObject {
    func open(_ url: URL)
    /// Opens `url` with the application at `applicationURL`, bringing it
    /// forward when `activating` is true.
    func open(_ url: URL, withApplicationAt applicationURL: URL, activating: Bool)
    /// Shows the files in Finder, selected.
    func revealInFileViewer(_ urls: [URL])
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    /// Every application that can open `url`.
    func applicationURLs(toOpen url: URL) -> [URL]
}

/// One running application the overlay may hide, quit, or relaunch.
@MainActor
protocol RunningApplicationControlling: AnyObject {
    var isTerminated: Bool { get }
    @discardableResult func hide() -> Bool
    @discardableResult func terminate() -> Bool
    @discardableResult func forceTerminate() -> Bool
}

/// Looks up running applications.
@MainActor
protocol RunningApplicationsQuerying: AnyObject {
    /// True when the process is known and has exited. `nil` when the pid
    /// does not map to an application (test stubs, odd processes).
    func isTerminated(processIdentifier: pid_t) -> Bool?
    /// The running instance of an application, by bundle identifier first
    /// and bundle URL second.
    func runningApplication(bundleIdentifier: String?, bundleURL: URL) -> (any RunningApplicationControlling)?
}

/// The displays attached right now.
@MainActor
protocol ScreenGeometryProviding: AnyObject {
    var screenCount: Int { get }
}
