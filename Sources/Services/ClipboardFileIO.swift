import Foundation

/// Serial, bounded disk operations for explicit clipboard/capture actions.
/// The UI awaits this owner; no detached task survives a cancelled surface.
actor ClipboardFileIO {
    static let shared = ClipboardFileIO()

    func read(at url: URL, limit: Int) -> Data? {
        guard !Task.isCancelled, limit >= 0, limit < Int.max,
              !ScreenshotLibrary.isUnavailable(url),
              let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1),
              data.count <= limit, !Task.isCancelled else { return nil }
        return data
    }

    func writeCapture(_ data: Data, folder: URL, name: String) -> URL? {
        guard !Task.isCancelled else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = QuickViewModel.nonClobberingURL(in: folder, name: name)
            // Exclusive creation prevents racing another capture's filename.
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }

    func copy(from source: URL, to destination: URL) -> Bool {
        guard !Task.isCancelled, !ScreenshotLibrary.isUnavailable(source) else { return false }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch { return false }
    }

    /// The save panel has already obtained the user's destination choice.
    func write(_ data: Data, to destination: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch { return false }
    }
}
