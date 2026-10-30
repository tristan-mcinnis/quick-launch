import Foundation

/// Reads one key from `~/.config/secrets.env`, the file the hourly key
/// refresh writes from 1Password. Read at call time, so a rotated key is
/// picked up without a relaunch; never cached, never logged.
enum SecretsEnv {
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/secrets.env")

    static func value(_ name: String, at url: URL = defaultFileURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value(name, in: text)
    }

    /// The value of the last `NAME=value` or `export NAME=value` line, with
    /// one pair of surrounding quotes removed. Nil when absent or empty.
    static func value(_ name: String, in text: String) -> String? {
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = line.trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("export ") { rest = String(rest.dropFirst(7)) }
            guard rest.hasPrefix(name + "=") else { continue }
            var value = String(rest.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            found = value
        }
        guard let found, !found.isEmpty else { return nil }
        return found
    }
}

/// The Tavily and Brave keys: the Keychain entry from Models › Web search,
/// else the one the hourly refresh keeps in `secrets.env`.
enum WebSearchKeys {
    static func tavily() -> String? {
        APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.tavilySearch)
            ?? SecretsEnv.value("TAVILY_API_KEY")
    }

    static func brave() -> String? {
        APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.braveSearch)
            ?? brave(in: (try? String(contentsOf: SecretsEnv.defaultFileURL, encoding: .utf8)) ?? "")
    }

    /// `BRAVE_SEARCH_API_KEY` is the 1Password name. `BRAVE_API_KEY` is the
    /// alias, used only when the primary name is absent or empty.
    static func brave(in text: String) -> String? {
        SecretsEnv.value("BRAVE_SEARCH_API_KEY", in: text)
            ?? SecretsEnv.value("BRAVE_API_KEY", in: text)
    }
}
