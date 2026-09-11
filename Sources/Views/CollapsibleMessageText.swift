import AppKit
import SwiftUI

/// One user turn's text, with the Show more / Collapse control from
/// `MessageCollapseState`. A short message renders whole and grows no
/// control; a long one starts collapsed at the first part of the text.
/// Answers never collapse, so they draw as prose and never come here.
///
/// The control is a real button, so it is keyboard focusable, reachable by
/// VoiceOver, and announces the state it moved to. `⇧⌘M` toggles the newest
/// collapsible message from anywhere in the overlay, for a reader who never
/// leaves the composer; only that message's control shows the key.
struct CollapsibleMessageText: View {
    let state: MessageCollapseState
    /// Whether `⇧⌘M` acts on this message (the newest collapsible turn).
    /// Only then does the control draw the key caps, in both Show more
    /// and Collapse.
    var showsShortcut = false
    /// The font of the body. A user pill in the thread reads at `body`; the
    /// default is the transcript's `detail`.
    var plainTextFont: Font = AQDesign.TypeToken.detail
    /// Whether the body takes the full width or hugs its text (a pill in
    /// the thread).
    var fillsWidth = true
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
            messageBody

            if let title = state.controlTitle {
                Button(action: toggle) {
                    HStack(spacing: AQDesign.Space.compact) {
                        Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                            .font(AQDesign.TypeToken.footnote.weight(.semibold))
                        Text(title)
                            .font(AQDesign.TypeToken.metadata)
                        if showsShortcut {
                            KeyCapGroup(keys: QuickViewModel.transcriptCollapseShortcut.keyCaps)
                        }
                    }
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .padding(.horizontal, AQDesign.Space.standard)
                    .frame(height: House.Control.chip - 6)
                    .background(
                        RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                            .fill(AQDesign.ColorToken.chipFill)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel(title)
                .accessibilityValue(state.accessibilityState)
                .help(helpText)
            }
        }
    }

    private var helpText: String {
        let help = state.isExpanded ? "Collapse this message" : "Show the rest of this message"
        guard showsShortcut else { return help }
        return "\(help) (\(QuickViewModel.transcriptCollapseShortcut.keyCaps.joined()))"
    }

    private var messageBody: some View {
        Text(state.displayedText)
            .font(plainTextFont)
            .textSelection(.enabled)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .accessibilityLabel(state.text)
    }

    private func toggle() {
        onToggle()
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: state.isExpanded ? "Message collapsed" : "Message expanded",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
