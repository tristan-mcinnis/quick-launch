import Foundation

@MainActor
final class TunaCatalogService: LauncherCatalogServicing {
    enum MutationError: LocalizedError {
        case invalidSnippet, unreadableStore, snippetNotFound

        var errorDescription: String? {
            switch self {
            case .invalidSnippet: "The snippet title and text cannot be empty."
            case .unreadableStore: "Quick Launch could not safely read Tuna's snippet store."
            case .snippetNotFound: "That snippet no longer exists in Tuna."
            }
        }
    }
    private(set) var snippets: [LauncherCatalogItem] = []
    private(set) var quickLinks: [LauncherCatalogItem] = []

    private let preferencesURL: URL
    private let configURL: URL

    init(
        preferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.brnbw.Tuna.plist"),
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tuna/config.toml")
    ) {
        self.preferencesURL = preferencesURL
        self.configURL = configURL
        reload()
    }

    func reload() {
        let custom = Self.loadCustomItems(from: preferencesURL)
        snippets = custom.filter { $0.kind == .snippet }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let fixedLinks = custom.filter { $0.kind == .quickLink }
        let smartLinks = Self.loadSmartLinks(from: configURL)
        quickLinks = (fixedLinks + smartLinks)
            .uniqued(by: \.id)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.kind == .snippet, !cleanTitle.isEmpty, !value.isEmpty else {
            throw MutationError.invalidSnippet
        }
        try mutateSnippet(item) { record in
            record["label"] = cleanTitle
            record["value"] = value
            return true
        }
    }

    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        guard item.kind == .snippet else { throw MutationError.invalidSnippet }
        try mutateSnippet(item) { _ in false }
    }

    private func mutateSnippet(
        _ item: LauncherCatalogItem,
        transform: (inout [String: Any]) -> Bool
    ) throws {
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data, format: nil
              ) as? [String: Any],
              let nested = root["CustomItemsCatalogItems"] as? Data,
              var records = try? PropertyListSerialization.propertyList(
                from: nested, format: nil
              ) as? [[String: Any]] else { throw MutationError.unreadableStore }

        let storedID = item.itemID.replacingOccurrences(of: "tuna-custom-", with: "")
        guard let index = records.firstIndex(where: {
            ($0["kind"] as? String) == "text"
                && ($0["id"] as? String)?.lowercased() == storedID.lowercased()
        }) else { throw MutationError.snippetNotFound }

        var record = records[index]
        if transform(&record) {
            records[index] = record
        } else {
            records.remove(at: index)
        }
        try writeRecords(records, root: root)
    }

    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !value.isEmpty else { throw MutationError.invalidSnippet }
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data, format: nil
              ) as? [String: Any],
              let nested = root["CustomItemsCatalogItems"] as? Data,
              var records = try? PropertyListSerialization.propertyList(
                from: nested, format: nil
              ) as? [[String: Any]] else { throw MutationError.unreadableStore }
        let id = UUID().uuidString.lowercased()
        records.append(["kind": "text", "id": id, "label": cleanTitle, "value": value])
        try writeRecords(records, root: root)
        guard let item = snippets.first(where: {
            $0.itemID.lowercased().hasSuffix(id) || ($0.title == cleanTitle && $0.value == value)
        }) else { throw MutationError.snippetNotFound }
        return item
    }

    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, ItemActionCatalog.looksLikeURL(cleanValue) else {
            throw MutationError.invalidSnippet
        }
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data, format: nil
              ) as? [String: Any],
              let nested = root["CustomItemsCatalogItems"] as? Data,
              var records = try? PropertyListSerialization.propertyList(
                from: nested, format: nil
              ) as? [[String: Any]] else { throw MutationError.unreadableStore }
        let id = UUID().uuidString.lowercased()
        records.append(["kind": "url", "id": id, "label": cleanTitle, "value": cleanValue])
        try writeRecords(records, root: root)
        guard let item = quickLinks.first(where: {
            $0.itemID.lowercased().hasSuffix(id) || ($0.title == cleanTitle && $0.value == cleanValue)
        }) else { throw MutationError.snippetNotFound }
        return item
    }

    /// Writes the custom-item records back with a timestamped backup beside
    /// the store, then reloads both catalogs.
    private func writeRecords(_ records: [[String: Any]], root: [String: Any]) throws {
        var root = root
        let backup = preferencesURL.deletingLastPathComponent().appendingPathComponent(
            "\(preferencesURL.lastPathComponent).quick-launch-backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        )
        try FileManager.default.copyItem(at: preferencesURL, to: backup)
        let updatedNested = try PropertyListSerialization.data(
            fromPropertyList: records, format: .binary, options: 0
        )
        root["CustomItemsCatalogItems"] = updatedNested
        let updatedRoot = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        try updatedRoot.write(to: preferencesURL, options: .atomic)
        reload()
    }

    static func loadCustomItems(from url: URL) -> [LauncherCatalogItem] {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              let nested = root["CustomItemsCatalogItems"] as? Data,
              let records = try? PropertyListSerialization.propertyList(
                from: nested,
                format: nil
              ) as? [[String: Any]] else { return [] }

        return records.compactMap { record in
            guard let kind = record["kind"] as? String,
                  let storedID = record["id"] as? String,
                  let value = record["value"] as? String,
                  !value.isEmpty else { return nil }
            let title = ((record["label"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch kind {
            case "text":
                return LauncherCatalogItem(
                    kind: .snippet,
                    itemID: "tuna-custom-\(storedID.lowercased())",
                    title: title.isEmpty ? "Untitled snippet" : title,
                    detail: "Tuna snippet",
                    value: value
                )
            case "url":
                guard let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                else { return nil }
                return LauncherCatalogItem(
                    kind: .quickLink,
                    itemID: "tuna-url-\(storedID.lowercased())",
                    title: title.isEmpty ? (url.host ?? "Untitled link") : title,
                    detail: url.host ?? "Tuna link",
                    value: value
                )
            default:
                return nil
            }
        }
    }

    static func loadSmartLinks(from url: URL) -> [LauncherCatalogItem] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseSmartLinks(source)
    }

    static func parseSmartLinks(_ source: String) -> [LauncherCatalogItem] {
        var records: [[String: String]] = []
        var current: [String: String]?

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[[") {
                if let current { records.append(current) }
                current = line == "[[smartLinks.entries]]" ? [:] : nil
                continue
            }
            guard current != nil,
                  !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            current?[key] = decodeTOMLScalar(rawValue)
        }
        if let current { records.append(current) }

        return records.compactMap { record in
            guard record["enabled"]?.lowercased() != "false",
                  let name = record["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let template = record["template"],
                  let scheme = URLComponents(string: template.replacingOccurrences(
                    of: "{{input}}",
                    with: "input"
                  ))?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { return nil }
            let preview = template
                .replacingOccurrences(of: "{{input}}", with: "")
                .replacingOccurrences(of: "{{clipboard}}", with: "")
            let host = URLComponents(string: preview)?.host ?? "Tuna Smart Link"
            return LauncherCatalogItem(
                kind: .quickLink,
                itemID: "tuna-smart-\(StableIdentifier.make(name + "\u{0}" + template))",
                title: name,
                detail: host,
                value: template,
                requiresInput: record["requiresInput"]?.lowercased() == "true"
                    || template.contains("{{input}}")
            )
        }
    }

    private static func decodeTOMLScalar(_ raw: String) -> String {
        if raw.hasPrefix("\""), raw.hasSuffix("\""),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
