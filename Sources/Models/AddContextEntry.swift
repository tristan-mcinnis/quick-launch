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
