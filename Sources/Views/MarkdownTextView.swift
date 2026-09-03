import SwiftUI
import AppKit

/// Displays an NSAttributedString in a non-editable, selectable NSTextView.
/// Used for markdown-rendered output in the overlay.
struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let isStreaming: Bool

    /// Remembers what the text view already shows, so an unrelated state
    /// change does not re-layout the whole answer.
    final class Coordinator {
        var shownMarkdown: String?
        var shownStreaming = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        // A long answer scrolls inside the capped window; without the
        // scroller nothing hinted that more text sat below the fold.
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.shownMarkdown != markdown || coordinator.shownStreaming != isStreaming else { return }
        coordinator.shownMarkdown = markdown
        coordinator.shownStreaming = isStreaming
        let newAttr = NSMutableAttributedString(attributedString: MarkdownRenderer.cachedRender(markdown))
        if isStreaming {
            // The streaming caret is house ink at the prose size.
            let cursor = NSAttributedString(string: "\u{258B}", attributes: [
                .font: NSFont.systemFont(ofSize: House.TypeToken.Size.body),
                .foregroundColor: House.NSColorToken.textPrimary,
            ])
            newAttr.append(cursor)
        }
        textView.textStorage?.setAttributedString(newAttr)
        if isStreaming {
            // Follow the stream: new text appears at the bottom edge, not
            // below it.
            textView.scrollRangeToVisible(NSRange(location: newAttr.length, length: 0))
        }
    }
}
