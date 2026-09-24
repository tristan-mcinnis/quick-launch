import AppKit
import Foundation
import NaturalLanguage
import Observation

/// A target language for the Translator window.
struct TranslationTarget: Equatable, Hashable, Sendable, Identifiable {
    let code: String
    let title: String
    var id: String { code }

    static let english = TranslationTarget(code: "en", title: "English")
    static let simplifiedChinese = TranslationTarget(code: "zh-Hans", title: "Chinese (Simplified)")
    static let traditionalChinese = TranslationTarget(code: "zh-Hant", title: "Chinese (Traditional)")
    static let japanese = TranslationTarget(code: "ja", title: "Japanese")
    static let french = TranslationTarget(code: "fr", title: "French")
    static let spanish = TranslationTarget(code: "es", title: "Spanish")
    static let german = TranslationTarget(code: "de", title: "German")

    /// Favourites first, the way the Companion ordered them.
    static let all: [TranslationTarget] = [
        english, simplifiedChinese, traditionalChinese, japanese,
        TranslationTarget(code: "ko", title: "Korean"),
        french, spanish, german,
        TranslationTarget(code: "it", title: "Italian"),
        TranslationTarget(code: "pt", title: "Portuguese"),
        TranslationTarget(code: "nl", title: "Dutch"),
        TranslationTarget(code: "ru", title: "Russian"),
        TranslationTarget(code: "ar", title: "Arabic"),
        TranslationTarget(code: "hi", title: "Hindi"),
        TranslationTarget(code: "th", title: "Thai"),
        TranslationTarget(code: "vi", title: "Vietnamese"),
        TranslationTarget(code: "id", title: "Indonesian"),
        TranslationTarget(code: "ms", title: "Malay"),
        TranslationTarget(code: "tr", title: "Turkish"),
        TranslationTarget(code: "pl", title: "Polish"),
        TranslationTarget(code: "sv", title: "Swedish"),
    ]

    static func named(_ code: String) -> TranslationTarget? {
        all.first { $0.code == code }
    }

    var isChinese: Bool { code.hasPrefix("zh") }

    /// What a language recogniser reports, mapped to a target.
    static func fromRecognized(_ language: NLLanguage?) -> TranslationTarget? {
        guard let language else { return nil }
        switch language {
        case .simplifiedChinese: return simplifiedChinese
        case .traditionalChinese: return traditionalChinese
        default: return all.first { $0.code == language.rawValue }
        }
    }
}

/// Source-language detection and the Companion's direction rule.
enum LanguageDetection {
    /// More than 15% CJK scalars means the text is Chinese (or Japanese/Korean).
    static func cjkRatio(_ text: String) -> Double {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                cjk += 1
                letters += 1
            default:
                if scalar.properties.isAlphabetic { letters += 1 }
            }
        }
        guard letters > 0 else { return 0 }
        return Double(cjk) / Double(letters)
    }

    static func recognize(_ text: String) -> TranslationTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(trimmed.prefix(600)))
        return TranslationTarget.fromRecognized(recognizer.dominantLanguage)
    }

    @concurrent
    static func recognizeForTranslation(_ text: String) async -> TranslationTarget? {
        recognize(text)
    }

    /// Where the text should go: CJK text goes to English, everything else
    /// to `lastTarget` (Chinese by default). If the recognised source is the
    /// same as `lastTarget`, English is used instead.
    static func target(for text: String, lastTarget: TranslationTarget) -> TranslationTarget {
        if cjkRatio(text) > 0.15 {
            return lastTarget.isChinese || lastTarget == .english ? .english : lastTarget
        }
        if let source = recognize(text), source == lastTarget { return .english }
        return lastTarget
    }
}

/// Pinyin for Simplified Chinese translations, display only.
enum Pinyin {
    @concurrent
    static func romanizeForDisplay(_ text: String) async -> String? {
        romanize(text)
    }

    static func romanize(_ text: String) -> String? {
        guard LanguageDetection.cjkRatio(text) > 0.15 else { return nil }
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) else { return nil }
        return mutable as String
    }
}

struct TranslationRecord: Codable, Equatable, Sendable {
    var id = UUID()
    var translatedAt = Date()
    var source: String
    var translation: String
    var target: String
}

/// The Translator window: source above, translation below, retranslating as
/// you type. Mirrors the Tuna Companion translator on Quick Launch's
/// primitives: the same model call, the same keys, no extra process.
@Observable
@MainActor
final class TranslatorModel {
    nonisolated static let debounce: Duration = .milliseconds(600)
    nonisolated static let historyLimit = 500

    var source = ""
    var translation = ""
    var pinyin: String?
    var target: TranslationTarget
    var sourceLanguage: TranslationTarget
    var sourceFocusRevision = 0
    private(set) var isWaitingForTranslation = false

    /// Only editor writes schedule a translation; imports and swaps manage their own work.
    var sourceInput: String {
        get { source }
        set {
            source = newValue
            sourceChanged()
        }
    }
    var detectedSource: TranslationTarget?
    var isTranslating = false
    var message: String?
    var isTargetPickerPresented = false
    var targetQuery = ""
    var pendingCommit: Commit?

    enum Commit: Equatable { case copy, paste }

    @ObservationIgnored var serviceFactory: () -> (any QuickService)?
    @ObservationIgnored var selectedTextService: (any SelectedTextServicing)?
    @ObservationIgnored var onTargetChange: ((TranslationTarget) -> Void)?
    @ObservationIgnored var onCommit: ((TranslationRecord) -> Void)?
    @ObservationIgnored var debounce: Duration = TranslatorModel.debounce
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pasteTarget: SelectionTarget?
    /// Set by Swap: the language of the swapped-in text is known, not guessed.
    @ObservationIgnored private var knownSourceOfSwappedText: TranslationTarget?
    /// The launch-time selected text, retained so "Use selected text" can fill
    /// the source even after the original app lost focus. Never auto-applied
    /// after the window is open — that would erase a manually typed source.
    @ObservationIgnored private var retainedSelection: String?

    /// Whether a retained launch selection is available to the "Use selected
    /// text" button.
    var hasRetainedSelection: Bool {
        !(retainedSelection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        lastTarget: TranslationTarget = .simplifiedChinese,
        lastSource: TranslationTarget? = nil,
        serviceFactory: @escaping () -> (any QuickService)? = { nil },
        selectedTextService: (any SelectedTextServicing)? = nil,
        pasteboard: (any PasteboardWriting)? = nil
    ) {
        self.target = lastTarget
        let rememberedSource = lastSource ?? (lastTarget == .english ? .simplifiedChinese : .english)
        self.sourceLanguage = rememberedSource == lastTarget
            ? (lastTarget == .english ? .simplifiedChinese : .english)
            : rememberedSource
        self.serviceFactory = serviceFactory
        self.selectedTextService = selectedTextService
        // In memory unless the app passes the system pasteboard, so a test
        // never reads or overwrites the user's clipboard.
        self.pasteboard = pasteboard ?? InMemoryPasteboard()
    }

    /// Where Copy writes and Paste reads. The app passes its system pasteboard.
    @ObservationIgnored private let pasteboard: any PasteboardWriting

    /// Open: remember the app behind the window and start from its selection.
    /// `retainedSelection` is the Quick Launch launch snapshot, kept so the
    /// user can re-import it with "Use selected text" after focus moves on.
    func prepare(
        target selectionTarget: SelectionTarget?,
        selectedText: String?,
        retainedSelection: String? = nil
    ) {
        clear()
        message = nil
        isTargetPickerPresented = false
        targetQuery = ""
        requestSourceFocus()
        pasteTarget = selectionTarget
        knownSourceOfSwappedText = nil
        self.retainedSelection = retainedSelection
        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = selectedText
            translateNow()
        }
    }

    /// Explicit "Use selected text": import the retained launch snapshot as the
    /// source. Only ever triggered by the button; never erases manual typing.
    func useRetainedSelection() {
        guard let text = retainedSelection,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        source = text
        sourceChanged()
        message = "Using selected text"
    }

    /// A handoff from the launcher's Translate transform: import the retained
    /// selection as the source and keep it for "Use selected text". Called when
    /// the window is already open, so a chip Translate fronts it and translates
    /// the selected text rather than toggling the window shut.
    func retainLaunchSelection(_ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelTranslation()
        knownSourceOfSwappedText = nil
        retainedSelection = text
        source = text
        translation = ""
        pinyin = nil
        isTargetPickerPresented = false
        requestSourceFocus()
        translateNow()
    }

    var filteredTargets: [TranslationTarget] {
        let query = targetQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return TranslationTarget.all }
        return TranslationTarget.all.filter { FuzzyMatcher.score(query: query, candidate: $0.title) != nil }
    }

    // MARK: Typing

    /// Called on every keystroke in the source pane.
    func sourceChanged() {
        knownSourceOfSwappedText = nil
        cancelTranslation()
        translation = ""
        pinyin = nil
        detectedSource = nil
        message = nil
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWaitingForTranslation = true
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? TranslatorModel.debounce)
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    /// Returns once the typing pause and the request it started are over:
    /// what a caller (or a test) waits on instead of the clock.
    func settled() async {
        while true {
            if let debounceTask {
                await debounceTask.value
                // A debounce that ran started a request; one that was
                // replaced left a newer debounce in its place.
                if self.debounceTask == debounceTask { self.debounceTask = nil }
                continue
            }
            if let requestTask {
                await requestTask.value
                if self.requestTask == requestTask { self.requestTask = nil }
                continue
            }
            return
        }
    }

    func requestSourceFocus() {
        sourceFocusRevision += 1
    }

    private func cancelTranslation() {
        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        requestTask = nil
        isTranslating = false
        isWaitingForTranslation = false
        pendingCommit = nil
    }

    func setTarget(_ newTarget: TranslationTarget) {
        cancelTranslation()
        translation = ""
        pinyin = nil
        if sourceLanguage == newTarget {
            sourceLanguage = target == newTarget
                ? (newTarget == .english ? .simplifiedChinese : .english)
                : target
        }
        target = newTarget
        isTargetPickerPresented = false
        targetQuery = ""
        onTargetChange?(newTarget)
        message = "Target: \(newTarget.title)"
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translateNow() }
    }

    /// The translation becomes the source and the target flips to the
    /// language the text was actually in, so repeated swaps round-trip.
    func swap() {
        let previousSource = source
        let previousTranslation = isTranslating || isWaitingForTranslation ? "" : translation
        let previousTarget = target
        let recognized = knownSourceOfSwappedText ?? detectedSource
        let newTarget = recognized.flatMap { $0 == target ? nil : $0 } ?? sourceLanguage
        cancelTranslation()
        sourceLanguage = previousTarget
        target = newTarget
        let hasCompletedTranslation = !previousTranslation.isEmpty
        knownSourceOfSwappedText = hasCompletedTranslation ? previousTarget : nil
        // A quick swap during debounce or streaming must never erase what was
        // typed. Only a complete result can replace the source for a round trip.
        source = hasCompletedTranslation ? previousTranslation : previousSource
        translation = hasCompletedTranslation ? previousSource : ""
        pinyin = target.isChinese ? Pinyin.romanize(translation) : nil
        detectedSource = hasCompletedTranslation ? previousTarget : nil
        onTargetChange?(newTarget)
        isTargetPickerPresented = false
        requestSourceFocus()
        message = hasCompletedTranslation ? "Languages swapped" : "Direction flipped"
        if !hasCompletedTranslation, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translateNow()
        }
    }

    func clear() {
        cancelTranslation()
        knownSourceOfSwappedText = nil
        source = ""
        translation = ""
        pinyin = nil
        detectedSource = nil
        isTranslating = false
        message = "Cleared"
    }

    func useClipboardAsSource() {
        guard let text = pasteboard.readString(), !text.isEmpty else {
            message = "The clipboard has no text"
            return
        }
        source = text
        sourceChanged()
        message = "Using clipboard text"
    }

    // MARK: Translating

    func translateNow() {
        debounceTask?.cancel()
        isWaitingForTranslation = false
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let service = serviceFactory() else {
            message = "Choose a model in Settings › Models"
            return
        }
        requestTask?.cancel()
        isTranslating = true
        let requestTarget = target
        let knownSource = knownSourceOfSwappedText
        let prompt = Self.prompt(for: text, target: requestTarget)
        requestTask = Task { [weak self] in
            let detected = await LanguageDetection.recognizeForTranslation(text)
            guard !Task.isCancelled else { return }
            self?.detectedSource = knownSource ?? detected
            if let detectedSource = self?.detectedSource, detectedSource != requestTarget {
                self?.sourceLanguage = detectedSource
                self?.onTargetChange?(requestTarget)
            }
            var collected = ""
            do {
                for try await delta in service.send(messages: [QuickMessage(role: .user, content: prompt)]) {
                    if Task.isCancelled { return }
                    if let piece = delta.text { collected += piece }
                    self?.translation = collected
                }
                guard let self, !Task.isCancelled else { return }
                self.translation = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                let romanized = requestTarget.isChinese
                    ? await Pinyin.romanizeForDisplay(self.translation) : nil
                guard !Task.isCancelled else { return }
                self.pinyin = romanized
                self.isTranslating = false
                if let pending = self.pendingCommit {
                    self.pendingCommit = nil
                    switch pending {
                    case .copy: self.copyTranslation()
                    case .paste: await self.pasteBack()
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isTranslating = false
                self.pendingCommit = nil
                self.message = error.localizedDescription
            }
        }
    }

    static func prompt(for text: String, target: TranslationTarget) -> String {
        "Translate the following text to \(target.title). Keep the meaning, tone, names, numbers, and paragraph breaks. Return only the translation, no preamble.\n\n\(text)"
    }

    // MARK: Committing

    /// ⌘↩: copy the translation. If one is still arriving, copy when it lands.
    func copyTranslation() {
        if isWaitingForTranslation { translateNow() }
        if isTranslating {
            pendingCommit = .copy
            message = "Copying when ready…"
            return
        }
        guard !translation.isEmpty else { return }
        pasteboard.writeString(translation)
        record()
        message = "Copied translation"
    }

    func copySource() {
        guard !source.isEmpty else { return }
        pasteboard.writeString(source)
        message = "Copied source text"
    }

    /// ⌘⇧↩: paste the translation into the app that was behind the window.
    @discardableResult
    func pasteBack() async -> Bool {
        if isWaitingForTranslation { translateNow() }
        if isTranslating {
            pendingCommit = .paste
            message = "Pasting when ready…"
            return false
        }
        guard !translation.isEmpty else { return false }
        guard let pasteTarget, let selectedTextService else {
            copyTranslation()
            message = "No app behind the translator. Copied instead."
            return false
        }
        record()
        guard await selectedTextService.paste(translation, to: pasteTarget) else {
            pasteboard.writeString(translation)
            message = "Could not paste into \(pasteTarget.applicationName). Copied instead."
            return false
        }
        return true
    }

    private func record() {
        onCommit?(TranslationRecord(source: source, translation: translation, target: target.code))
    }
}
