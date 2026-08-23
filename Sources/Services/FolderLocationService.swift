import AppKit
import Foundation

/// A folder the launcher can open: built-in user folders plus folders the user adds in Settings.
struct FolderLocation: Identifiable, Equatable, Codable, Sendable {
    /// Stable: "downloads", "desktop", ... for built-ins; a `StableIdentifier` of the path for custom folders.
    var id: String
    var title: String
    /// Stored as given ("~/Downloads"); "~" is expanded at use time.
    var path: String
    var systemImage: String
    var isBuiltIn: Bool

    var expandedURL: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

enum FolderLocationService {
    static let builtIn: [FolderLocation] = [
        ("home", "Home", "~", "house"),
        ("desktop", "Desktop", "~/Desktop", "menubar.dock.rectangle"),
        ("documents", "Documents", "~/Documents", "doc.text"),
        ("downloads", "Downloads", "~/Downloads", "arrow.down.circle"),
        ("applications", "Applications", "/Applications", "app.badge"),
        ("pictures", "Pictures", "~/Pictures", "photo"),
        ("movies", "Movies", "~/Movies", "film"),
        ("music", "Music", "~/Music", "music.note"),
        ("public", "Public", "~/Public", "person.2"),
        ("library", "Library", "~/Library", "books.vertical"),
        ("icloud-drive", "iCloud Drive", "~/Library/Mobile Documents/com~apple~CloudDocs", "icloud"),
    ].map { FolderLocation(id: $0.0, title: $0.1, path: $0.2, systemImage: $0.3, isBuiltIn: true) }

    /// Built-ins that exist on disk plus the custom ones that exist, deduplicated by expanded path.
    static func available(custom: [FolderLocation], fileManager: FileManager = .default) -> [FolderLocation] {
        var seen = Set<String>()
        return (builtIn + custom).filter { location in
            let path = location.expandedURL.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            return seen.insert(path).inserted
        }
    }

    /// Make a custom location from a user-chosen folder URL (title = last path component).
    static func custom(from url: URL) -> FolderLocation {
        let path = url.standardizedFileURL.path
        return FolderLocation(
            id: StableIdentifier.make(path),
            title: url.lastPathComponent,
            path: path,
            systemImage: "folder",
            isBuiltIn: false
        )
    }

    /// Opens the folder in Finder right away. This used to front an existing
    /// Finder window through an osascript AppleScript, but that Apple Event
    /// exchange could hang for minutes on a busy system (measured at 107 s),
    /// so Return now takes the fast native route every time.
    @MainActor
    static func open(_ location: FolderLocation) async -> Bool {
        NSWorkspace.shared.open(location.expandedURL)
    }

    @MainActor
    static func reveal(_ location: FolderLocation) {
        NSWorkspace.shared.activateFileViewerSelecting([location.expandedURL])
    }
}
