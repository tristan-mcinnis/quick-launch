import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// Attachment chips (spec section 3.10): one chip view for the composer
// strip, the question pills in the thread, Quick AI, and AI Chat; the strip
// above the composer; read-only chips over a pill; the drop overlay and
// target; and the pasteboard reader behind `⌘V`.

extension EnvironmentValues {
    /// The composer's attachment tray, for views that sit between the owner
    /// and the composer and do not pass it on (the Quick AI surface, the
    /// floating Add Context pane). An explicit `tray:` parameter wins.
    @Entry var attachmentTray: AttachmentTray? = nil
}

// MARK: - Chip model

/// What one chip shows, whatever it came from: a tray item in the composer,
/// a reference on a sent question, or an attachment the view model held
/// before the tray.
struct AttachmentChipModel: Identifiable, Equatable {
    enum Phase: Equatable {
        case reading
        case ready
        case failed(String)
        /// A sent attachment whose text (or picture) this session does not
        /// hold: "Not loaded" after a relaunch, "Image not kept" for a
        /// picture. Never colour; the line says it.
        case notLoaded(String)
    }

    let id: String
    var kind: ChatAttachmentKind
    var name: String
    var phase: Phase
    /// Units and size ("42 pp · 1.2 MB"), pixel size, or a link's host.
    var detail: String
    /// The cut, in the chip's words ("first 200,000 of 612,000 characters").
    var cut: String?
    /// PNG or JPEG bytes for an image chip's thumbnail. Memory only.
    var imageData: Data?
    /// Overrides the kind's glyph (a window context chip).
    var glyphOverride: String?

    var systemImage: String {
        if case .failed = phase { return "exclamationmark.triangle" }
        return glyphOverride ?? Self.systemImage(for: kind)
    }

    /// The detail as drawn: "Reading…", the failure line, or the detail
    /// with " · cut" when the text was cut.
    var detailLine: String {
        switch phase {
        case .reading: return "Reading…"
        case .failed(let line): return line
        case .notLoaded(let line): return line
        case .ready: return cut == nil ? detail : [detail, "cut"].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// The tooltip: the whole cut line, the failure, or the name.
    var help: String {
        switch phase {
        case .failed(let line): return "\(name): \(line)"
        case .notLoaded(let line): return "\(name): \(line)"
        case .reading: return "Reading \(name)…"
        case .ready:
            guard let cut else { return name }
            return "\(name): \(Self.sentenceCase(cut))"
        }
    }

    /// VoiceOver: "Attachment: Q3 report.pdf, PDF, 42 pages, cut to the
    /// first 200,000 of 612,000 characters".
    var accessibilityLabel: String {
        var parts = ["Attachment: \(name)", Self.kindName(for: kind)]
        switch phase {
        case .reading:
            parts.append("reading")
        case .failed(let line), .notLoaded(let line):
            parts.append(line)
        case .ready:
            if let spoken = spokenDetail, !spoken.isEmpty { parts.append(spoken) }
            if let cut { parts.append("cut to the \(cut)") }
        }
        return parts.joined(separator: ", ")
    }

    /// The detail read aloud: pages, not "pp"; "by", not "×".
    var spokenDetail: String?

    // MARK: Builders

    /// A chip for a reference: a sent question's pill, or a tray item that
    /// was read.
    init(ref: ChatAttachmentRef, imageData: Data? = nil, id: String? = nil) {
        self.id = id ?? ref.id.uuidString
        self.kind = ref.kind
        self.name = ref.name
        self.phase = .ready
        self.detail = Self.detail(for: ref)
        self.spokenDetail = Self.spokenDetail(for: ref)
        self.cut = ref.truncation.map(\.summary).flatMap { $0.isEmpty ? nil : $0 }
        self.imageData = ref.kind.isImage ? imageData : nil
        self.glyphOverride = nil
    }

    /// A chip for a tray item in any phase.
    init(item: AttachmentTray.Item) {
        switch item.phase {
        case .ready(let content):
            self = AttachmentChipModel(ref: content.ref, imageData: content.image?.data, id: item.id.uuidString)
        case .reading, .failed:
            self.id = item.id.uuidString
            self.kind = item.kind
            self.name = item.name
            if case .failed(let line) = item.phase {
                self.phase = .failed(line)
            } else {
                self.phase = .reading
            }
            self.detail = ""
            self.spokenDetail = nil
            self.cut = nil
            if case .some(.image(let image, _, _)) = item.source {
                self.imageData = image.data
            } else {
                self.imageData = nil
            }
            self.glyphOverride = nil
        }
        if phase == .ready {
            detail = ["Ready", detail].filter { !$0.isEmpty }.joined(separator: " · ")
            spokenDetail = ["ready to send", spokenDetail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// A chip drawn from its parts (the view model's attachments before
    /// the tray, and render proofs).
    init(
        id: String,
        kind: ChatAttachmentKind,
        name: String,
        detail: String,
        spokenDetail: String? = nil,
        imageData: Data? = nil,
        glyphOverride: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.phase = .ready
        self.detail = detail
        self.spokenDetail = spokenDetail ?? detail
        self.cut = nil
        self.imageData = imageData
        self.glyphOverride = glyphOverride
    }

    // MARK: Words and glyphs

    static func systemImage(for kind: ChatAttachmentKind) -> String {
        switch kind {
        case .pdf: "doc.richtext"
        case .word: "doc.text"
        case .powerpoint: "rectangle.on.rectangle.angled"
        case .excel: "tablecells"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .text, .markdown: "text.alignleft"
        case .code: "curlybraces"
        case .link: "link"
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        case .selection: "text.cursor"
        }
    }

    static func kindName(for kind: ChatAttachmentKind) -> String {
        kind.displayName
    }

    /// "42 pp · 1.2 MB", "12 slides", "3 sheets", "18 KB", "1944 × 1464",
    /// or a link's host.
    static func detail(for ref: ChatAttachmentRef) -> String {
        switch ref.kind {
        case .image, .screenshot:
            guard let width = ref.pixelWidth, let height = ref.pixelHeight else { return "" }
            return "\(width) × \(height)"
        case .link:
            return ref.host ?? ref.url?.absoluteString ?? ""
        case .selection:
            return ref.characterCount.map { "\(AttachmentTruncation.count($0)) characters" } ?? ""
        default:
            var parts: [String] = []
            if let units = unitText(for: ref, short: true) { parts.append(units) }
            if let bytes = ref.byteCount { parts.append(byteText(bytes)) }
            return parts.joined(separator: " · ")
        }
    }

    static func spokenDetail(for ref: ChatAttachmentRef) -> String? {
        switch ref.kind {
        case .image, .screenshot:
            guard let width = ref.pixelWidth, let height = ref.pixelHeight else { return nil }
            return "\(width) by \(height) pixels"
        case .link:
            return ref.host
        case .selection:
            return ref.characterCount.map { "\(AttachmentTruncation.count($0)) characters" }
        default:
            return unitText(for: ref, short: false)
        }
    }

    private static func unitText(for ref: ChatAttachmentRef, short: Bool) -> String? {
        guard let count = ref.pageCount else { return nil }
        let number = AttachmentTruncation.count(count)
        switch ref.kind {
        case .pdf, .word:
            if short { return "\(number) pp" }
            return count == 1 ? "1 page" : "\(number) pages"
        case .powerpoint:
            return count == 1 ? "1 slide" : "\(number) slides"
        case .excel:
            return count == 1 ? "1 sheet" : "\(number) sheets"
        default:
            return nil
        }
    }

    /// A file size the way the spec writes it ("18 KB", "1.2 MB"), in
    /// decimal units like Finder, the same on every Mac.
    static func byteText(_ bytes: Int) -> String {
        let units = ["KB", "MB", "GB"]
        guard bytes >= 1_000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let digits = unit == 0 || value >= 10 ? 0 : 1
        let number = value.formatted(
            .number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US"))
        )
        return "\(number) \(units[unit])"
    }

    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - Chips from the view model

/// The screenshots and Screen Awareness context the view model holds today,
/// as chips in the same strip. They go once the view model routes its
/// captures into the tray.
enum PendingCaptureChips {
    static let imagePrefix = "pending-image-"
    static let contextID = "pending-context"

    @MainActor
    static func chips(for viewModel: QuickViewModel) -> [AttachmentChipModel] {
        var chips: [AttachmentChipModel] = []
        let images = viewModel.pendingImages
        for (index, image) in images.enumerated() {
            chips.append(AttachmentChipModel(
                id: imagePrefix + String(index),
                kind: .screenshot,
                name: images.count > 1 ? "Screenshot \(index + 1)" : "Screenshot",
                detail: "\(image.pixelWidth) × \(image.pixelHeight)",
                spokenDetail: "\(image.pixelWidth) by \(image.pixelHeight) pixels",
                imageData: image.data
            ))
        }
        if let context = viewModel.pendingContext,
           context.includedSources != ["Screenshot"],
           !context.includedSources.isEmpty || images.isEmpty {
            let selectionOnly = context.includedSources == ["Selection"]
            chips.append(AttachmentChipModel(
                id: contextID,
                kind: .selection,
                name: selectionOnly
                    ? "Selection · \(context.appName)"
                    : "\(context.captureTypeTitle) · \(context.appName)",
                detail: selectionOnly
                    ? "\(AttachmentTruncation.count(context.selectedText?.count ?? 0)) characters"
                    : context.includedSources.joined(separator: ", "),
                glyphOverride: selectionOnly ? nil : "macwindow"
            ))
        }
        return chips
    }

    /// Removes one of these chips from the view model.
    @MainActor
    static func remove(_ id: String, from viewModel: QuickViewModel) {
        if id == contextID {
            viewModel.pendingContext = nil
        } else if id.hasPrefix(imagePrefix), let index = Int(id.dropFirst(imagePrefix.count)),
                  viewModel.pendingImages.indices.contains(index) {
            viewModel.pendingImages.remove(at: index)
        }
        viewModel.requestInputFocus()
    }
}

// MARK: - Chip

/// One attachment: the glyph (or a thumbnail), the name, the detail, and in
/// the composer strip a remove button. `Control.chip` high at `Radius.sm`
/// on `chipFill`; no colour in any state (DESIGN rule 2).
struct AttachmentChip: View {
    let model: AttachmentChipModel
    /// The strip's keyboard selection.
    var isSelected = false
    /// Present only in the composer strip.
    var onRemove: (() -> Void)? = nil
    /// Opens the attachment (a pill chip in the thread).
    var onOpen: (() -> Void)? = nil
    /// Reads a failed composer attachment again.
    var onRetry: (() -> Void)? = nil
    /// Reads a "Not loaded" attachment again: the same file, or the link
    /// fetched again. Only when the user clicks it.
    var onReattach: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.leading, House.Spacing.xs)
            .padding(.trailing, onRemove == nil ? House.Spacing.xs : House.Spacing.xxs)
            .frame(height: House.Control.chip)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
            .onTapGesture { if let onOpen { onOpen() } }
            .onHover { hovering in isHovering = hovering }
            .animation(reduceMotion ? nil : .easeOut(duration: House.Motion.hover), value: isHovering)
            .help(model.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .modifier(ChipAccessibilityActions(onRemove: onRemove, onOpen: onOpen, onRetry: onRetry, onReattach: onReattach))
    }

    private var content: some View {
        HStack(spacing: House.Spacing.xxs) {
            leading
            nameText
            detailText
            if model.phase == .reading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: House.Spacing.sm, height: House.Spacing.sm)
                    .accessibilityHidden(true)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .buttonStyle(.plain)
                    .help("Read \(model.name) again (Space on the selected chip)")
                    .accessibilityHidden(true)
            }
            if let onReattach { reattachButton(onReattach) }
            if let onRemove { removeButton(onRemove) }
        }
    }

    /// "Re-attach" at the chip's end, in secondary ink: a word, not a colour.
    private func reattachButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Re-attach")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .underline(isHovering)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.kind == .link ? "Fetch \(model.name) again" : "Read \(model.name) again from the same file")
        .accessibilityHidden(true)
    }

    private var nameText: some View {
        Text(model.name)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: PanelSizing.attachmentNameMaxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var detailText: some View {
        let line = model.detailLine
        if !line.isEmpty {
            Text(line)
                .font(House.TypeToken.meta)
                .monospacedDigit()
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(AQDesign.TypeToken.glyphSmall)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove \(model.name)")
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var leading: some View {
        if case .failed = model.phase {
            glyph
        } else if model.kind.isImage, let data = model.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                .clipShape(RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous))
                .accessibilityHidden(true)
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: model.systemImage)
            .font(House.TypeToken.caption)
            .foregroundStyle(House.ColorToken.textSecondary)
            .frame(width: House.Spacing.md, height: House.Spacing.md)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
        if isSelected {
            shape
                .fill(House.ColorToken.selectionFill)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
        } else {
            shape.fill(isHovering && (onRemove != nil || onOpen != nil)
                ? House.ColorToken.hoverFill
                : House.ColorToken.chipFill)
        }
    }
}

/// Remove and Open as VoiceOver actions, since the chip reads as one element.
private struct ChipAccessibilityActions: ViewModifier {
    let onRemove: (() -> Void)?
    let onOpen: (() -> Void)?
    let onRetry: (() -> Void)?
    let onReattach: (() -> Void)?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let onRemove { Button("Remove", action: onRemove) }
            if let onOpen { Button("Open", action: onOpen) }
            if let onRetry { Button("Retry", action: onRetry) }
            if let onReattach { Button("Re-attach", action: onReattach) }
        }
    }
}

// MARK: - Strip

/// The row of chips above the composer: `Control.chip` plus `Spacing.xs`
/// above and below, chips `Spacing.xs` apart, scrolling sideways when they
/// overflow, the routing line at the trailing end, then clear-all.
struct AttachmentStripView: View {
    let chips: [AttachmentChipModel]
    var focusedID: String? = nil
    var routingLine: String? = nil
    /// Left and right of the row: the composer circles' inset in Quick AI
    /// and AI Chat, the panel inset at root.
    var sideInset: CGFloat = House.Spacing.xs
    let onRemove: (String) -> Void
    let onClearAll: () -> Void
    var onRetry: ((String) -> Void)? = nil
    var selectionPreview: QuickViewModel.LaunchSelection? = nil

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: House.Spacing.xs) {
                        ForEach(chips) { chip in
                            AttachmentChip(
                                model: chip,
                                isSelected: chip.id == focusedID,
                                onRemove: { onRemove(chip.id) },
                                onRetry: retryAction(for: chip)
                            )
                            .id(chip.id)
                        }
                    }
                }
                .onChange(of: focusedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: chips.last?.id) { _, id in
                    guard let id, focusedID == nil else { return }
                    proxy.scrollTo(id, anchor: .trailing)
                }
            }
            if let routingLine, !routingLine.isEmpty {
                Text(routingLine)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let selectionPreview {
                SelectedTextPreviewButton(
                    text: selectionPreview.text,
                    title: "Selected text from \(selectionPreview.appName)"
                )
            }
            Button(action: onClearAll) {
                Image(systemName: "xmark.circle.fill")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(width: House.Control.chip, height: House.Control.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove all attachments (⌫ removes the newest)")
            .accessibilityLabel("Remove all attachments")
        }
        .padding(.horizontal, sideInset)
        .padding(.vertical, House.Spacing.xs)
        .frame(height: PanelSizing.attachmentStripHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chips.count == 1 ? "1 attachment" : "\(chips.count) attachments")
    }

    private func retryAction(for chip: AttachmentChipModel) -> (() -> Void)? {
        guard case .failed = chip.phase, let onRetry else { return nil }
        return { onRetry(chip.id) }
    }
}

/// The strip as the composers draw it: the tray's chips after the view
/// model's own screenshots and context, the tray's notice above, and the
/// routing line (the tray's, else where the screenshots go).
struct ComposerAttachmentStrip: View {
    @Bindable var viewModel: QuickViewModel
    let tray: AttachmentTray?
    var sideInset: CGFloat = House.Spacing.xs

    /// Whether the strip draws a row of chips.
    @MainActor
    static func hasChips(viewModel: QuickViewModel, tray: AttachmentTray?) -> Bool {
        viewModel.hasPendingAttachment || !(tray?.isEmpty ?? true)
    }

    var body: some View {
        let pending = PendingCaptureChips.chips(for: viewModel)
        let trayChips = tray?.items.map(AttachmentChipModel.init(item:)) ?? []
        let chips = pending + trayChips
        VStack(alignment: .leading, spacing: 0) {
            if let notice = tray?.notice {
                Text(notice)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, sideInset + House.Spacing.xxs)
                    .padding(.top, House.Spacing.xs)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !chips.isEmpty {
                AttachmentStripView(
                    chips: chips,
                    focusedID: tray?.focusedItemID?.uuidString,
                    routingLine: routingLine,
                    sideInset: sideInset,
                    onRemove: remove,
                    onClearAll: clearAll,
                    onRetry: retry,
                    selectionPreview: selectionPreview
                )
            }
        }
        .onChange(of: tray?.notice) { _, notice in
            guard let notice else { return }
            QuickAIAnnouncement.post(notice, priority: .medium)
        }
    }

    private var selectionPreview: QuickViewModel.LaunchSelection? {
        guard viewModel.launchSelection == nil,
              let context = viewModel.pendingContext,
              let text = context.selectedText, !text.isEmpty else { return nil }
        return QuickViewModel.LaunchSelection(text: text, appName: context.appName)
    }

    private var routingLine: String? {
        if let line = tray?.routingLine { return line }
        return viewModel.attachmentRoutingLine
    }

    private func remove(_ id: String) {
        if let uuid = UUID(uuidString: id), let tray, tray.items.contains(where: { $0.id == uuid }) {
            tray.remove(uuid)
            viewModel.requestInputFocus()
        } else {
            PendingCaptureChips.remove(id, from: viewModel)
        }
    }

    private func retry(_ id: String) {
        guard let id = UUID(uuidString: id), let tray else { return }
        if tray.retry(id) { viewModel.errorMessage = nil }
        viewModel.requestInputFocus()
    }

    private func clearAll() {
        if viewModel.hasPendingAttachment { viewModel.clearAttachments() }
        tray?.removeAll()
        viewModel.requestInputFocus()
    }
}

// MARK: - Chips over a question pill

/// A sent question's attachments over its pill: right aligned, read only,
/// wrapping. A click opens the attachment.
struct AttachmentPillChips: View {
    let chips: [AttachmentChipModel]
    var onOpen: ((AttachmentChipModel) -> Void)? = nil
    /// Offered on a chip whose phase is `.notLoaded` and that can be read
    /// again (`canReattach`).
    var onReattach: ((AttachmentChipModel) -> Void)? = nil
    var canReattach: (AttachmentChipModel) -> Bool = { _ in false }

    var body: some View {
        ChipFlowLayout(spacing: House.Spacing.xs) {
            ForEach(chips) { chip in
                AttachmentChip(
                    model: chip,
                    onOpen: onOpen.map { open in { open(chip) } },
                    onReattach: canReattach(chip) ? onReattach.map { reattach in { reattach(chip) } } : nil
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chips.count == 1 ? "1 attachment" : "\(chips.count) attachments")
    }
}

/// Lays chips in rows, right aligned, wrapping to a new row when the next
/// chip does not fit.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Drop

/// Over a drop target while a drag is over it: `hoverFill` at `Radius.xl`
/// with a `strokeStrong` hairline and one line, "Drop to attach", on a
/// raised pill so it reads over any text below. Over a composer it hides
/// what is typed (`coversContent`), since the line would sit on it.
struct AttachmentDropOverlay: View {
    var coversContent = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.xl, style: .continuous)
        ZStack {
            if coversContent { shape.fill(House.ColorToken.surface) }
            shape.fill(House.ColorToken.hoverFill)
            shape.strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
            if coversContent {
                label
            } else {
                // Circular, not continuous: at half the height a continuous
                // capsule's stroke leaves a stray hairline past its caps.
                let pill = RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                label
                    .padding(.horizontal, House.Spacing.md)
                    .frame(height: House.Control.pill)
                    .background(pill.fill(House.ColorToken.surfaceRaised))
                    .overlay(pill.strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text("Drop to attach")
            .font(House.TypeToken.label)
            .foregroundStyle(House.ColorToken.textPrimary)
    }
}

/// Makes a view a drop target for the tray: file URLs, web URLs, and
/// images. No tray, no target.
struct AttachmentDropTarget: ViewModifier {
    let tray: AttachmentTray?
    /// How far the overlay sits inside the target's edge.
    var inset: CGFloat = House.Spacing.xs
    var coversContent = false

    func body(content: Content) -> some View {
        if let tray {
            content
                .onDrop(
                    of: AttachmentTray.droppableTypes,
                    isTargeted: Binding(
                        get: { tray.isDropTargeted },
                        set: { tray.isDropTargeted = $0 }
                    )
                ) { providers in
                    tray.acceptDrop(providers)
                    return true
                }
                .overlay {
                    if tray.isDropTargeted {
                        AttachmentDropOverlay(coversContent: coversContent).padding(inset)
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// See `AttachmentDropTarget`.
    func attachmentDropTarget(_ tray: AttachmentTray?, coversContent: Bool = false) -> some View {
        modifier(AttachmentDropTarget(tray: tray, coversContent: coversContent))
    }
}

// MARK: - Pasteboard

/// Reads what `⌘V` would paste, without writing: files first, then text,
/// then an image (read only when there is no file), so the pasteboard's
/// change count never moves.
enum AttachmentPasteboardReader {
    @MainActor
    static func read(_ pasteboard: NSPasteboard = .general) -> AttachmentPasteboardContents {
        var contents = AttachmentPasteboardContents()
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty {
            contents.fileURLs = files
            return contents
        }
        contents.string = pasteboard.string(forType: .string)
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            contents.image = ClipboardImageReader.attachment(from: pasteboard)
        }
        return contents
    }
}

// MARK: - Quick Look

/// Space on a chip in the strip: the file in the Quick Look panel.
@MainActor
final class AttachmentQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = AttachmentQuickLook()

    private var urls: [URL] = []

    func preview(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        urls = [url]
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
