import Foundation

/// The Translator's ⌘K list: its actions, and Translation History (the
/// translations it has committed, newest first), each a searchable list in
/// the window, like the language lists.
enum TranslatorList: Equatable, Sendable {
    case actions
    case history
}

/// One row of the ⌘K action list.
struct TranslatorAction: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case history
        case key(TranslatorKey)
    }

    let kind: Kind
    let title: String
    let symbol: String
    let keyCaps: [String]

    var id: String { title }

    static let all: [TranslatorAction] = [
        TranslatorAction(kind: .history, title: "Translation History", symbol: "clock.arrow.circlepath", keyCaps: []),
        TranslatorAction(kind: .key(.copy), title: "Copy Translation", symbol: "doc.on.doc", keyCaps: TranslatorKey.copy.shortcut.keyCaps),
        TranslatorAction(kind: .key(.pasteBack), title: "Paste Back", symbol: "arrow.uturn.left", keyCaps: TranslatorKey.pasteBack.shortcut.keyCaps),
        TranslatorAction(kind: .key(.swap), title: "Swap Languages", symbol: "arrow.left.arrow.right", keyCaps: TranslatorKey.swap.shortcut.keyCaps),
        TranslatorAction(kind: .key(.source), title: "Source Language", symbol: "globe", keyCaps: TranslatorKey.source.shortcut.keyCaps),
        TranslatorAction(kind: .key(.target), title: "Target Language", symbol: "globe", keyCaps: TranslatorKey.target.shortcut.keyCaps),
        TranslatorAction(kind: .key(.useClipboard), title: "Use Clipboard as Source", symbol: "clipboard", keyCaps: TranslatorKey.useClipboard.shortcut.keyCaps),
    ]
}

extension TranslationRecord: Identifiable {}

extension TranslatorModel {
    /// How many history rows the list shows before a search narrows it.
    nonisolated static let historyShown = 50

    /// ⌘K: opens the action list, or closes whichever list is open.
    func toggleActionList() {
        if list != nil {
            list = nil
        } else {
            languagePicker = nil
            list = .actions
        }
        listQuery = ""
        if list == nil { requestSourceFocus() }
    }

    /// Opens Translation History straight away, reading the file fresh.
    func openHistory() {
        languagePicker = nil
        history = historyLoader()
        list = .history
        listQuery = ""
    }

    /// The action rows, narrowed by the list's search field.
    var actionOptions: [TranslatorAction] {
        let query = listQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return TranslatorAction.all }
        return TranslatorAction.all.filter { FuzzyMatcher.score(query: query, candidate: $0.title) != nil }
    }

    /// The newest translations, or every one whose source or translation
    /// holds each typed word (case and accents ignored).
    var historyOptions: [TranslationRecord] {
        let words = FuzzyMatcher.fold(listQuery).split(separator: " ")
        guard !words.isEmpty else { return Array(history.prefix(Self.historyShown)) }
        return history.filter { record in
            let text = FuzzyMatcher.fold(record.source + " " + record.translation)
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Return on an action row. History opens its list; a key runs as its
    /// shortcut would, through the app (`performKey`).
    func chooseAction(_ action: TranslatorAction) {
        switch action.kind {
        case .history:
            openHistory()
        case .key(let key):
            list = nil
            listQuery = ""
            performKey?(key)
        }
    }

    /// Return on a history row: the old translation back in the window, as
    /// it was, without asking the model again. ⌘↩ then copies it.
    func reopen(_ record: TranslationRecord) {
        list = nil
        listQuery = ""
        loadRecord(record)
        message = "From history"
        requestSourceFocus()
    }

    var listFooterContext: String? {
        switch list {
        case .actions: "Actions"
        case .history: "Translation History · \(history.count)"
        case nil: nil
        }
    }
}
