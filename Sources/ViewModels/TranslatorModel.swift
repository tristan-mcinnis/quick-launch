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
    nonisolated static let debounce: Duration = .milliseconds(260)
    nonisolated static let historyLimit = 500

    var source = ""
    var translation = ""
    var pinyin: String?
    var target: TranslationTarget
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
    @ObservationIgnored private var lastTranslatedSource = ""

    init(
        lastTarget: TranslationTarget = .simplifiedChinese,
        serviceFactory: @escaping () -> (any QuickService)? = { nil },
        selectedTextService: (any SelectedTextServicing)? = nil
    ) {
        self.target = lastTarget
        self.serviceFactory = serviceFactory
        self.selectedTextService = selectedTextService
    }

    /// Open: remember the app behind the window and start from its selection.
    func prepare(target selectionTarget: SelectionTarget?, selectedText: String?) {
        pasteTarget = selectionTarget
        knownSourceOfSwappedText = nil
        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = selectedText
            chooseTargetAutomatically()
            translateNow()
        }
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
        detectedSource = LanguageDetection.recognize(source)
        chooseTargetAutomatically()
        debounceTask?.cancel()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            requestTask?.cancel()
            translation = ""
            pinyin = nil
            isTranslating = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? TranslatorModel.debounce)
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    private func chooseTargetAutomatically() {
        let preferred = target.isChinese || target == .english ? target : target
        let next = LanguageDetection.target(for: source, lastTarget: preferred)
        if next != target {
            target = next
        }
    }

    func setTarget(_ newTarget: TranslationTarget) {
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
        let previousTranslation = translation
        let sourceLanguage = knownSourceOfSwappedText ?? detectedSource ?? (target == .english ? .simplifiedChinese : .english)
        let newTarget = sourceLanguage == target ? .english : sourceLanguage
        if previousTranslation.isEmpty {
            target = newTarget
            message = "Direction flipped"
            return
        }
        knownSourceOfSwappedText = target
        source = previousTranslation
        translation = previousSource
        pinyin = target.isChinese ? nil : Pinyin.romanize(previousSource)
        detectedSource = target
        target = newTarget
        onTargetChange?(newTarget)
        message = "Languages swapped"
    }

    func clear() {
        debounceTask?.cancel()
        requestTask?.cancel()
        source = ""
        translation = ""
        pinyin = nil
        detectedSource = nil
        isTranslating = false
        message = "Cleared"
    }

    func useClipboardAsSource() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
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
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let service = serviceFactory() else {
            message = "Choose a model in Settings › Models"
            return
        }
        requestTask?.cancel()
        isTranslating = true
        lastTranslatedSource = text
        let prompt = Self.prompt(for: text, target: target)
        requestTask = Task { [weak self] in
            var collected = ""
            do {
                for try await delta in service.send(messages: [QuickMessage(role: .user, content: prompt)]) {
                    if Task.isCancelled { return }
                    if let piece = delta.text { collected += piece }
                    self?.translation = collected
                }
                guard let self, !Task.isCancelled else { return }
                self.translation = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pinyin = self.target.isChinese ? Pinyin.romanize(self.translation) : nil
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
        if isTranslating {
            pendingCommit = .copy
            message = "Copying when ready…"
            return
        }
        guard !translation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
        record()
        message = "Copied translation"
    }

    func copySource() {
        guard !source.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        message = "Copied source text"
    }

    /// ⌘⇧↩: paste the translation into the app that was behind the window.
    @discardableResult
    func pasteBack() async -> Bool {
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(translation, forType: .string)
            message = "Could not paste into \(pasteTarget.applicationName). Copied instead."
            return false
        }
        return true
    }

    private func record() {
        onCommit?(TranslationRecord(source: source, translation: translation, target: target.code))
    }
}

/// Committed translations only, newest first, bounded. Local JSON, 0600.
enum TranslationHistoryStore {
    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quick Launch/translation-history.json")
    }

    static func load(from url: URL) -> [TranslationRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([TranslationRecord].self, from: data)
        else { return [] }
        return records
    }

    static func append(_ record: TranslationRecord, to url: URL, limit: Int = TranslatorModel.historyLimit) {
        var records = load(from: url)
        records.insert(record, at: 0)
        records = Array(records.prefix(limit))
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
