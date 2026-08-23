import AppKit

/// `NSWorkspace.icon(forFile:)` costs about 5 ms the first time it sees an
/// app, which the launcher rows paid on the main thread while you typed.
/// Icons are kept here and warmed in small batches after launch.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    static func forget(path: String) {
        icons.removeValue(forKey: path)
    }

    /// Loads icons for `paths` a few at a time so launch stays responsive.
    static func prewarm(paths: [String]) {
        let missing = paths.filter { icons[$0] == nil }
        guard !missing.isEmpty else { return }
        Task { @MainActor in
            var index = 0
            while index < missing.count {
                let end = min(index + 8, missing.count)
                for path in missing[index..<end] { _ = icon(forPath: path) }
                index = end
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}
