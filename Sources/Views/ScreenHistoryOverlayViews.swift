import SwiftUI

/// Screen History's overlay surfaces: the catalog row, the empty state, the
/// Save to Vault form, and the layout constants the core sizing asks for.
/// `OverlayView` only calls into these; it holds no Screen History logic.

/// Layout budget for the Save to Vault form.
enum ScreenHistorySaveLayout {
    /// Keeps the exact payload preview and its primary action visible. The
    /// payload body scrolls within this fixed production budget.
    static let minimumWindowHeight: CGFloat = 620
}

/// The two-line row a screen moment gets in the launcher list. `nil` for
/// every other result, so the caller stays a single `if let`.
struct ScreenHistoryResultRow: View {
    let item: LauncherCatalogItem
    let isSelected: Bool
    let position: Int?
    let total: Int?
    let primaryAction: String

    init?(
        result: LauncherSearchResult,
        isSelected: Bool,
        position: Int?,
        total: Int?,
        primaryAction: String
    ) {
        guard case .item(let item) = result, item.kind == .screenHistory else { return nil }
        self.item = item
        self.isSelected = isSelected
        self.position = position
        self.total = total
        self.primaryAction = primaryAction
    }

    static func isScreenHistory(_ result: LauncherSearchResult) -> Bool {
        guard case .item(let item) = result else { return false }
        return item.kind == .screenHistory
    }

    var accessibilityValue: String {
        ScreenHistoryAccessibilityPresentation.rowValue(
            isSelected: isSelected,
            position: position,
            total: total,
            primaryAction: primaryAction
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

/// Screen History rows grow with Dynamic Type; every other row stays 42pt.
struct ScreenHistoryRowFrame: ViewModifier {
    let result: LauncherSearchResult
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 58

    func body(content: Content) -> some View {
        let isScreenHistory = ScreenHistoryResultRow.isScreenHistory(result)
        content.frame(
            minHeight: isScreenHistory ? rowMinHeight : 42,
            maxHeight: isScreenHistory ? nil : 42
        )
    }
}

/// The footer needs a taller minimum in the Screen History catalog so its
/// longer context line survives accessibility text sizes.
struct ScreenHistoryFooterFrame: ViewModifier {
    let isActive: Bool
    let defaultMinHeight: CGFloat
    @ScaledMetric(relativeTo: .caption) private var footerMinHeight: CGFloat = 34

    func body(content: Content) -> some View {
        content.frame(minHeight: isActive ? footerMinHeight : defaultMinHeight)
    }
}

struct ScreenHistoryEmptyState: View {
    @Bindable var viewModel: QuickViewModel
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 96

    var body: some View {
        let presentation = ScreenHistoryEmptyPresentation(
            state: viewModel.screenHistory.loadState,
            query: viewModel.input
        )
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.icon)
                .font(AQDesign.TypeToken.glyph.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if presentation.offersClearFilters {
                    Button("Clear filters") {
                        viewModel.input = ""
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(minHeight: minimumHeight)
        .accessibilityElement(children: .combine)
    }
}

struct ScreenHistoryEmptyPresentation: Equatable, Sendable {
    let icon: String
    let title: String
    let detail: String
    let offersClearFilters: Bool

    init(state: ScreenHistoryLoadState, query: String) {
        let filterDecision = ScreenHistoryQueryParser.parse(query)
        if case .search(let parsed) = filterDecision {
            offersClearFilters = parsed.hasFilters
        } else {
            offersClearFilters = false
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        icon = switch state {
        case .loading: "hourglass"
        case .failed, .unavailable: "exclamationmark.circle"
        case .refusedFuture, .routedToVaultSearch: "arrow.triangle.branch"
        default: "clock.arrow.circlepath"
        }
        title = switch state {
        case .loading: "Searching screen history…"
        case .unavailable: "Screen History is unavailable on this Mac."
        case .failed(let message): message
        case .refusedFuture: "Future screen activity cannot be known."
        case .routedToVaultSearch: "Use Vault Search for current project status."
        case .ready:
            cleanQuery.isEmpty ? "No screen history yet" : "No screen history for “\(String(cleanQuery.prefix(120)))”"
        case .idle: "Open Screen History to search this Mac."
        }
        detail = switch state {
        case .loading: "Search stays on this Mac."
        case .unavailable: "Enable legacy search or create the owned local store in Settings."
        case .failed: "No web, model, Vault Search, or VPS fallback was used."
        case .refusedFuture: "Screen History only reports what was visible in the past."
        case .routedToVaultSearch: "Screen History records visibility. Vault Search reports current work state."
        case .ready:
            offersClearFilters
                ? "Try different words or clear the filters."
                : "Try different words."
        case .idle: ""
        }
    }
}

struct ScreenHistorySavePreview: Equatable, Sendable {
    let source: String
    let localRecordID: String
    let seenAt: String
    let application: String
    let window: String
    let ocrExcerpt: String
    let validationError: String?

    init(frame: ScreenHistoryFrame) {
        source = frame.source == .owned ? "Owned" : "Coast"
        localRecordID = frame.sourceIdentifier
        seenAt = ScreenHistoryVaultSaveService.formattedTimestamp(frame.capturedAt)
        application = frame.application.map {
            String($0.prefix(ScreenHistoryVaultSaveService.maximumApplicationCharacters))
        } ?? "Not included"
        window = frame.windowTitle.map {
            String($0.prefix(ScreenHistoryVaultSaveService.maximumWindowTitleCharacters))
        } ?? "Not included"
        let boundedOCR = String(
            frame.ocrText.prefix(ScreenHistoryVaultSaveService.maximumOCRExcerptCharacters)
        )
        ocrExcerpt = boundedOCR
        let cleanRecordID = frame.sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        validationError = cleanRecordID.isEmpty
            || cleanRecordID.count > ScreenHistoryVaultSaveService.maximumRecordIDCharacters
            ? "This local record ID cannot be saved."
            : nil
    }
}

enum ScreenHistoryAccessibilityPresentation {
    static let informationGroupName = "Information"

    static func rowValue(
        isSelected: Bool,
        position: Int?,
        total: Int?,
        primaryAction: String
    ) -> String {
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        if let position, let total { parts.append("\(position) of \(total)") }
        if isSelected { parts.append("\(primaryAction) with Return") }
        return parts.joined(separator: ", ")
    }

    static func actionValue(isSelected: Bool, position: Int, total: Int) -> String {
        "\(isSelected ? "Selected, " : "")\(position) of \(total)"
    }
}

/// The ⌘K "Save to Vault" form: an exact preview of the payload plus an
/// optional project slug and note.
struct ScreenHistorySaveForm: View {
    @Bindable var viewModel: QuickViewModel
    let result: LauncherSearchResult
    let formFocused: FocusState<Bool>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var projectSlug = ""
    @State private var note = ""

    private var textScale: CGFloat {
        switch dynamicTypeSize {
        case .accessibility1: 1.35
        case .accessibility2: 1.6
        case .accessibility3: 2
        case .accessibility4: 2.25
        case .accessibility5: 2.5
        default: 1
        }
    }

    var body: some View {
        if case .item(let item) = result,
           let frame = viewModel.screenHistory.frame(for: item) {
            let preview = ScreenHistorySavePreview(frame: frame)
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent("Source", value: preview.source)
                            LabeledContent("Local record ID", value: preview.localRecordID)
                            LabeledContent("Seen at", value: preview.seenAt)
                            LabeledContent("Application", value: preview.application)
                            LabeledContent("Window", value: preview.window)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("OCR excerpt saved to Vault")
                                    .font(AQDesign.TypeToken.scaledHint(textScale, weight: .semibold))
                                Text(preview.ocrExcerpt.isEmpty ? "Empty" : preview.ocrExcerpt)
                                    .font(AQDesign.TypeToken.scaledHint(textScale))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(AQDesign.ColorToken.keyCapFill)
                                    )
                            }
                        }
                        .font(AQDesign.TypeToken.scaledBody(textScale))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Screen moment preview")

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Project slug")
                                .font(AQDesign.TypeToken.scaledHint(textScale))
                                .foregroundStyle(.secondary)
                            TextField("Optional, for example: acme-launch", text: $projectSlug)
                                .textFieldStyle(.roundedBorder)
                                .font(AQDesign.TypeToken.scaledBody(textScale))
                                .focused(formFocused)
                                .accessibilityLabel("Optional project slug")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Note")
                                .font(AQDesign.TypeToken.scaledHint(textScale))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $note)
                                .font(AQDesign.TypeToken.scaledBody(textScale))
                                .frame(minHeight: 64, maxHeight: 110)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                                .accessibilityLabel("Optional note")
                        }
                        if let error = preview.validationError ?? viewModel.screenHistory.saveError {
                            Text(error)
                                .font(AQDesign.TypeToken.scaledHint(textScale))
                                .foregroundStyle(AQDesign.ColorToken.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Unable to save. \(error)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 380)
                HStack(spacing: AQDesign.Space.standard) {
                    Button("Save moment") {
                        Task {
                            _ = await viewModel.screenHistory.saveNote(
                                for: result,
                                projectSlug: projectSlug,
                                note: note
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .font(AQDesign.TypeToken.scaledBody(textScale, weight: .semibold))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(preview.validationError != nil)
                    Button("Cancel") { viewModel.dismissItemActionLayer() }
                        .font(AQDesign.TypeToken.scaledBody(textScale))
                    Spacer()
                    Text("⌘↩ saves · esc cancels")
                        .font(AQDesign.TypeToken.scaledHint(textScale))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("This screen moment is no longer available.")
                .font(.body)
                .foregroundStyle(AQDesign.ColorToken.danger)
        }
    }
}
