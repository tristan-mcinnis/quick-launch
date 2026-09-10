import AppKit
import SwiftUI

/// What one fenced code block carries: the language its info string names,
/// the code the fence wrapped, and what Copy writes.
struct CodeBlockContent: Equatable, Sendable {
    /// The fence's info string as written, `nil` when the fence had none.
    let infoString: String?
    /// The code the fence wrapped, without the fence markers and without the
    /// trailing newline the fenced block adds.
    let code: String

    /// The fence's detected language: the first word of the info string.
    /// `nil` when the fence carried none, so the block draws unlabelled
    /// rather than guessing at syntax.
    var language: String? {
        guard let infoString else { return nil }
        guard let token = infoString.split(whereSeparator: \.isWhitespace).first else { return nil }
        let label = String(token)
        return label.isEmpty ? nil : label
    }

    /// What Copy writes to the pasteboard: the code exactly, with no fence
    /// markers, no language label, and no surrounding prose.
    var copyPayload: String { code }

    /// The code's line count, for the block's accessibility label.
    var lineCount: Int {
        code.isEmpty ? 1 : code.components(separatedBy: "\n").count
    }

    /// What the block announces to VoiceOver: its language when the fence
    /// named one, and its size.
    var accessibilityLabel: String {
        let lines = lineCount
        let unit = lines == 1 ? "line" : "lines"
        guard let language else { return "Code block, \(lines) \(unit)" }
        return "\(language) code block, \(lines) \(unit)"
    }
}

/// The wrap toggle's state. Wrap starts off, so long lines scroll sideways
/// until the reader asks for wrapping.
struct CodeBlockWrapState: Equatable {
    /// The control's label, the same in both states so it stays findable.
    static let label = "Wrap"
    /// The control's accessible name. The visible label never carries the
    /// state, so VoiceOver reads it from `accessibilityValue`.
    static let accessibilityLabel = "Wrap long lines"
    /// Wrap is off until the reader turns it on.
    static let initialState = CodeBlockWrapState(isWrapped: false)

    private(set) var isWrapped: Bool

    init(isWrapped: Bool) {
        self.isWrapped = isWrapped
    }

    /// Off means the code body scrolls sideways.
    var scrollsSideways: Bool { !isWrapped }

    /// What VoiceOver reads for the toggle: the visible label never changes,
    /// so the state has to.
    var accessibilityValue: String { isWrapped ? "On" : "Off" }

    var helpText: String {
        isWrapped
            ? "Wrapping long lines to the answer width. Turn off to scroll them sideways."
            : "Scrolling long lines sideways. Turn on to wrap them to the answer width."
    }

    mutating func toggle() {
        isWrapped.toggle()
    }
}

/// The code block's measurements. The view draws to these and
/// `MarkdownRenderer.measuredHeight` reads them, so the drawn block and the
/// measured window cannot drift apart.
enum CodeBlockMetrics {
    /// The header strip: language, Copy, and the wrap toggle.
    static let headerHeight: CGFloat = House.Control.compact + AQDesign.Space.compact
    static let bodyHorizontalPadding: CGFloat = AQDesign.Space.standard
    static let bodyVerticalPadding: CGFloat = AQDesign.Space.standard
    static let cornerRadius: CGFloat = AQDesign.fieldCornerRadius

    /// The header plus the hairline under it.
    static var chromeHeight: CGFloat { headerHeight + House.hairline }

    static var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: House.TypeToken.Size.code, weight: .regular)
    }

    /// One code line at the house code size.
    static var lineHeight: CGFloat {
        let font = codeFont
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// Height the block draws at `width`. Wrap is off by default, so the
    /// measured height is the code's line count, which is what the unwrapped
    /// body draws while it scrolls sideways.
    static func height(
        of content: CodeBlockContent,
        width: CGFloat,
        isWrapped: Bool = CodeBlockWrapState.initialState.isWrapped
    ) -> CGFloat {
        chromeHeight + bodyHeight(code: content.code, width: width, isWrapped: isWrapped)
            + bodyVerticalPadding * 2
    }

    static func bodyHeight(code: String, width: CGFloat, isWrapped: Bool) -> CGFloat {
        guard isWrapped else {
            let lines = code.isEmpty ? 1 : code.components(separatedBy: "\n").count
            return CGFloat(lines) * lineHeight
        }
        let available = max(width - bodyHorizontalPadding * 2, 1)
        let rect = attributed(code).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(rect.height.rounded(.up), lineHeight)
    }

    private static func attributed(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: codeFont])
    }
}

/// Which of a code block's accessibility elements an identifier names.
enum CodeBlockControl: String {
    case block, copy, wrap
}

/// One fenced code block in an assistant answer: the header strip with the
/// fence language, Copy, and the wrap toggle, over the code itself.
struct CodeBlockView: View {
    let content: CodeBlockContent
    /// Names the surface this block belongs to. The same code can be on
    /// screen twice (an overlay answer and a `⌘J` thread message), so the
    /// controls carry an identifier scoped to the instance they belong to.
    var instanceID = "answer"

    /// The identifier one of this block's controls carries.
    static func accessibilityIdentifier(
        _ control: CodeBlockControl,
        instance: String
    ) -> String {
        "code-block-\(instance)-\(control.rawValue)"
    }

    @State private var wrap = CodeBlockWrapState.initialState
    @State private var didCopy = false
    @State private var copyRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HouseDivider()
            codeBody
        }
        .background(
            RoundedRectangle(cornerRadius: CodeBlockMetrics.cornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: CodeBlockMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodeBlockMetrics.cornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.accessibilityIdentifier(.block, instance: instanceID))
        .accessibilityLabel(content.accessibilityLabel)
        // Clears the "Copied" confirmation after a beat, and is cancelled
        // when the block changes or disappears.
        .task(id: copyRevision) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AQDesign.Space.standard) {
            if let language = content.language {
                Text(language)
                    .font(AQDesign.TypeToken.code)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .accessibilityLabel("Language: \(language)")
            }
            Spacer(minLength: AQDesign.Space.standard)
            wrapToggle
            copyButton
        }
        .padding(.horizontal, AQDesign.Space.standard)
        .frame(height: CodeBlockMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(AQDesign.ColorToken.well)
    }

    private var wrapToggle: some View {
        Button {
            wrap.toggle()
        } label: {
            chromeLabel(
                title: CodeBlockWrapState.label,
                systemImage: wrap.isWrapped ? "checkmark" : "arrow.left.and.right",
                isActive: wrap.isWrapped
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(CodeBlockWrapState.accessibilityLabel)
        .accessibilityValue(wrap.accessibilityValue)
        .accessibilityIdentifier(Self.accessibilityIdentifier(.wrap, instance: instanceID))
        .accessibilityHint(wrap.helpText)
        .accessibilityAddTraits(wrap.isWrapped ? [.isSelected] : [])
        .help(wrap.helpText)
    }

    private var copyButton: some View {
        Button {
            copyCode()
        } label: {
            chromeLabel(
                title: didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                isActive: didCopy
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(Self.copyAccessibilityLabel(didCopy: didCopy))
        .accessibilityIdentifier(Self.accessibilityIdentifier(.copy, instance: instanceID))
        .accessibilityHint(Self.copyHelpText)
        .help("Copy code")
    }

    /// A header control: quiet ink when idle, a filled and checked chip when
    /// it carries the block's state.
    private func chromeLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        HStack(spacing: AQDesign.Space.compact + 2) {
            Image(systemName: systemImage)
                .font(AQDesign.TypeToken.caption)
            Text(title)
                .font(AQDesign.TypeToken.metadata)
        }
        .foregroundStyle(
            isActive ? AQDesign.ColorToken.textPrimary : AQDesign.ColorToken.textSecondary
        )
        .padding(.horizontal, AQDesign.Space.standard)
        .frame(minHeight: AQDesign.keyCapHeight)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius, style: .continuous)
                .fill(isActive ? AQDesign.ColorToken.selectionFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius, style: .continuous)
                .strokeBorder(
                    isActive ? AQDesign.ColorToken.keyCapStroke : Color.clear,
                    lineWidth: AQDesign.hairline
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: - Body

    @ViewBuilder
    private var codeBody: some View {
        if wrap.isWrapped {
            codeText
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CodeBlockMetrics.bodyHorizontalPadding)
                .padding(.vertical, CodeBlockMetrics.bodyVerticalPadding)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                codeText
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, CodeBlockMetrics.bodyHorizontalPadding)
                    .padding(.vertical, CodeBlockMetrics.bodyVerticalPadding)
            }
        }
    }

    private var codeText: some View {
        Text(content.code)
            .font(AQDesign.TypeToken.code)
            .foregroundStyle(AQDesign.ColorToken.textPrimary)
            .textSelection(.enabled)
            .accessibilityLabel("Code")
            .accessibilityValue(content.code)
    }

    // MARK: - Copy

    /// The Copy control's accessible name, which becomes the confirmation
    /// once the code has landed on the pasteboard.
    static func copyAccessibilityLabel(didCopy: Bool) -> String {
        didCopy ? "Copied" : "Copy code"
    }

    static let copyHelpText = "Copies this block's code, without the fence markers"

    private func copyCode() {
        Self.writeToPasteboard(content.copyPayload)
        didCopy = true
        copyRevision += 1
        Self.announceCopied()
    }

    /// Writes a block's payload to the pasteboard. Tests pass a scratch
    /// pasteboard so the general one is untouched.
    @MainActor
    static func writeToPasteboard(_ payload: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    /// The inline confirmation is visual; VoiceOver gets the announcement.
    @MainActor
    static func announceCopied() {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Code copied",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
