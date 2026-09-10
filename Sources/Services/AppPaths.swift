import Foundation

/// The one place that knows where Quick Launch keeps its local data.
///
/// Every store used to build `~/Library/Application Support/Quick Launch`
/// by hand. The paths produced here are byte-identical to those, so files
/// written by earlier builds still load.
enum AppPaths {
    /// Folder name under `~/Library/Application Support`.
    static let applicationSupportFolderName = "Quick Launch"

    /// `~/Library/Application Support/Quick Launch`.
    static var applicationSupportDirectory: URL {
        applicationSupportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Same as `applicationSupportDirectory`, rooted at an explicit home.
    static func applicationSupportDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    /// A file directly inside the app's Application Support folder.
    static func file(_ name: String) -> URL {
        applicationSupportDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// A sub-folder of the app's Application Support folder.
    static func directory(_ name: String) -> URL {
        applicationSupportDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// Per-model profiles: which models are on, and their reasoning effort.
    static var modelPreferencesFile: URL {
        file("model-preferences.json")
    }
}
