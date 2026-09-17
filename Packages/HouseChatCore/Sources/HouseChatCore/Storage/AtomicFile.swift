import Darwin
import Foundation

/// Write-ahead file writing with the permissions set at creation.
///
/// Every state file this package writes goes through here:
/// - the temporary file is created with `O_EXCL | O_NOFOLLOW` and its final
///   mode (0600) in the same call, so the bytes are never readable by another
///   user even for an instant;
/// - the rename into place is atomic on one filesystem, and the directory is
///   fsynced afterwards;
/// - reads use `O_NOFOLLOW`, so a symlink planted where a state file belongs
///   is refused instead of followed.
enum AtomicFile {
    enum Failure: Error, Equatable {
        case open(path: String, errno: Int32)
        case write(path: String, errno: Int32)
        case rename(path: String, errno: Int32)
        case read(path: String, errno: Int32)
        /// A symlink sits where a real directory is required.
        case symlink(path: String)
        /// Something that is not a directory sits where one is required.
        case notADirectory(path: String)
    }

    static func write(_ data: Data, to url: URL, permissions: Int) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".house-chat-\(UUID().uuidString).tmp")
        let path = temporary.path
        let descriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(permissions))
        }
        guard descriptor >= 0 else { throw Failure.open(path: path, errno: errno) }
        var committed = false
        defer {
            close(descriptor)
            if !committed { unlink(path) }
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Failure.write(path: path, errno: errno)
                    }
                    offset += written
                }
            }
            if fsync(descriptor) != 0 { throw Failure.write(path: path, errno: errno) }
        } catch {
            if let failure = error as? Failure { throw failure }
            throw Failure.write(path: path, errno: errno)
        }

        if rename(path, url.path) != 0 {
            throw Failure.rename(path: url.path, errno: errno)
        }
        committed = true

        // The rename is only durable once the directory entry is synced.
        let directoryDescriptor = directory.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Reads a file, refusing a symlink and never following one.
    static func read(_ url: URL) throws -> Data {
        let path = url.path
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Failure.read(path: path, errno: errno) }
        defer { close(descriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.read(path: path, errno: errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Creates the directory if it is missing, tolerating a concurrent
    /// creation, and refuses a symlink or a non-directory in its place.
    ///
    /// The order matters: `lstat`, then an atomic `mkdir`, then - only on
    /// `EEXIST` - a second `lstat`. A directory another process created between
    /// the two checks is accepted, not mistaken for an unsafe path.
    ///
    /// When the directory already exists, is a real directory, and is owned by
    /// this process, its mode is narrowed to `permissions`. A directory this
    /// process does not own is left alone, and no path above `url` is touched.
    static func ensureDirectory(_ url: URL, permissions: Int) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try verifyDirectory(info, url)
            tightenIfOwned(url, info: info, permissions: permissions)
            return
        }

        if mkdir(url.path, mode_t(permissions)) == 0 { return }

        switch errno {
        case EEXIST:
            guard lstat(url.path, &info) == 0 else { throw Failure.open(path: url.path, errno: errno) }
            try verifyDirectory(info, url)
            tightenIfOwned(url, info: info, permissions: permissions)
        case ENOENT:
            // A parent is missing (a nested root): create the chain, then
            // verify what landed at `url`.
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: permissions)]
                )
            } catch {
                throw Failure.open(path: url.path, errno: errno)
            }
            guard lstat(url.path, &info) == 0 else { throw Failure.open(path: url.path, errno: errno) }
            try verifyDirectory(info, url)
            tightenIfOwned(url, info: info, permissions: permissions)
        default:
            throw Failure.open(path: url.path, errno: errno)
        }
    }

    /// True when the path exists and is a directory (never a symlink).
    static func isDirectoryNotSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func verifyDirectory(_ info: stat, _ url: URL) throws {
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw Failure.symlink(path: url.path)
        case S_IFDIR: return
        default: throw Failure.notADirectory(path: url.path)
        }
    }

    /// Narrow-only, and only on a directory this process owns.
    private static func tightenIfOwned(_ url: URL, info: stat, permissions: Int) {
        guard info.st_uid == geteuid() else { return }
        let current = Int(info.st_mode & 0o777)
        guard current & ~permissions != 0 else { return }
        chmod(url.path, mode_t(permissions))
    }

    /// True when the path exists and is a regular file (never a symlink).
    static func isRegularFile(_ url: URL) -> Bool {
        fileType(url) == S_IFREG
    }

    static func isDirectory(_ url: URL) -> Bool {
        fileType(url) == S_IFDIR
    }

    static func isSymlink(_ url: URL) -> Bool {
        fileType(url) == S_IFLNK
    }

    /// `lstat`'s file type, so a symlink is a symlink and never its target.
    static func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func permissions(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o777)
    }
}
