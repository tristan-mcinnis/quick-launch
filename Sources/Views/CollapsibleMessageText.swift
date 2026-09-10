import AppKit
import SwiftUI

/// One transcript message body, with the Show more / Collapse control from
/// `MessageCollapseState`. A short message renders whole and grows no
/// control; a long one starts collapsed at the first part of the text.
///
/// The control is a real button, so it is keyboard focusable, reachable by
/// VoiceOver, and announces the state it moved to. `⌘⇧M` toggles the newest
/// collapsible message from anywhere in the overlay, for a reader who never
/// leaves the composer.
struct CollapsibleMessageText: View {
    let state: MessageCollapseState
    /// How the surface draws the message body. The overlay's transcript block
    /// draws it as plain text; the `⌘J` thread draws the answer stack, which
    /// is what gives a message its code blocks. The collapse rule, the
    /// control, and its announcement are shared either way.
    var rendersMarkdown = false
    /// Scopes the answer stack's controls, so the thread's Copy button and
    /// the overlay's are not the same accessibility element.
    var instanceID = "transcript"
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
                        if !state.isExpanded {
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
                .help(state.isExpanded
                    ? "Collapse this message"
                    : "Show the rest of this message (⌘⇧M)")
            }
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        if rendersMarkdown {
            MarkdownTextView(
                markdown: state.displayedText,
                isStreaming: false,
                scrolls: false,
                instanceID: instanceID
            )
            .accessibilityLabel(state.text)
        } else {
            Text(state.displayedText)
                .font(AQDesign.TypeToken.detail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(state.text)
        }
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
