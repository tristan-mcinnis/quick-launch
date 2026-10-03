import AppKit
import Foundation

/// The live `ChatBackendProbing`. tmux, pi, and recall are found the way
/// Continue in pi and the Memory tool find them (`ExecutableResolver`:
/// `~/.local/bin`, `/opt/homebrew/bin`, and the other usual folders, then
/// `PATH`); Ghostty by the bundle identifier the hand-off opens; the vault
/// lane by `ssh -G <House server host>`, which prints what ssh would use from the
/// config and never connects.
///
/// An actor: it owns the one child process, and every lookup runs on its
/// executor, off the main thread.
actor ChatBackendProbe: ChatBackendProbing {
    typealias Resolve = @Sendable (_ name: String) -> URL?
    typealias ApplicationLookup = @Sendable (_ bundleIdentifier: String) -> URL?

    /// `ssh -G` reads files only; this bounds a broken config's `Match exec`.
    static let sshConfigTimeout: TimeInterval = 3

    private let resolve: Resolve
    private let applicationURL: ApplicationLookup
    private let run: ProcessRunning
    private let vaultHost: String

    init(
        resolve: @escaping Resolve = { ExecutableResolver.resolve($0) },
        applicationURL: @escaping ApplicationLookup = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        run: @escaping ProcessRunning = ProcessRunner.live,
        vaultHost: String = HouseServer.host
    ) {
        self.resolve = resolve
        self.applicationURL = applicationURL
        self.run = run
        self.vaultHost = vaultHost
    }

    func probe() async -> ChatBackendStatus {
        let vaultHostConfigured = await isVaultHostConfigured()
        return ChatBackendStatus(
            tmuxFound: resolve("tmux") != nil,
            piFound: resolve("pi") != nil,
            ghosttyFound: applicationURL(PiHandoffService.ghosttyBundleIdentifier) != nil,
            recallFound: resolve("recall") != nil,
            vaultHostConfigured: vaultHostConfigured,
            vaultHost: vaultHost
        )
    }

    private func isVaultHostConfigured() async -> Bool {
        guard let result = try? await run(
            SSHRunner.executable,
            Self.sshConfigArguments(host: vaultHost),
            Self.sshConfigTimeout
        ), result.status == 0 else { return false }
        return Self.isConfigured(sshConfig: result.stdoutText, host: vaultHost)
    }

    /// `ssh -G <host>`: the resolved options, one `key value` per line.
    nonisolated static func sshConfigArguments(host: String) -> [String] {
        ["-G", host]
    }

    /// A host with a `HostName` of its own is configured. With no entry,
    /// ssh echoes the alias back as the host name.
    nonisolated static func isConfigured(sshConfig: String, host: String) -> Bool {
        for line in sshConfig.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "hostname" else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name.lowercased() != host.lowercased()
        }
        return false
    }
}
