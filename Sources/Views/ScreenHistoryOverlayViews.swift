import SwiftUI

/// Screen History's overlay surfaces: the catalog row, the empty state, the
/// Save to Vault form, and the layout constants the core sizing asks for.
/// `OverlayView` only calls into these; it holds no Screen History logic.

/// Layout budget for the Save to Vault form.
enum ScreenHistorySaveLayout {
    /// Keeps the exact payload preview and its primary action visible. The
    /// payload body scrolls within this fixed production budget.
    static let minimumWindowHeight: CGFloat = 620
    /// The scrolling payload preview inside the form, in row units.
    static let previewScrollHeight = House.Control.row * 9
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
        // A two-line row keeps the house roles: the title is the label
        // weight, the detail is metadata. Dynamic Type stays, so the Screen
        // History text-size control still grows both lines.
        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
            Text(item.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

/// Screen History rows grow with Dynamic Type; every other row stays the
/// house row height.
struct ScreenHistoryRowFrame: ViewModifier {
    let result: LauncherSearchResult
    @ScaledMetric(relativeTo: .body) private var rowMinHeight = House.Control.input

    func body(content: Content) -> some View {
        let isScreenHistory = ScreenHistoryResultRow.isScreenHistory(result)
        content.frame(
            minHeight: isScreenHistory ? rowMinHeight : AQDesign.rowHeight,
            maxHeight: isScreenHistory ? nil : AQDesign.rowHeight
        )
    }
}

/// The footer needs a taller minimum in the Screen History catalog so its
/// longer context line survives accessibility text sizes.
struct ScreenHistoryFooterFrame: ViewModifier {
    let isActive: Bool
    let defaultMinHeight: CGFloat
    @ScaledMetric(relativeTo: .caption) private var footerMinHeight = House.Control.railRow

    func body(content: Content) -> some View {
        content.frame(minHeight: isActive ? footerMinHeight : defaultMinHeight)
    }
}

struct ScreenHistoryEmptyState: View {
    @Bindable var viewModel: QuickViewModel
    @ScaledMetric(relativeTo: .body) private var minimumHeight =
        House.Spacing.xxxxl + House.Spacing.xxl

    var body: some View {
        let presentation = ScreenHistoryEmptyPresentation(
            state: viewModel.screenHistory.loadState,
            query: viewModel.input
        )
        HStack(alignment: .top, spacing: House.Spacing.sm) {
            IconTile {
                Image(systemName: presentation.icon)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
            }
            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                Text(presentation.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                if presentation.offersClearFilters {
                    Button("Clear filters") {
                        viewModel.input = ""
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .padding(House.Spacing.lg)
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
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                ScrollView {
                    VStack(alignment: .leading, spacing: House.Spacing.sm) {
                        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                            LabeledContent("Source", value: preview.source)
                            LabeledContent("Local record ID", value: preview.localRecordID)
                            LabeledContent("Seen at", value: preview.seenAt)
                            LabeledContent("Application", value: preview.application)
                            LabeledContent("Window", value: preview.window)
                            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                                Text("OCR excerpt saved to Vault")
                                    .font(AQDesign.TypeToken.scaledHint(textScale, weight: .semibold))
                                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                Text(preview.ocrExcerpt.isEmpty ? "Empty" : preview.ocrExcerpt)
                                    .font(AQDesign.TypeToken.scaledHint(textScale))
                                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AQDesign.Space.standard)
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: AQDesign.fieldCornerRadius,
                                            style: .continuous
                                        )
                                        .fill(AQDesign.ColorToken.surfaceFill)
                                    )
                            }
                        }
                        .font(AQDesign.TypeToken.scaledBody(textScale))
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Screen moment preview")

                        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                            Text("Project slug")
                                .font(AQDesign.TypeToken.scaledHint(textScale))
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            TextField("Optional, for example: acme-launch", text: $projectSlug)
                                .textFieldStyle(.roundedBorder)
                                .font(AQDesign.TypeToken.scaledBody(textScale))
                                .focused(formFocused)
                                .accessibilityLabel("Optional project slug")
                        }
                        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                            Text("Note")
                                .font(AQDesign.TypeToken.scaledHint(textScale))
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            TextEditor(text: $note)
                                .font(AQDesign.TypeToken.scaledBody(textScale))
                                .frame(
                                    minHeight: House.Spacing.xxxxl,
                                    maxHeight: House.Control.row * 3
                                )
                                .overlay(
                                    RoundedRectangle(
                                        cornerRadius: AQDesign.fieldCornerRadius,
                                        style: .continuous
                                    )
                                    .strokeBorder(
                                        AQDesign.ColorToken.fieldStroke,
                                        lineWidth: AQDesign.hairline
                                    )
                                )
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
                .frame(maxHeight: ScreenHistorySaveLayout.previewScrollHeight)
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
                    .buttonStyle(InkButtonStyle())
                    .font(AQDesign.TypeToken.scaledBody(textScale, weight: .semibold))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(preview.validationError != nil)
                    Button("Cancel") { viewModel.dismissItemActionLayer() }
                        .font(AQDesign.TypeToken.scaledBody(textScale))
                    Spacer()
                    Text("⌘↩ saves · esc cancels")
                        .font(AQDesign.TypeToken.scaledHint(textScale))
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
            }
        } else {
            Text("This screen moment is no longer available.")
                .font(.body)
                .foregroundStyle(AQDesign.ColorToken.danger)
        }
    }
}
