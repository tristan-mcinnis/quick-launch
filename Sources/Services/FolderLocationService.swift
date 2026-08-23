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

    /// Fronts an existing Finder window already showing the folder, or opens a new one.
    /// The script is fixed; the path arrives as `item 1 of argv`, never interpolated.
    static let finderScript = """
    on run argv
      set p to POSIX file (item 1 of argv) as alias
      tell application "Finder"
        activate
        repeat with w in (every Finder window)
          try
            if (target of w as alias) is p then
              set index of w to 1
              return "fronted"
            end if
          end try
        end repeat
        set nw to make new Finder window to p
        set index of nw to 1
        return "opened"
      end tell
    end run
    """

    static func openPlan(for location: FolderLocation) -> (executable: String, arguments: [String]) {
        ("/usr/bin/osascript", ["-e", finderScript, "--", location.expandedURL.path])
    }

    /// Runs the plan; on any failure falls back to `NSWorkspace.shared.open` so the folder always opens.
    /// Returns false only when both fail.
    @MainActor
    static func open(_ location: FolderLocation) async -> Bool {
        if await runPlan(openPlan(for: location)) { return true }
        return NSWorkspace.shared.open(location.expandedURL)
    }

    @MainActor
    static func reveal(_ location: FolderLocation) {
        NSWorkspace.shared.activateFileViewerSelecting([location.expandedURL])
    }

    private static func runPlan(_ plan: (executable: String, arguments: [String])) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else { return false }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "fronted" || text == "opened"
    }
}
