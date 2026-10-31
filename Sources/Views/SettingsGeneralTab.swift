import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HouseDesign

// MARK: - General

struct GeneralTab: View {
    @Bindable var viewModel: QuickViewModel
    /// A failed Caffeinate assertion is surfaced here, beside the switch that
    /// asked for it, instead of being silently swallowed.
    @State private var caffeinateError: String?

    var body: some View {
        SettingsPaneScroller(pane: .general) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                hotkeysCard.settingsAnchor("general.hotkeys")
                behaviourCard.settingsAnchor("general.behaviour")
                caffeinateCard.settingsAnchor("general.caffeinate")
                // High in the pane: these are behaviour settings, and the
                // cards under them (Learning & Review especially) are long.
                QuickAISettingsView(viewModel: viewModel).settingsAnchor("general.quickAI")
                ChatSettingsView(viewModel: viewModel).settingsAnchor("general.chat")
                FallbackCommandsView(viewModel: viewModel).settingsAnchor("general.fallback")
                learningAndReviewCard.settingsAnchor("general.learning")
                HistorySettingsView(viewModel: viewModel).settingsAnchor("general.history")
                appearanceCard.settingsAnchor("general.appearance")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, SettingsMetrics.paneBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hotkeysCard: some View {
        SettingsCard("Hotkeys") {
            SettingsRow(title: "Open Quick Launch", isFirst: true) {
                HotkeyRecorderView(
                    keyCode: viewModel.settingsBinding(\.hotkeyKeyCode),
                    modifiers: viewModel.settingsBinding(\.hotkeyModifiers),
                    label: "Open Quick Launch",
                    showsLabel: false
                )
            }
            if let error = viewModel.hotkeyRegistrationError {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Quick AI") {
                ActionHotkeyRecorderView(
                    hotkey: viewModel.settingsBinding(
                        get: { $0.quickAIHotkeyEnabled ? $0.quickAIHotkey : nil },
                        set: { settings, value in
                            if let value {
                                settings.quickAIHotkey = value
                                settings.quickAIHotkeyEnabled = true
                            } else {
                                settings.quickAIHotkeyEnabled = false
                            }
                        },
                        onSet: { NotificationCenter.default.post(name: .quickAIHotkeyChanged, object: nil) }
                    ),
                    label: "Quick AI",
                    showsLabel: false,
                    changeNotification: .quickAIHotkeyChanged
                )
            }
            if let error = viewModel.settings.quickAIHotkeyConflict()
                ?? viewModel.quickAIHotkeyRegistrationError {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Open Translator") {
                ActionHotkeyRecorderView(
                    hotkey: viewModel.settingsBinding(
                        get: { $0.translatorHotkey as ActionHotkey? },
                        set: { settings, value in
                            settings.translatorHotkey = value
                                ?? ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
                        }
                    ),
                    label: "Open Translator",
                    showsLabel: false,
                    changeNotification: .translatorSettingsChanged
                )
            }
            if let error = viewModel.settings.translatorHotkeyConflict()
                ?? viewModel.translatorHotkeyRegistrationError {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Type to Click") {
                ActionHotkeyRecorderView(
                    hotkey: viewModel.settingsBinding(
                        get: { $0.typeToClickHotkeyEnabled ? $0.typeToClickHotkey : nil },
                        set: { settings, value in
                            if let value {
                                settings.typeToClickHotkey = value
                                settings.typeToClickHotkeyEnabled = true
                            } else {
                                settings.typeToClickHotkeyEnabled = false
                            }
                        }
                    ),
                    label: "Type to Click",
                    showsLabel: false,
                    changeNotification: .typeToClickSettingsChanged
                )
            }

            SettingsRow(title: "After Return") {
                Picker("After Return", selection: viewModel.settingsBinding(\.typeToClickContinuation) { _ in
                    NotificationCenter.default.post(name: .typeToClickSettingsChanged, object: nil)
                }) {
                    ForEach(TypeToClickContinuation.allCases, id: \.self) { continuation in
                        Text(continuation.displayName).tag(continuation)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            CardNote { CardText(typeToClickNote, tone: typeToClickNoteTone) }
        }
    }

    private var typeToClickNote: String {
        if let error = viewModel.settings.typeToClickHotkeyConflict()
            ?? viewModel.typeToClickHotkeyRegistrationError {
            return error
        }
        guard viewModel.settings.typeToClickHotkeyEnabled else {
            return "No direct hotkey. Type to Click remains available from Quick Launch."
        }
        return viewModel.settings.typeToClickContinuation == .continuous
            ? "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It pulses the choice, prioritizes an opened menu, and stays open for the next step; Esc or the shortcut closes it."
            : "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It acts once and closes; invoke Type to Click again for another action."
    }

    private var typeToClickNoteTone: Color {
        let conflict = viewModel.settings.typeToClickHotkeyConflict()
            ?? viewModel.typeToClickHotkeyRegistrationError
        return conflict == nil
            ? AQDesign.ColorToken.textSecondary
            : AQDesign.ColorToken.danger
    }

    private var behaviourCard: some View {
        SettingsCard("Behaviour") {
            SettingsRow(
                title: "Copy the first answer of each chat automatically",
                detail: "Not follow-ups or AI Chat. Clipboard History skips it.",
                isFirst: true
            ) {
                Toggle(
                    "Copy the first answer of each chat automatically",
                    isOn: viewModel.settingsBinding(\.autoCopy)
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Launch at login") {
                Toggle(
                    "Launch at login",
                    isOn: viewModel.settingsBinding(\.launchAtLogin) { _ in viewModel.applyLaunchAtLogin() }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Show menu bar icon") {
                Toggle("Show menu bar icon", isOn: viewModel.settingsBinding(\.showMenuBar))
                    .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Double-tap right \u{2318} sends the focused window to AI") {
                Toggle(
                    "Double-tap right \u{2318} sends the focused window to AI",
                    isOn: viewModel.settingsBinding(\.screenAwarenessDoubleTap) { _ in
                        NotificationCenter.default.post(name: .screenAwarenessSettingsChanged, object: nil)
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(
                title: "Attach a copied image when Quick Launch opens",
                detail: "Off: an image is attached only when you paste, drop or capture one."
            ) {
                Toggle(
                    "Attach a copied image when Quick Launch opens",
                    isOn: viewModel.settingsBinding(\.attachClipboardImageOnOpen) { isOn in
                        // Turning it on offers the next copy, not an old one.
                        if isOn { ClipboardImageReader.suppressAutoOffer() }
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Search text inside screenshots (on-device OCR)") {
                Toggle(
                    "Search text inside screenshots (on-device OCR)",
                    isOn: viewModel.settingsBinding(\.screenshotTextSearch)
                )
                .toggleStyle(InkToggleStyle())
            }
        }
    }

    /// Caffeinate's four preferences. These lived only in the launcher's
    /// Caffeinate catalog; the master switch, Agent Watch, the battery cutoff,
    /// and the display assertion now have a home here too, and every control
    /// writes both the stored setting and the running manager.
    private var caffeinateCard: some View {
        SettingsCard("Caffeinate") {
            SettingsRow(
                title: "Keep this Mac awake",
                detail: "Hold a sleep assertion until you turn it off. A timed session set from the launcher still shows below.",
                isFirst: true
            ) {
                Toggle(
                    "Keep this Mac awake",
                    isOn: Binding(
                        get: { viewModel.settings.caffeinateEnabled },
                        set: { enabled in
                            if viewModel.setCaffeinateEnabled(enabled) {
                                caffeinateError = nil
                            } else {
                                caffeinateError = "Could not turn Caffeinate \(enabled ? "on" : "off")."
                            }
                        }
                    )
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.enabled", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Agent Watch",
                detail: "Stay awake while Claude Code or Codex is working, then let the Mac sleep again."
            ) {
                Toggle(
                    "Agent Watch",
                    isOn: viewModel.settingsBinding(\.caffeinateAgentWatch) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.agentWatch", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Pause on battery at",
                detail: "On battery at or below this percent, sleep is allowed again. Off never pauses."
            ) {
                Picker(
                    "Pause on battery at",
                    selection: viewModel.settingsBinding(\.caffeinateBatteryCutoff) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                ) {
                    ForEach(batteryCutoffChoices, id: \.self) { percent in
                        Text(percent == 0 ? "Off" : "\(percent)%").tag(percent)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityLabel("Pause Caffeinate on battery at")
            }
            .settingsAnchor("general.caffeinate.battery", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Keep the display awake",
                detail: "Also prevent the display from idle-sleeping. Off, only the system stays awake."
            ) {
                Toggle(
                    "Keep the display awake",
                    isOn: viewModel.settingsBinding(\.caffeinateKeepDisplayAwake) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.display", radius: AQDesign.fieldCornerRadius)

            CardNote { CardText(caffeinateStatusText) }
            // A timed or Agent Watch session leaves the master switch off, so
            // its own cancel control lives here. A paused session is still in
            // force and is exactly the case this is for.
            if viewModel.hasCaffeinateSession, !viewModel.settings.caffeinateEnabled {
                CardNote {
                    Button("Decaffeinate", role: .destructive) {
                        _ = viewModel.setCaffeinateEnabled(false)
                    }
                }
            }
            if let caffeinateError {
                CardNote { CardText(caffeinateError, tone: AQDesign.ColorToken.danger) }
            }
        }
    }

    /// The presets, plus whatever is stored, so a value written by an older
    /// build (or a hand-edited plist) still renders and stays selectable.
    private var batteryCutoffChoices: [Int] {
        var choices = [0, 10, 20, 30, 50]
        let current = viewModel.settings.caffeinateBatteryCutoff
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
    }

    /// The manager's own policy line: it names the reason and reports a
    /// battery pause, which `isCaffeinating` alone cannot (the assertion is
    /// released while paused).
    private var caffeinateStatusText: String {
        viewModel.caffeinateStatusSummary
    }

    /// Ranking learning and the interaction journal sit together: they are the
    /// two halves of "how does Quick Launch learn from me, and what can I see
    /// and undo".
    private var learningAndReviewCard: some View {
        SettingsCard("Learning & Review") {
            SettingsRow(
                title: "Learn from my choices",
                detail: "Items you pick for a search rise to the top next time. Stored only on this Mac.",
                isFirst: true
            ) {
                Toggle(
                    "Learn from my choices",
                    isOn: viewModel.settingsBinding(\.launcherLearningEnabled)
                )
                .toggleStyle(InkToggleStyle())
            }
            CardNote {
                Button("Forget learned ranking", role: .destructive) {
                    viewModel.forgetLearnedRanking()
                }
            }

            SettingsRow(
                title: "Keep a local interaction journal",
                detail: "Records outcomes only — choices, abandoned searches, retries, and failures. No text, no content, no network. Turning it off stops new recording; events already kept stay on this Mac and keep ageing out until you clear them."
            ) {
                Toggle(
                    "Keep a local interaction journal",
                    isOn: viewModel.settingsBinding(\.interactionJournalEnabled) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            if !viewModel.settings.interactionJournalEnabled {
                CardNote {
                    CardText(
                        viewModel.interactionJournalEvents.isEmpty
                            ? "Recording is off. Nothing new is written."
                            : "Recording is off. The "
                                + "\(viewModel.interactionJournalEvents.count) saved event"
                                + "\(viewModel.interactionJournalEvents.count == 1 ? "" : "s") "
                                + "stay on this Mac and remain exportable and clearable, and "
                                + "still age out on the retention below."
                    )
                }
            }

            SettingsRow(title: "Keep journal events for") {
                Picker(
                    "Keep journal events for",
                    selection: viewModel.settingsBinding(\.interactionJournalRetentionDays) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                ) {
                    ForEach(retentionChoices, id: \.self) { days in
                        Text(Self.retentionTitle(days)).tag(days)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            SettingsRow(title: "Maximum journal events") {
                Picker(
                    "Maximum journal events",
                    selection: viewModel.settingsBinding(\.interactionJournalEventCap) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                ) {
                    ForEach(eventCapChoices, id: \.self) { cap in
                        Text(cap.formatted()).tag(cap)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            CardNote { CardText(journalStatusText) }

            journalReview

            CardNote {
                HStack(spacing: House.Spacing.sm) {
                    Menu("Export…") {
                        ForEach(InteractionJournalExportFormat.allCases) { format in
                            Button(format.title) { exportJournal(as: format) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(viewModel.interactionJournalEvents.isEmpty)
                    Button("Reveal in Finder") { viewModel.revealInteractionJournal() }
                    Button("Clear journal", role: .destructive) {
                        viewModel.clearInteractionJournal()
                    }
                    .disabled(viewModel.interactionJournalEvents.isEmpty)
                }
            }

            CardNote {
                CardText(
                    "Local only: the journal lives at "
                        + "~/Library/Application Support/Quick Launch/interaction-journal.json "
                        + "with owner-only permissions, and nothing is ever sent anywhere. "
                        + "Its query digest is keyed with a random key this Mac generated "
                        + "(interaction-journal-key, also owner-only and re-checked on "
                        + "every launch), so repeats correlate here and the digest cannot "
                        + "be recomputed without that file. "
                        + "It never stores clipboard, snippet, chat, selection, file, query, "
                        + "or AI answer text. Typed text is written only as that keyed "
                        + "digest plus a coarse size band — including a question you "
                        + "submit through the Ask AI row. That digest is one-way, not a "
                        + "secret store: a short query is still guessable by brute force "
                        + "if someone has the key file, so avoid typing secrets here. "
                        + "An identifier that could carry content, such as a typed web "
                        + "address or a window title, is replaced by a keyed digest too; "
                        + "for a typed web address the launcher's own row identity is a "
                        + "keyless content hash, which is stable but not cryptographic, "
                        + "so this journal re-keys it. "
                        + "Marked rows are review notes and never change ranking."
                )
            }
        }
    }

    /// Every clamped setting value must render and select. The documented range
    /// is far wider than the presets, so the current value is added when it is
    /// not already offered.
    private var retentionChoices: [Int] {
        InteractionJournalStore.retentionChoices(
            including: viewModel.settings.interactionJournalRetentionDays
        )
    }

    private var eventCapChoices: [Int] {
        InteractionJournalStore.eventCapChoices(
            including: viewModel.settings.interactionJournalEventCap
        )
    }

    private static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 7, 30, 90: "\(days) days"
        case 365: "1 year"
        case 1: "1 day"
        default: "\(days) days"
        }
    }

    private var journalStatusText: String {
        let events = viewModel.interactionJournalEvents
        guard let first = events.first else { return "No events recorded yet." }
        var text = "\(events.count) event\(events.count == 1 ? "" : "s") · "
        text += ByteCountFormatter.string(
            fromByteCount: Int64(viewModel.interactionJournalByteSize),
            countStyle: .file
        )
        text += " · last \(first.date.formatted(date: .abbreviated, time: .shortened))"
        let accidents = events.count { $0.markedAccidental }
        if accidents > 0 { text += " · \(accidents) marked accidental" }
        return text
    }

    /// The last few outcomes, each with the explicit, reversible "wrong choice"
    /// marker. Nothing here is inferred and nothing feeds ranking.
    private var journalReview: some View {
        let events = Array(viewModel.interactionJournalEvents.prefix(6))
        let revision = viewModel.interactionJournalRevision
        return Group {
            if !events.isEmpty {
                VStack(spacing: 0) {
                    HouseDivider()
                    ForEach(events) { event in
                        journalRow(event)
                    }
                }
                .id(revision)
            }
        }
    }

    private func journalRow(_ event: InteractionJournalEvent) -> some View {
        HStack(spacing: House.Spacing.sm) {
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(event.kind.shortTitle)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(journalDetail(event))
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: House.Spacing.sm)
            Button(event.markedAccidental ? "Unmark" : "Mark wrong") {
                viewModel.setInteractionMarkedAccidental(
                    id: event.id,
                    accidental: !event.markedAccidental
                )
            }
            .font(AQDesign.TypeToken.caption)
        }
        .frame(minHeight: 26)
    }

    private func journalDetail(_ event: InteractionJournalEvent) -> String {
        var parts: [String] = []
        if let itemID = event.itemID { parts.append(itemID) }
        if event.scope != LauncherUsageStore.rootScope { parts.append(event.scope) }
        if let detail = event.detail { parts.append(detail) }
        if let bucket = event.queryLengthBucket { parts.append("\(bucket) chars") }
        if event.markedAccidental { parts.append("marked accidental") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func exportJournal(as format: InteractionJournalExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Interaction Journal"
        panel.nameFieldStringValue = InteractionJournalExporter.suggestedFileName(for: format)
        switch format {
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .jsonLines:
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        }
        panel.canCreateDirectories = true
        let viewModel = viewModel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.writeInteractionJournal(as: format, to: url)
        }
    }

    private var appearanceCard: some View {
        SettingsCard("Appearance") {
            SettingsRow(title: "Appearance", isFirst: true) {
                InkSegmentedControl(
                    selection: viewModel.settingsBinding(\.appearance),
                    options: AppearancePreference.allCases.map {
                        InkSegment(value: $0, title: $0.displayName)
                    }
                )
                .frame(maxWidth: 300)
            }
        }
    }
}
