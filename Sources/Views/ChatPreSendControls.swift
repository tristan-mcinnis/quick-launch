import SwiftUI

/// What the next Send needs the user to know, drawn between the attachment
/// strip and the composer field. Both surfaces draw it, because both compose
/// `QuickAIComposer`: Quick AI on its panel, the AI Chat window in its shell.
///
/// It says nothing in the ordinary case. The scope pill was removed on
/// 2026-09-20 (see `QuickViewModel+ChatCommands`), and the destination is
/// drawn only when it is not the routine one: a blocked route, a local
/// route, or an image going somewhere other than the chosen model. The
/// routine "Will send to <provider>" was on screen for every message and
/// told the user nothing they had not chosen themselves; the route is still
/// recorded against every answer (`ChatContextRecordView`).
///
/// So this whole view collapses to nothing most of the time, and the
/// composer sits directly under the attachment strip.
struct ChatPreSendControls: View {
    @Bindable var viewModel: QuickViewModel

    private var showsDestination: Bool { !viewModel.chatDestinationIsRoutine }
    private var showsAnything: Bool {
        showsDestination || viewModel.refusedCommandText != nil || viewModel.slashSkillNotice != nil
    }

    var body: some View {
        if showsAnything {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                if showsDestination {
                    HStack(spacing: House.Spacing.xs) {
                        Spacer(minLength: House.Spacing.xs)
                        destination
                    }
                }
                skillNotice
                sendAsText
            }
            .padding(.horizontal, House.Spacing.lg)
            .padding(.vertical, House.Spacing.xxs)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What the next message needs you to know")
        }
    }

    // MARK: - Skill

    /// A skill command in the draft puts up to twelve thousand characters of
    /// guidance in front of the question. That is worth one line before
    /// Send, so it is never added silently.
    @ViewBuilder
    private var skillNotice: some View {
        if let notice = viewModel.slashSkillNotice {
            HStack(spacing: House.Spacing.xxs) {
                Image(systemName: "book.closed")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Text(notice)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: House.Spacing.xs)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(notice)
        }
    }

    // MARK: - Destination

    /// Where the next Send actually goes, when that is worth saying. The
    /// route is resolved once, by the view model, for the request as it
    /// stands, so a tray image, an image from an earlier turn and a plain
    /// text question all read from the same decision the send path uses. The
    /// view adds no heuristic of its own: it never looks at pending images
    /// or at the configured vision model.
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
