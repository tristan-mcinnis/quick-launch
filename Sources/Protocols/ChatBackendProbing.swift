import Foundation

/// What Settings › General › Chat says about the programs the chat features
/// lean on: Continue in pi (tmux, pi, Ghostty) and the tool backends (the
/// `recall` CLI for Memory, the vault-vps SSH host for Vault).
struct ChatBackendStatus: Sendable, Equatable {
    var tmuxFound: Bool
    var piFound: Bool
    var ghosttyFound: Bool
    var recallFound: Bool
    /// vault-vps has an entry of its own in the SSH config.
    var vaultHostConfigured: Bool

    /// Everything found, some of it, or none of what the feature needs.
    enum Level: Sendable, Equatable {
        case ready
        case partial
        case missing
    }

    /// tmux and pi are required; without Ghostty the session still starts
    /// and the attach command is copied instead.
    var piLevel: Level {
        guard tmuxFound, piFound else { return .missing }
        return ghosttyFound ? .ready : .partial
    }

    var piLine: String {
        let missing = [("tmux", tmuxFound), ("pi", piFound), ("Ghostty", ghosttyFound)]
            .filter { !$0.1 }
            .map(\.0)
        guard !missing.isEmpty else { return "tmux, pi and Ghostty found." }
        let names = Self.joined(missing)
        if tmuxFound, piFound {
            return "\(names) not found. pi still starts in tmux."
        }
        return "\(names) not found. Continue in pi needs tmux and pi."
    }

    var toolsLevel: Level {
        switch (recallFound, vaultHostConfigured) {
        case (true, true): .ready
        case (false, false): .missing
        default: .partial
        }
    }

    var toolsLine: String {
        let memory = recallFound ? "recall found." : "recall not found, so Memory cannot run."
        let vault = vaultHostConfigured
            ? "vault-vps is in your SSH config."
            : "vault-vps is not in your SSH config."
        return "\(memory) \(vault)"
    }

    /// "a", "a and b", "a, b and c".
    private static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Looks up the programs behind `ChatBackendStatus`. Settings asks when the
/// General pane appears; the answer arrives off the main thread, so the
/// pane never waits on it.
protocol ChatBackendProbing: Sendable {
    func probe() async -> ChatBackendStatus
}
