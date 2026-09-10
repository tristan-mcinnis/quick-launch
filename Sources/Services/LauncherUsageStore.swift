import Foundation

/// Quicksilver-style learning for the launcher.
///
/// Two local signals feed ranking:
///
/// 1. **Mnemonics.** The exact text that was typed when an item was chosen
///    (folded, per scope) maps to the items chosen for it. Type `cla`, pick
///    Claude, and `cla` ranks Claude first from then on.
/// 2. **Frecency.** A per-item use count that decays with a fixed half-life,
///    so last month's favourite does not outrank this week's.
///
/// Everything stays on this Mac. The store holds only launcher item
/// identifiers (bundle identifiers, command ids, snippet ids) and the short
/// typed abbreviations that led to a choice. Snippet and clipboard values are
/// never written here.
@MainActor
final class LauncherUsageStore {
    struct Record: Codable, Equatable, Sendable {
        var count: Double
        var lastUsed: Date
    }

    private struct Snapshot: Codable, Sendable {
        var version: Int = 1
        var mnemonics: [String: [String: Record]]
        var items: [String: Record]
    }

    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    static let maxQueryLength = 32
    static let maxMnemonics = 300
    static let maxItemsPerMnemonic = 6
    static let maxItems = 400
    nonisolated static let rootScope = "root"

    /// `"<scope>\u{1F}<query>"` → item id → record.
    private(set) var mnemonics: [String: [String: Record]] = [:]
    /// `"<scope>\u{1F}<item id>"` → record.
    private(set) var items: [String: Record] = [:]

    private let file: JSONFileStore<Snapshot>?
    var now: () -> Date

    /// Pass `nil` for an in-memory store (tests, previews).
    init(fileURL: URL?, now: @escaping () -> Date = Date.init) {
        self.file = fileURL.map { JSONFileStore(fileURL: $0) }
        self.now = now
        load()
    }

    static func defaultFileURL() -> URL {
        AppPaths.file("launcher-usage.json")
    }

    // MARK: - Recording

    /// Record that `itemID` was chosen after typing `query` in `scope`.
    func recordSelection(query: String, scope: String, itemID: String) {
        let stamp = now()
        let folded = Self.normalizedQuery(query)
        if !folded.isEmpty {
            let key = Self.mnemonicKey(scope: scope, query: folded)
            var bucket = mnemonics[key] ?? [:]
            bucket[itemID] = bumped(bucket[itemID], at: stamp)
            if bucket.count > Self.maxItemsPerMnemonic {
                let weakest = bucket.min { weight($0.value, at: stamp) < weight($1.value, at: stamp) }
                if let weakest { bucket.removeValue(forKey: weakest.key) }
            }
            mnemonics[key] = bucket
            pruneMnemonics(at: stamp)
        }
        recordUse(itemID: itemID, scope: scope, at: stamp)
        save()
    }

    /// Record a use that had no typed query, such as a global hotkey.
    func recordUse(itemID: String, scope: String = LauncherUsageStore.rootScope) {
        recordUse(itemID: itemID, scope: scope, at: now())
        save()
    }

    private func recordUse(itemID: String, scope: String, at stamp: Date) {
        let key = Self.itemKey(scope: scope, itemID: itemID)
        items[key] = bumped(items[key], at: stamp)
        if items.count > Self.maxItems {
            let weakest = items.min { weight($0.value, at: stamp) < weight($1.value, at: stamp) }
            if let weakest { items.removeValue(forKey: weakest.key) }
        }
    }

    func forget(itemID: String) {
        for key in mnemonics.keys {
            mnemonics[key]?.removeValue(forKey: itemID)
            if mnemonics[key]?.isEmpty == true { mnemonics.removeValue(forKey: key) }
        }
        items = items.filter { !$0.key.hasSuffix("\u{1F}" + itemID) }
        save()
    }

    func reset() {
        mnemonics.removeAll()
        items.removeAll()
        save()
    }

    var isEmpty: Bool { mnemonics.isEmpty && items.isEmpty }

    // MARK: - Reading

    /// Decayed weight of the exact mnemonic `query` → `itemID` in `scope`.
    func mnemonicWeight(query: String, scope: String, itemID: String) -> Double {
        let folded = Self.normalizedQuery(query)
        guard !folded.isEmpty,
              let record = mnemonics[Self.mnemonicKey(scope: scope, query: folded)]?[itemID]
        else { return 0 }
        return weight(record, at: now())
    }

    /// Decayed use count of `itemID` in `scope`, regardless of what was typed.
    func frecency(itemID: String, scope: String = LauncherUsageStore.rootScope) -> Double {
        guard let record = items[Self.itemKey(scope: scope, itemID: itemID)] else { return 0 }
        return weight(record, at: now())
    }

    /// Item ids in `scope`, most used first.
    func topItemIDs(scope: String = LauncherUsageStore.rootScope, limit: Int) -> [String] {
        let stamp = now()
        let prefix = scope + "\u{1F}"
        var ranked: [(id: String, weight: Double)] = []
        for (key, record) in items where key.hasPrefix(prefix) {
            let value = weight(record, at: stamp)
            guard value >= 0.5 else { continue }
            ranked.append((String(key.dropFirst(prefix.count)), value))
        }
        ranked.sort { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.id < rhs.id : lhs.weight > rhs.weight
        }
        return ranked.prefix(max(0, limit)).map(\.id)
    }

    /// Ranking signals for every item that has history relevant to `query`.
    ///
    /// Computed once per keystroke so each candidate costs one dictionary read.
    func signals(query: String, scope: String) -> [String: LauncherRankSignal] {
        let stamp = now()
        let folded = Self.normalizedQuery(query)
        var result: [String: LauncherRankSignal] = [:]

        let scopePrefix = scope + "\u{1F}"
        for (key, record) in items where key.hasPrefix(scopePrefix) {
            let itemID = String(key.dropFirst(scopePrefix.count))
            result[itemID, default: LauncherRankSignal()].frecency = weight(record, at: stamp)
        }

        guard !folded.isEmpty else { return result }

        if let exact = mnemonics[Self.mnemonicKey(scope: scope, query: folded)] {
            for (itemID, record) in exact {
                result[itemID, default: LauncherRankSignal()].exactMnemonic = weight(record, at: stamp)
            }
        }

        // Shorter abbreviations that were learned for the same item still help
        // once the user keeps typing ("cl" learned, "cla" typed)...
        var shorter = folded
        while shorter.count > 1 {
            shorter.removeLast()
            guard let bucket = mnemonics[Self.mnemonicKey(scope: scope, query: shorter)] else { continue }
            for (itemID, record) in bucket {
                let value = weight(record, at: stamp)
                if value > result[itemID, default: LauncherRankSignal()].relatedMnemonic {
                    result[itemID, default: LauncherRankSignal()].relatedMnemonic = value
                }
            }
        }

        // ...and longer learned abbreviations help when the user types less
        // ("cla" learned, "c" typed).
        let keyPrefix = Self.mnemonicKey(scope: scope, query: folded)
        for (key, bucket) in mnemonics where key.hasPrefix(keyPrefix) && key != keyPrefix {
            for (itemID, record) in bucket {
                let value = weight(record, at: stamp)
                if value > result[itemID, default: LauncherRankSignal()].relatedMnemonic {
                    result[itemID, default: LauncherRankSignal()].relatedMnemonic = value
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    static func normalizedQuery(_ query: String) -> String {
        let folded = FuzzyMatcher
            .fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
            .lowercased()
        return String(folded.prefix(maxQueryLength))
    }

    static func mnemonicKey(scope: String, query: String) -> String {
        scope + "\u{1F}" + query
    }

    static func itemKey(scope: String, itemID: String) -> String {
        scope + "\u{1F}" + itemID
    }

    private func weight(_ record: Record, at stamp: Date) -> Double {
        let age = max(0, stamp.timeIntervalSince(record.lastUsed))
        return record.count * pow(0.5, age / Self.halfLife)
    }

    private func bumped(_ record: Record?, at stamp: Date) -> Record {
        guard let record else { return Record(count: 1, lastUsed: stamp) }
        return Record(count: weight(record, at: stamp) + 1, lastUsed: stamp)
    }

    private func pruneMnemonics(at stamp: Date) {
        guard mnemonics.count > Self.maxMnemonics else { return }
        let ranked = mnemonics.map { key, bucket -> (String, Double) in
            (key, bucket.values.map { weight($0, at: stamp) }.max() ?? 0)
        }
        .sorted { $0.1 < $1.1 }
        for (key, _) in ranked.prefix(mnemonics.count - Self.maxMnemonics) {
            mnemonics.removeValue(forKey: key)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let snapshot = file?.load() else { return }
        mnemonics = snapshot.mnemonics
        items = snapshot.items
    }

    private func save() {
        file?.save(Snapshot(mnemonics: mnemonics, items: items))
    }

    /// Tests: block until queued writes are on disk.
    func waitForPendingWrites() {
        file?.flush()
    }
}

/// Learned evidence for one launcher item against the current query.
struct LauncherRankSignal: Equatable, Sendable {
    /// Decayed count of times this item was chosen for exactly this query.
    var exactMnemonic: Double = 0
    /// Best decayed count for a shorter or longer learned abbreviation.
    var relatedMnemonic: Double = 0
    /// Decayed use count independent of the query.
    var frecency: Double = 0
}

/// Turns learned signals into a score boost that composes with fuzzy scores.
///
/// Tiers, highest first:
/// - exact mnemonic: beats an exact alias (12 000) or exact name (10 000),
///   because the user has already told us what this abbreviation means;
/// - related mnemonic: beats a name-prefix match (2 000) but not an exact
///   name, so `c` prefers a learned Claude over Calendar, and `calendar`
///   still opens Calendar;
/// - frecency: a small tie-breaker among otherwise equal matches.
enum LauncherRanker {
    static let exactMnemonicBase = 20_000
    static let relatedMnemonicBase = 2_500
    static let frecencyCap = 1_200
    /// A pinned item that matches the query outranks plain use counts but
    /// not a learned abbreviation.
    static let pinnedBoost = 1_500

    static func boost(for signal: LauncherRankSignal?) -> Int {
        guard let signal else { return 0 }
        var boost = 0
        if signal.exactMnemonic > 0 {
            boost += exactMnemonicBase + Int(min(signal.exactMnemonic, 20) * 200)
        } else if signal.relatedMnemonic > 0 {
            boost += relatedMnemonicBase + Int(min(signal.relatedMnemonic, 20) * 100)
        }
        boost += min(frecencyCap, Int(min(signal.frecency, 30) * 40))
        return boost
    }
}
