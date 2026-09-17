import SwiftUI

/// What the next Send will read and where it will go, drawn between the
/// attachment strip and the composer field. Both surfaces draw it, because
/// both compose `QuickAIComposer`: Quick AI on its panel, the AI Chat window
/// in its shell.
///
/// Every word comes from the view model's resolution of the request as it
/// stands, never from the state of a control: `contextScopeLabel` is the
/// policy the next turn will actually run under, so an ordinary chat with no
/// sources reads "Standard chat", a grounded question whose tools are
/// withheld reads "Attached sources", and one the user widened reads
/// "Broader search", whatever was clicked to get there.
struct ChatPreSendControls: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(spacing: House.Spacing.xs) {
                scopeControl
                if let attached = viewModel.attachedSourceSummary {
                    Text(attached)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: House.Spacing.xs)
                destination
            }
            if !viewModel.contextScopeDetail.isEmpty {
                Text(viewModel.contextScopeDetail)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
            sendAsText
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the next message reads and where it goes")
    }

    // MARK: - Scope

    /// The visible Attached sources / Broader search control. It is never
    /// disabled: the view model picks the other side of the *effective*
    /// decision, so the same click widens a withheld request and narrows an
    /// open one.
    private var scopeControl: some View {
        Button {
            viewModel.toggleContextScope()
        } label: {
            HStack(spacing: House.Spacing.xxs) {
                Circle()
                    .fill(viewModel.contextScopeOffersWidening
                        ? AQDesign.ColorToken.warning
                        : AQDesign.ColorToken.textTertiary.opacity(0.6))
                    .frame(width: House.Spacing.xxs, height: House.Spacing.xxs)
                    .accessibilityHidden(true)
                Text(viewModel.contextScopeLabel)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(minHeight: House.Control.chip - 6)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(AQDesign.ColorToken.chipFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What this message can read")
        .accessibilityValue(viewModel.contextScopeLabel)
        .accessibilityHint(viewModel.contextScopeDetail)
        .help(viewModel.contextScopeOffersWidening
            ? "Broaden this question to earlier turns and outside sources"
            : (viewModel.contextScopeDetail.isEmpty ? "Change what this message may read" : viewModel.contextScopeDetail))
    }

    // MARK: - Destination

    /// Where the next Send actually goes. The route is resolved once, by the
    /// view model, for the request as it stands, so a tray image, an image
    /// from an earlier turn and a plain text question all read from the same
    /// decision the send path uses. The view adds no heuristic of its own:
    /// it never looks at pending images or at the configured vision model.
    private var destination: some View {
        ChatDestinationLabel(destination: ChatDestination(
            label: viewModel.chatDestinationLabel,
            isCloud: viewModel.chatDestinationIsCloud,
            warning: viewModel.chatRouteWarning
        ))
    }

    // MARK: - Send as Text

    /// An unknown slash command stays local. This is the only action that
    /// sends it, so Return and ⌘Return are never consent.
    @ViewBuilder
    private var sendAsText: some View {
        if let refused = viewModel.refusedCommandText {
            HStack(spacing: House.Spacing.xs) {
                Text("Not a command")
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .fixedSize()
                Text(refused)
                    .font(AQDesign.TypeToken.code)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: House.Spacing.xs)
                Button {
                    viewModel.sendRefusedCommandAsText()
                } label: {
                    Text("Send as Text")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, House.Spacing.sm)
                        .frame(minHeight: House.Control.chip - 6)
                        .background(
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .fill(AQDesign.ColorToken.chipFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-send-as-text")
                .accessibilityLabel("Send as Text")
                .help("Send \(refused) as an ordinary question")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Not a command: \(refused)")
        }
    }
}

/// Where the next Send goes, as the view model resolved it for the request
/// as it stands.
///
/// One seam feeds both this line and the actual send, so the label can never
/// name a destination the request will not use. `warning` is set when the
/// chosen route cannot actually run (an image route with no key or no model,
/// for one): the line then says so instead of claiming the destination.
struct ChatDestination: Equatable {
    var label: String
    var isCloud: Bool
    var warning: String?

    /// How the line reads. The view draws exactly this, so a test can prove
    /// the wording without reading pixels.
    struct Presentation: Equatable {
        /// The line's text: the warning when there is one, the destination
        /// otherwise.
        var primary: String
        /// The destination, demoted to an explanation, only under a warning.
        var secondary: String?
        var symbol: String
        var isWarning: Bool
        var accessibilityLabel: String
    }

    var presentation: Presentation {
        Presentation(
            primary: warning ?? label,
            secondary: warning == nil ? nil : label,
            symbol: warning != nil ? "exclamationmark.triangle" : (isCloud ? "cloud" : "desktopcomputer"),
            isWarning: warning != nil,
            accessibilityLabel: warning.map { "Route warning: \($0). \(label)" } ?? "Destination: \(label)"
        )
    }
}

/// The resolved destination line: the route when it will run, the warning
/// when it will not. A warning owns the line, so the destination is never
/// stated as a promise the send path will not keep.
struct ChatDestinationLabel: View {
    let destination: ChatDestination

    private var presentation: ChatDestination.Presentation { destination.presentation }

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            Image(systemName: presentation.symbol)
                .font(AQDesign.TypeToken.footnote.weight(.semibold))
                .foregroundStyle(presentation.isWarning
                    ? AQDesign.ColorToken.warning
                    : AQDesign.ColorToken.textTertiary)
                .accessibilityHidden(true)
            Text(presentation.primary)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(presentation.isWarning
                    ? AQDesign.ColorToken.warning
                    : AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let secondary = presentation.secondary {
                Text("·")
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Text(secondary)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The warning keeps the room; the explanation yields.
                    .layoutPriority(-1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .help(destination.warning ?? destination.label)
    }
}
