import AppKit
import Foundation

/// The application a clipboard copy is attributed to.
///
/// This is "the app that was in front when the copy was observed", resolved
/// from the frontmost application at capture time. It is deliberately not a
/// claim about the true originating process: a service, an extension, or a
/// hidden helper can put bytes on the pasteboard, and Quick Launch only sees
/// foreground state. Copy that wording stays in the UI, never "copied from".
struct ClipboardSourceInfo: Codable, Sendable, Equatable, Hashable {
    /// The app's bundle identifier, when it has one. The exclusion list keys
    /// on this because names are not stable or unique.
    var bundleIdentifier: String?
    /// The display name at capture time.
    var name: String

    init(bundleIdentifier: String?, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// A short, bounded tag derived from the app name, used for search and
    /// the source filter. Nil for a blank name. Names are trimmed and capped
    /// so a hostile or odd localized name cannot bloat the history metadata.
    var tag: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }

    /// The same app as another observation, by bundle identifier when both
    /// have one, otherwise by case-insensitive name.
    func isSameApp(as other: ClipboardSourceInfo) -> Bool {
        if let lhs = bundleIdentifier, let rhs = other.bundleIdentifier,
           !lhs.isEmpty, !rhs.isEmpty {
            return lhs == rhs
        }
        return name.compare(other.name, options: .caseInsensitive) == .orderedSame
    }
}

/// Resolves the app in front when a clipboard copy is observed. A seam so
/// tests are deterministic and never read the real window server, and so a
/// future better resolver (an Accessibility frontmost app) can replace the
/// default without touching the store.
@MainActor
protocol ClipboardSourceResolving: AnyObject {
    func currentClipboardSource() -> ClipboardSourceInfo?
}

/// The default resolver: the frontmost application from `NSWorkspace`.
@MainActor
final class SystemClipboardSourceResolver: ClipboardSourceResolving {
    func currentClipboardSource() -> ClipboardSourceInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
        return ClipboardSourceInfo(bundleIdentifier: app.bundleIdentifier, name: name)
    }
}

/// How long an *unpinned* clipboard entry may live. Opt-in: the default is
/// `forever`, so an existing history is never silently expired by an update.
/// Pinned entries are always kept, whatever the retention is.
enum ClipboardRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case forever
    case fiveMinutes
    case oneHour
    case oneDay
    case oneWeek
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: "Forever"
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        case .oneDay: "1 day"
        case .oneWeek: "1 week"
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        }
    }

    /// The window length, or nil for `forever`.
    var interval: TimeInterval? {
        switch self {
        case .forever: nil
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .oneMonth: 30 * 24 * 60 * 60
        case .threeMonths: 90 * 24 * 60 * 60
        case .sixMonths: 180 * 24 * 60 * 60
        case .oneYear: 365 * 24 * 60 * 60
        }
    }

    /// The oldest instant an unpinned entry may have and still be kept, or
    /// nil when nothing expires. `now` is injected so the policy is testable
    /// without waiting.
    func cutoff(from now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

/// Which Apple Vision recognition level a captured image is read with.
enum ClipboardOCRMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast
    case accurate

    var id: String { rawValue }
    var displayName: String { self == .fast ? "Fast" : "Accurate" }
}

/// The user's clipboard-capture policy, kept in step with Settings by the
/// owner. It never carries content: only which apps to skip, how long to
/// keep, and how (and whether) to read text from images.
struct ClipboardCapturePolicy: Equatable, Sendable {
    /// Bundle identifiers whose copies are never recorded. The reference
    /// defaults are password managers; Quick Launch ships the list empty and
    /// lets the user add apps, but never records concealed/transient content
    /// whatever this says.
    var disabledSourceBundleIDs: Set<String> = []
    /// How long an unpinned entry lives. Opt-in; `forever` by default.
    var retention: ClipboardRetention = .forever
    /// Recognize text from a copied image (on-device Vision) for search and
    /// the "copy text" actions.
    var ocrEnabled: Bool = true
    /// Fast or accurate recognition.
    var ocrMode: ClipboardOCRMode = .accurate
    /// Record a Universal Clipboard copy that arrived from another device.
    /// Off by default. Markers (concealed/transient/auto-generated) are
    /// honoured either way; this only decides whether the remote type is
    /// treated as content to skip.
    var captureRemote: Bool = false
    /// Attach a source-app tag to each entry for filtering.
    var sourceTagsEnabled: Bool = true

    static let `default` = ClipboardCapturePolicy()

    /// True when a copy attributed to `source` must not be recorded.
    func excludes(_ source: ClipboardSourceInfo?) -> Bool {
        guard let bundleID = source?.bundleIdentifier, !bundleID.isEmpty else { return false }
        return disabledSourceBundleIDs.contains(bundleID)
    }
}

/// A practical filter over the clipboard catalog. Empty `kinds` means every
/// kind. `sourceBundleID` and `tag` are mutually exclusive in the UI but the
/// predicate honours either if both are set.
struct ClipboardCatalogFilter: Equatable, Sendable {
    var kinds: Set<ClipboardPayloadKind> = []
    var pinnedOnly: Bool = false
    var sourceBundleID: String?
    /// A source app name, from the `source:` query token. Matched against the
    /// observed app name (case-insensitive) or its bundle identifier.
    var sourceName: String?
    var tag: String?

    /// Whether any filter is narrowing the list.
    var isActive: Bool {
        !kinds.isEmpty || pinnedOnly || sourceBundleID != nil || sourceName != nil || tag != nil
    }

    func matches(_ item: LauncherCatalogItem) -> Bool {
        guard item.kind == .clipboard else { return false }
        if !kinds.isEmpty {
            guard let kind = item.clipboardPayload?.kind, kinds.contains(kind) else { return false }
        }
        if pinnedOnly, !item.isPinned { return false }
        if let sourceBundleID {
            guard item.clipboardSource?.bundleIdentifier == sourceBundleID else { return false }
        }
        if let sourceName {
            let name = item.clipboardSource?.name ?? ""
            let bundleID = item.clipboardSource?.bundleIdentifier ?? ""
            guard name.compare(sourceName, options: .caseInsensitive) == .orderedSame
                || bundleID.compare(sourceName, options: .caseInsensitive) == .orderedSame
            else { return false }
        }
        if let tag {
            guard item.clipboardTags.contains(where: {
                $0.compare(tag, options: .caseInsensitive) == .orderedSame
            }) else { return false }
        }
        return true
    }
}

/// Query grammar for the clipboard catalog. `source:App`, `tag:App`,
/// `kind:image|text|rich|file|data`, and `pin:true` narrow the list; the rest
/// is the free-text search. The tokens are surfaced in the catalog's filter
/// hint, so the predicate is visible rather than hidden.
struct ClipboardFilterQuery: Equatable, Sendable {
    var source: String?
    var tag: String?
    var kinds: Set<ClipboardPayloadKind> = []
    var pinnedOnly = false
    var needle = ""

    static func parse(_ text: String) -> ClipboardFilterQuery {
        var query = ClipboardFilterQuery()
        var remaining: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let piece = String(token)
            guard let colon = piece.firstIndex(of: ":") else {
                remaining.append(piece)
                continue
            }
            let key = piece[..<colon].lowercased()
            let value = String(piece[piece.index(after: colon)...])
            guard !value.isEmpty else {
                remaining.append(piece)
                continue
            }
            switch key {
            case "source", "app", "from":
                query.source = value
            case "tag":
                query.tag = value
            case "kind", "type":
                if let kind = Self.kind(for: value) { query.kinds.insert(kind) }
            case "pin", "pinned":
                query.pinnedOnly = !["false", "0", "no"].contains(value.lowercased())
            default:
                remaining.append(piece)
            }
        }
        query.needle = remaining.joined(separator: " ")
        return query
    }

    private static func kind(for value: String) -> ClipboardPayloadKind? {
        switch value.lowercased() {
        case "image", "images", "img", "picture": .image
        case "text": .text
        case "rich", "richtext", "formatted": .richText
        case "file", "files": .fileURL
        case "data": .data
        default: nil
        }
    }
}
