import Foundation

/// Quick Launch's local snippet and Quicklink catalog.
///
/// The catalog is owner-only JSON under Application Support. On the first run
/// after this store was introduced, any surviving Tuna custom items and Smart
/// Links are copied in once. Tuna is never needed for later reads or writes.
@MainActor
final class LauncherCatalogService: LauncherCatalogServicing {
    enum MutationError: LocalizedError {
        case invalidSnippet, unreadableStore, snippetNotFound
        case invalidQuickLink, quickLinkNotFound

        var errorDescription: String? {
            switch self {
            case .invalidSnippet: "The snippet title and text cannot be empty."
            case .unreadableStore: "Quick Launch could not safely read its snippet store."
            case .snippetNotFound: "That snippet no longer exists in Quick Launch."
            case .invalidQuickLink: "A Quicklink needs a name and a web address."
            case .quickLinkNotFound: "That Quicklink no longer exists in Quick Launch."
            }
        }
    }

    private struct StoredItem: Codable, Equatable, Sendable {
        var itemID: String
        var title: String
        var value: String
        var requiresInput: Bool

        init(itemID: String, title: String, value: String, requiresInput: Bool = false) {
            self.itemID = itemID
            self.title = title
            self.value = value
            self.requiresInput = requiresInput
        }

        init(_ item: LauncherCatalogItem) {
            itemID = item.itemID
            title = item.title
            value = item.value
            requiresInput = item.requiresInput
        }

        private enum CodingKeys: String, CodingKey {
            case itemID, title, value, requiresInput
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try values.decode(String.self, forKey: .itemID)
            title = try values.decode(String.self, forKey: .title)
            value = try values.decode(String.self, forKey: .value)
            requiresInput = try values.decodeIfPresent(Bool.self, forKey: .requiresInput) ?? false
        }
    }

    private struct StoredCatalog: Codable, Equatable, Sendable {
        var snippets: [StoredItem] = []
        var quickLinks: [StoredItem] = []

        private enum CodingKeys: String, CodingKey {
            case snippets, quickLinks
        }

        init() {}

        init(snippets: [StoredItem], quickLinks: [StoredItem]) {
            self.snippets = snippets
            self.quickLinks = quickLinks
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            snippets = try values.decodeIfPresent([StoredItem].self, forKey: .snippets) ?? []
            quickLinks = try values.decodeIfPresent([StoredItem].self, forKey: .quickLinks) ?? []
        }
    }

    private(set) var snippets: [LauncherCatalogItem] = []
    private(set) var quickLinks: [LauncherCatalogItem] = []
    private(set) var loadErrorMessage: String?

    private let store: JSONFileStore<StoredCatalog>
    private let legacyPreferencesURL: URL
    private let legacyConfigURL: URL
    private var storedCatalog = StoredCatalog()
    private var storeIsReadable = true

    init(
        storeURL: URL = AppPaths.launcherCatalogFile,
        legacyPreferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.brnbw.Tuna.plist"),
        legacyConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tuna/config.toml")
    ) {
        store = JSONFileStore(fileURL: storeURL, schemaVersion: 1)
        self.legacyPreferencesURL = legacyPreferencesURL
        self.legacyConfigURL = legacyConfigURL
        reload()
    }

    func reload() {
        if store.exists {
            do {
                guard let catalog = try store.loadOrThrow() else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                storedCatalog = catalog
                storeIsReadable = true
                loadErrorMessage = nil
            } catch {
                storeIsReadable = false
                loadErrorMessage = "Quick Launch could not read its local snippet store. The file was left untouched."
                snippets = []
                quickLinks = []
                AppLog.persistence.error(
                    "Could not load launcher-catalog.json: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        } else {
            storedCatalog = Self.legacyCatalog(
                preferencesURL: legacyPreferencesURL,
                configURL: legacyConfigURL
            )
            storeIsReadable = true
            loadErrorMessage = nil
            if !storedCatalog.snippets.isEmpty || !storedCatalog.quickLinks.isEmpty {
                do {
                    try store.saveNow(storedCatalog)
                } catch {
                    AppLog.persistence.error(
                        "Could not migrate the legacy launcher catalog: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        publishStoredCatalog()
    }

    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.kind == .snippet, !cleanTitle.isEmpty, !value.isEmpty else {
            throw MutationError.invalidSnippet
        }
        guard let index = storedCatalog.snippets.firstIndex(where: { $0.itemID == item.itemID }) else {
            throw MutationError.snippetNotFound
        }
        var updated = storedCatalog
        updated.snippets[index].title = cleanTitle
        updated.snippets[index].value = value
        try persist(updated)
    }

    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        guard item.kind == .snippet else { throw MutationError.invalidSnippet }
        var updated = storedCatalog
        let oldCount = updated.snippets.count
        updated.snippets.removeAll { $0.itemID == item.itemID }
        guard updated.snippets.count != oldCount else { throw MutationError.snippetNotFound }
        try persist(updated)
    }

    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !value.isEmpty else { throw MutationError.invalidSnippet }
        let stored = StoredItem(
            itemID: "quick-launch-snippet-\(UUID().uuidString.lowercased())",
            title: cleanTitle,
            value: value
        )
        var updated = storedCatalog
        updated.snippets.append(stored)
        try persist(updated)
        guard let item = snippets.first(where: { $0.itemID == stored.itemID }) else {
            throw MutationError.snippetNotFound
        }
        return item
    }

    func updateQuickLink(_ item: LauncherCatalogItem, title: String, value: String) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.kind == .quickLink else { throw MutationError.invalidQuickLink }
        guard item.isEditableQuickLink else { throw MutationError.invalidQuickLink }
        guard !cleanTitle.isEmpty, ItemActionCatalog.looksLikeURL(cleanValue) else {
            throw MutationError.invalidQuickLink
        }
        guard let index = storedCatalog.quickLinks.firstIndex(where: { $0.itemID == item.itemID }) else {
            throw MutationError.quickLinkNotFound
        }
        var updated = storedCatalog
        updated.quickLinks[index].title = cleanTitle
        updated.quickLinks[index].value = cleanValue
        updated.quickLinks[index].requiresInput = QuickLinkQuery.contains(cleanValue)
        try persist(updated)
    }

    func deleteQuickLink(_ item: LauncherCatalogItem) throws {
        guard item.kind == .quickLink else { throw MutationError.invalidQuickLink }
        guard item.isEditableQuickLink else { throw MutationError.invalidQuickLink }
        var updated = storedCatalog
        let oldCount = updated.quickLinks.count
        updated.quickLinks.removeAll { $0.itemID == item.itemID }
        guard updated.quickLinks.count != oldCount else { throw MutationError.quickLinkNotFound }
        try persist(updated)
    }

    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, ItemActionCatalog.looksLikeURL(cleanValue) else {
            throw MutationError.invalidQuickLink
        }
        let stored = StoredItem(
            itemID: "quick-launch-link-\(UUID().uuidString.lowercased())",
            title: cleanTitle,
            value: cleanValue,
            requiresInput: QuickLinkQuery.contains(cleanValue)
        )
        var updated = storedCatalog
        updated.quickLinks.append(stored)
        try persist(updated)
        guard let item = quickLinks.first(where: { $0.itemID == stored.itemID }) else {
            throw MutationError.quickLinkNotFound
        }
        return item
    }

    private func persist(_ updated: StoredCatalog) throws {
        guard storeIsReadable else { throw MutationError.unreadableStore }
        try store.saveNow(updated)
        storedCatalog = updated
        publishStoredCatalog()
    }

    private func publishStoredCatalog() {
        snippets = storedCatalog.snippets.map {
            LauncherCatalogItem(
                kind: .snippet,
                itemID: $0.itemID,
                title: $0.title,
                detail: "Snippet",
                value: $0.value
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        quickLinks = storedCatalog.quickLinks.compactMap { stored in
            guard let url = URL(string: stored.value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return LauncherCatalogItem(
                kind: .quickLink,
                itemID: stored.itemID,
                title: stored.title,
                detail: url.host ?? "Quicklink",
                value: stored.value,
                requiresInput: stored.requiresInput || QuickLinkQuery.contains(stored.value)
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func legacyCatalog(preferencesURL: URL, configURL: URL) -> StoredCatalog {
        let custom = loadLegacyCustomItems(from: preferencesURL)
        let smartLinks = loadLegacySmartLinks(from: configURL)
        return StoredCatalog(
            snippets: custom.filter { $0.kind == .snippet }.map(StoredItem.init),
            quickLinks: (custom.filter { $0.kind == .quickLink } + smartLinks)
                .uniqued(by: \.id)
                .map(StoredItem.init)
        )
    }

    /// Reads Tuna's former custom-item format for a one-time local migration.
    static func loadLegacyCustomItems(from url: URL) -> [LauncherCatalogItem] {
        guard let records = readLegacyCustomItems(from: url) else { return [] }

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
                    detail: "Snippet",
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
                    detail: url.host ?? "Quicklink",
                    value: value,
                    requiresInput: QuickLinkQuery.contains(value)
                )
            default:
                return nil
            }
        }
    }

    private static func readLegacyCustomItems(from url: URL) -> [[String: Any]]? {
        AppLog.attempt("Read legacy Tuna custom items", {
            let data = try Data(contentsOf: url)
            guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let nested = root["CustomItemsCatalogItems"] as? Data,
                  let records = try PropertyListSerialization.propertyList(from: nested, format: nil) as? [[String: Any]]
            else { throw CocoaError(.propertyListReadCorrupt) }
            return records
        })
    }

    static func loadLegacySmartLinks(from url: URL) -> [LauncherCatalogItem] {
        guard let source = AppLog.attempt(
            "Read legacy Tuna smart links",
            { try String(contentsOf: url, encoding: .utf8) }
        ) else { return [] }
        return parseLegacySmartLinks(source)
    }

    static func parseLegacySmartLinks(_ source: String) -> [LauncherCatalogItem] {
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
            let host = URLComponents(string: preview)?.host ?? "Imported Smart Link"
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
