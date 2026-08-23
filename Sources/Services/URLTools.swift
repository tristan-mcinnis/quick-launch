import Foundation

/// Strips tracking parameters and text fragments from http(s) URLs.
enum URLCleaner {
    /// Removes tracking query parameters and fragments like `#:~:text=`.
    /// Returns nil when the input is not an http(s) URL. Keeps every other
    /// parameter and the original order. Returns the same string (not nil)
    /// when nothing had to be removed.
    static func clean(_ text: String) -> String? {
        cleanResult(text)?.string
    }

    /// True when `clean` would change the URL.
    static func hasTrackingParameters(_ text: String) -> Bool {
        cleanResult(text)?.changed ?? false
    }

    // MARK: - Rules

    /// Parameter names stripped on every host (lowercased).
    private static let globalNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid",
        "mc_cid", "mc_eid", "igshid", "igsh",
        "ref", "ref_src", "ref_url",
        "_hsenc", "_hsmi", "hsctatracking", "mkt_tok", "vero_id",
        "yclid", "twclid", "ttclid", "li_fat_id", "s_cid",
        "_ga", "_gl", "oly_anon_id", "oly_enc_id", "rb_clickid", "sc_cid",
        "trk", "trkcampaign",
    ]

    private static let globalPrefixes = ["utm_"]

    private static let shareIDHosts = ["open.spotify.com", "youtu.be", "youtube.com"]
    private static let youtubeHosts = ["youtube.com", "youtu.be"]
    private static let spmHosts = ["taobao.com", "aliexpress.com"]

    private struct CleanResult {
        let string: String
        let changed: Bool
    }

    private static func cleanResult(_ text: String) -> CleanResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty
        else { return nil }

        let host = rawHost.lowercased()
        var changed = false

        // Amazon product pages: collapse to /dp/ASIN and drop everything else.
        if isAmazon(host), let asin = amazonASIN(in: components.path) {
            let newPath = "/dp/\(asin)"
            if components.path != newPath || components.query != nil || components.fragment != nil {
                components.path = newPath
                components.percentEncodedQuery = nil
                components.percentEncodedFragment = nil
                changed = true
            }
        }

        // Query parameters.
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            let kept = items.filter { !isTracking($0, host: host) }
            if kept.count != items.count {
                components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
                changed = true
            }
        }

        // Text fragments: #:~:text=...
        if let fragment = components.percentEncodedFragment, fragment.hasPrefix(":~:") {
            components.percentEncodedFragment = nil
            changed = true
        }

        guard changed else { return CleanResult(string: trimmed, changed: false) }
        guard let result = components.string else { return nil }
        return CleanResult(string: result, changed: true)
    }

    private static func isTracking(_ item: URLQueryItem, host: String) -> Bool {
        let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
        if globalPrefixes.contains(where: name.hasPrefix) { return true }
        if globalNames.contains(name) { return true }

        switch name {
        case "si":
            return shareIDHosts.contains { hostMatches(host, $0) }
        case "feature":
            let value = (item.value?.removingPercentEncoding ?? item.value ?? "").lowercased()
            return value == "share" && youtubeHosts.contains { hostMatches(host, $0) }
        case "spm":
            return spmHosts.contains { hostMatches(host, $0) }
        default:
            return false
        }
    }

    private static func hostMatches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func isAmazon(_ host: String) -> Bool {
        host.split(separator: ".").contains("amazon")
    }

    /// Returns the product ID that follows `/dp/` or `/gp/product/`.
    private static func amazonASIN(in path: String) -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (index, segment) in segments.enumerated() {
            let next = index + 1
            guard next < segments.count else { continue }
            if segment == "dp" {
                return validASIN(segments[next])
            }
            if segment == "gp", segments[next] == "product", next + 1 < segments.count {
                return validASIN(segments[next + 1])
            }
        }
        return nil
    }

    private static func validASIN(_ candidate: String) -> String? {
        guard candidate.count == 10,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return candidate
    }
}

/// Turns text typed into the launcher into an openable URL when it looks like one.
enum TypedURLDetector {
    /// Returns an openable URL for input like "apple.com", "www.bbc.co.uk/news",
    /// "localhost:3000", "https://x.y", "example.com/path?q=1", "192.168.1.1".
    /// Returns nil for normal words, sentences, emails, file paths, and
    /// dotted tokens whose last label is not a known TLD ("file.txt", "v1.2").
    /// Adds https:// when the scheme is missing (http:// for localhost and
    /// private IPs).
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }

        // Explicit scheme: accept anything URL can parse with a host.
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: trimmed), let host = url.host(), !host.isEmpty else { return nil }
            return url
        }

        // Other schemes, emails, and file paths are not typed web URLs.
        if trimmed.contains("://") || trimmed.contains("@") { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") { return nil }

        // Split the authority (host[:port]) from the rest.
        let authorityEnd = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? trimmed.endIndex
        let authority = String(trimmed[..<authorityEnd])
        var host = authority
        if let colon = authority.firstIndex(of: ":") {
            host = String(authority[..<colon])
            let port = String(authority[authority.index(after: colon)...])
            guard !port.isEmpty, port.allSatisfy(\.isNumber),
                  let number = Int(port), (1...65535).contains(number)
            else { return nil }
        }

        let scheme: String
        let loweredHost = host.lowercased()
        if loweredHost == "localhost" {
            scheme = "http"
        } else if let octets = ipv4Octets(loweredHost) {
            scheme = isPrivate(octets) ? "http" : "https"
        } else if isDomain(loweredHost) {
            scheme = "https"
        } else {
            return nil
        }

        return URL(string: "\(scheme)://\(trimmed)")
    }

    // MARK: - Host checks

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivate(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (0, _):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return false }
        }
        guard let tld = labels.last else { return false }
        return knownTLDs.contains(String(tld))
    }

    /// Common generic TLDs plus two-letter country codes.
    static let knownTLDs: Set<String> = [
        // Generic and sponsored.
        "com", "net", "org", "io", "co", "app", "dev", "ai", "me", "info",
        "edu", "gov", "mil", "int", "tv", "fm", "xyz", "biz", "pro", "name",
        "mobi", "tech", "site", "online", "store", "shop", "blog", "news",
        "cloud", "page", "live", "studio", "design", "club", "art", "top",
        "vip", "one", "link", "wiki", "zone", "space", "world", "today",
        "life", "email", "network", "agency", "digital", "media", "solutions",
        "systems", "services", "software", "tools", "center", "company",
        "group", "team", "global", "earth", "academy", "school", "health",
        "finance", "money", "bank", "travel", "photo", "video", "music",
        "games", "run", "gg", "to", "ly", "cc", "ws", "nu", "tk",
        "im", "la", "ms", "st", "eu", "asia",
        // Left out on purpose because they read as file extensions in a
        // launcher: md, sh, py, so.
        // Country codes.
        "uk", "de", "fr", "cn", "jp", "us", "ca", "au", "nz", "in", "br",
        "mx", "es", "it", "nl", "be", "ch", "at", "se", "no", "dk", "fi",
        "pl", "pt", "ru", "ua", "cz", "hu", "ro", "gr", "tr", "il", "ae",
        "sa", "za", "ng", "ke", "eg", "ar", "cl", "pe", "ve", "kr", "hk",
        "tw", "sg", "my", "th", "vn", "ph", "id", "pk", "bd", "lk", "ie",
        "is", "lu", "li", "mc", "sk", "si", "hr", "rs", "bg", "lt", "lv",
        "ee", "by", "kz", "ge", "am", "az", "al", "ba", "mk", "cy", "mt",
        "qa", "kw", "om", "bh", "jo", "lb", "iq", "ir", "ma", "tn", "dz",
        "gh", "tz", "ug", "rw", "et", "zw", "zm", "mz", "ao", "ec", "uy",
        "bo", "cr", "pa", "do", "gt", "hn", "sv", "ni", "cu", "pr",
        "jm", "tt", "bs", "bm", "je", "gl", "fo", "ad", "sm", "va", "gi",
        "mo", "np", "mm", "kh", "uz", "mn",
    ]
}
