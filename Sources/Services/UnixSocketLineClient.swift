import Darwin
import Foundation

/// One request line out, one reply line back, over a Unix domain socket.
/// The house socket protocol is deliberately this small
/// (`design-system/docs/app-commands.md`), copied from local-dictation's
/// `ipc.rs`, which is the reference.
///
/// A socket path in the user's own config directory at mode 0600 is callable
/// only by them; that is why the contract uses one instead of a URL scheme.
///
/// Every call runs on a global queue, never the main actor, and every call
/// carries a timeout: connect, send, and receive each get one, so a dead
/// listener or an app that accepts and never answers cannot hold the
/// launcher.
typealias HouseSocketSending = @Sendable (URL, String, TimeInterval) async throws -> String

enum UnixSocketLineClient {

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the
    /// terminator. A longer path can never be connected to, so it is refused
    /// before a descriptor is opened.
    static let maximumPathLength = 103

    enum Failure: Error, Equatable {
        /// No listener, no such file, path too long, or the connect timed out.
        case cannotConnect
        /// Connected, but no complete reply line arrived in time.
        case timedOut
        /// The peer closed without sending a line.
        case noReply
    }

    /// The real client, as a value, so a service that talks to a socket
    /// takes one of these and a test hands it a fake.
    static let live: HouseSocketSending = { url, line, timeout in
        try await send(line, to: url, timeout: timeout)
    }

    static func send(_ line: String, to url: URL, timeout: TimeInterval) async throws -> String {
        let path = url.path
        guard path.utf8.count <= maximumPathLength else { throw Failure.cannotConnect }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reply = try exchange(line: line, path: path, timeout: timeout)
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals

    /// Blocking, on a global queue. Descriptors are closed on every path.
    private static func exchange(line: String, path: String, timeout: TimeInterval) throws -> String {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.cannotConnect }
        defer { close(descriptor) }

        var timeval = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        // A connect to a socket file nobody is listening on fails at once
        // (ECONNREFUSED); these bound the case where the peer accepts and
        // then goes quiet.
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<Darwin.timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<Darwin.timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.cannotConnect }

        // One request per line.
        var request = Array((line + "\n").utf8)
        var written = 0
        while written < request.count {
            let sent = request.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(descriptor, base.advanced(by: written), request.count - written, 0)
            }
            guard sent > 0 else { throw Failure.timedOut }
            written += sent
        }

        // One reply line. Reading stops at the first newline so a peer that
        // holds the connection open afterwards does not cost a timeout.
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(descriptor, base, raw.count, 0)
            }
            if read > 0 {
                reply.append(contentsOf: buffer[0..<read])
                if let newline = reply.firstIndex(of: UInt8(ascii: "\n")) {
                    return string(of: reply[reply.startIndex..<newline])
                }
                continue
            }
            if read == 0 {
                // Closed cleanly. Everything before the close is the reply.
                guard !reply.isEmpty else { throw Failure.noReply }
                return string(of: reply[...])
            }
            // EAGAIN / EWOULDBLOCK is the receive timeout firing.
            throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timedOut : Failure.noReply
        }
    }

    private static func string(of slice: Data.SubSequence) -> String {
        String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
