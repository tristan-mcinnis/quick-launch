import Foundation

/// The optional House server: one SSH host alias, as `~/.ssh/config` names
/// it, that serves the vault search script, a self-hosted SearXNG, and a
/// trafilatura page reader.
///
/// Nothing in Quick Launch needs it. On a Mac with no such SSH entry, ssh
/// fails at once and each lane degrades: the Vault tool is not offered,
/// Vault Search reports the error, Automatic web search moves on to the next
/// backend, and a page read keeps its direct fetch.
///
/// `defaults write com.tristanmcinnis.quick-launch HouseServerHost <alias>`
/// points every lane at another host.
enum HouseServer {
    /// The alias the House setup uses when nothing else is set.
    static let defaultHost = "vault-vps"
    /// The user-defaults key that names another alias.
    static let hostDefaultsKey = "HouseServerHost"

    /// The configured alias, or `defaultHost`.
    static var host: String {
        let configured = UserDefaults.standard.string(forKey: hostDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? defaultHost : configured
    }
}
