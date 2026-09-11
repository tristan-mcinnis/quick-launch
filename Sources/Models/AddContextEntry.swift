import Foundation

/// One row of the Add Context menu, the same list behind the control left of
/// the composer and behind typing `@` in it. Every entry reuses a capture
/// path the overlay already had; nothing here captures by itself.
enum AddContextEntry: String, CaseIterable, Identifiable, Sendable {
    case focusedWindow
    case selectedText
    case selectedArea
    case entireScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusedWindow: "Focused Window"
        case .selectedText: "Selected Text"
        case .selectedArea: "Selected Area"
        case .entireScreen: "Entire Screen"
        }
    }

    /// What the entry attaches, in the reader's words.
    var detail: String {
        switch self {
        case .focusedWindow: "The front window of the app you were in, as an image"
        case .selectedText: "The text selected in the app you were in"
        case .selectedArea: "Draw a rectangle over the screen"
        case .entireScreen: "Every display, as one image"
        }
    }

    /// Reads the app that was in front before Quick Launch. The AI Chat
    /// window leaves these out while it knows no such app.
    var needsPreviousApp: Bool {
        self == .focusedWindow || self == .selectedText
    }

    var systemImage: String {
        switch self {
        case .focusedWindow: "macwindow"
        case .selectedText: "text.cursor"
        case .selectedArea: "rectangle.dashed"
        case .entireScreen: "display"
        }
    }
}

/// One row of the Add Context menu once files and links can be attached:
/// the four captures, then File…, Link…, and Finder Selection. The same
/// list sits behind the plus circle and behind `@`, in Quick AI and in AI
/// Chat. Each row names what it attaches; the attaching itself is the
/// tray's (`AttachmentTray`) and its owner's.
enum AddContextRow: Hashable, Identifiable, Sendable {
    case capture(AddContextEntry)
    /// An open panel for one or more files.
    case file
    /// A one-line field in the same pane for a web link.
    case link
    /// The files selected in the Finder window behind the overlay.
    case finderSelection

    /// Finder's bundle identifier: Finder Selection is listed only when the
    /// app behind the overlay is Finder.
    static let finderBundleIdentifier = "com.apple.finder"

    /// The menu in order: the four captures, File…, Link…, and Finder
    /// Selection when Finder is the app behind the overlay.
    static func menu(finderIsBehind: Bool) -> [AddContextRow] {
        var rows = AddContextEntry.allCases.map(AddContextRow.capture)
        rows.append(.file)
        rows.append(.link)
        if finderIsBehind { rows.append(.finderSelection) }
        return rows
    }

    /// The menu with the captures the surface offers (the AI Chat window
    /// drops the two that need an app behind it while it knows none), then
    /// File…, Link…, and Finder Selection when Finder is behind.
    static func menu(captures: [AddContextEntry], finderIsBehind: Bool) -> [AddContextRow] {
        var rows = captures.map(AddContextRow.capture)
        rows.append(.file)
        rows.append(.link)
        if finderIsBehind { rows.append(.finderSelection) }
        return rows
    }

    /// The menu for the app behind the overlay, by its bundle identifier.
    static func menu(appBehind bundleIdentifier: String?) -> [AddContextRow] {
        menu(finderIsBehind: bundleIdentifier == finderBundleIdentifier)
    }

    var id: String {
        switch self {
        case .capture(let entry): entry.id
        case .file: "file"
        case .link: "link"
        case .finderSelection: "finderSelection"
        }
    }

    var title: String {
        switch self {
        case .capture(let entry): entry.title
        case .file: "File…"
        case .link: "Link…"
        case .finderSelection: "Finder Selection"
        }
    }

    var detail: String {
        switch self {
        case .capture(let entry): entry.detail
        case .file: "PDF, Word, PowerPoint, Excel, text, or an image"
        case .link: "A web page, read once"
        case .finderSelection: "The files selected in Finder"
        }
    }

    var systemImage: String {
        switch self {
        case .capture(let entry): entry.systemImage
        case .file: "doc.badge.plus"
        case .link: "link"
        case .finderSelection: "folder"
        }
    }

    /// The capture this row runs, when it is one of the four.
    var capture: AddContextEntry? {
        if case .capture(let entry) = self { return entry }
        return nil
    }
}
