import AppKit
import SwiftUI

/// Media and text budgets inside the detail pane, written in row units so
/// nothing here invents a size off the house control scale.
private enum DetailMetrics {
    /// A preview image, swatch, or placeholder at rest.
    static let previewHeight = House.Control.row * 3
    /// The tallest a preview or a scrolling block of text grows.
    static let previewMaxHeight = House.Control.row * 5
    /// A plain-text block under the Information group.
    static let textMaxHeight = House.Control.row * 3
}

/// Emoji & Symbols as a grid: Frequently Used first, then everything that
/// matches. Arrow keys move the highlight; Return pastes, ⌘↩ copies.
struct EmojiGridView: View {
    @Bindable var viewModel: QuickViewModel
    static let columns = 9
    /// One cell is a composer-height tile. `PanelSizing` measures the grid
    /// with the same token, so the window and the view cannot drift.
    static let cellHeight = House.Control.composer
    /// A section header takes one spacing step of its own.
    static let headerHeight = House.Spacing.xl

    var body: some View {
        let items = viewModel.launcherMatches
        let sections = viewModel.gridSections
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                HStack(spacing: AQDesign.Space.standard) {
                    SectionLabel(text: section.title)
                    Text("\(section.range.count)")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
                .frame(height: Self.headerHeight)
                .padding(.horizontal, House.Spacing.sm)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: AQDesign.Space.compact),
                        count: Self.columns
                    ),
                    spacing: AQDesign.Space.compact
                ) {
                    ForEach(section.range, id: \.self) { index in
                        if case .item(let item) = items[index] {
                            Button {
                                viewModel.applicationSelectionIndex = index
                                Task { await viewModel.performLauncherResult(items[index]) }
                            } label: {
                                Text(item.value)
                                    .font(.system(size: House.TypeToken.Size.display))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.cellHeight - AQDesign.Space.compact)
                                    // One selection language across the app:
                                    // fill, inset ring, and a 1 pt drop.
                                    .background(
                                        RowHighlight(
                                            isSelected: index == viewModel.applicationSelectionIndex
                                        )
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.title)
                            .accessibilityLabel(item.title)
                        }
                    }
                }
                .padding(.horizontal, AQDesign.Space.standard)
            }
        }
        .padding(.vertical, AQDesign.Space.compact)
    }
}

/// Raycast-style detail beside a list: a preview and an Information block,
/// each a raised card on the panel ground.
struct CatalogDetailPane: View {
    @Bindable var viewModel: QuickViewModel
    let item: LauncherCatalogItem
    @ScaledMetric(relativeTo: .body) private var screenHistoryTextMaxHeight: CGFloat = 150
    /// Clipboard image payload, loaded off-main (no disk IO in the body).
    @State private var previewPayload: ClipboardPayload?
    /// Thumbnail for a clipboard entry that is a reference to an image file on
    /// disk (a Finder/screenshot file URL), loaded off-main in the task.
    @State private var filePreviewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            preview
            informationGroup
            if let text = longText {
                textGroup(text)
            }
            Spacer(minLength: 0)
        }
        .padding(House.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
            previewPayload = nil
            filePreviewImage = nil
            if item.kind == .screenHistory, let frame = viewModel.screenHistory.frame(for: item) {
                await viewModel.screenHistory.loadOCRBoxes(for: frame)
            }
            if item.kind == .clipboard {
                if item.clipboardPayload?.kind == .image {
                    let loaded = await viewModel.fullClipboardPayload(for: item)
                    guard !Task.isCancelled else { return }
                    previewPayload = loaded
                } else if let urlString = item.clipboardPayload?.fileURLs.first {
                    let image = await Self.fileReferenceThumbnail(from: urlString)
                    guard !Task.isCancelled else { return }
                    filePreviewImage = image
                }
            }
        }
    }

    // MARK: - Groups

    private var informationGroup: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            groupLabel(ScreenHistoryAccessibilityPresentation.informationGroupName)
            VStack(spacing: AQDesign.Space.compact) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top, spacing: House.Spacing.sm) {
                        Text(row.0)
                            .font(detailFont)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        Spacer(minLength: House.Spacing.sm)
                        Text(row.1)
                            .font(detailFont)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(item.kind == .screenHistory ? 3 : 2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ScreenHistoryAccessibilityPresentation.informationGroupName)
    }

    private func textGroup(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            groupLabel(textTitle)
            ScrollView {
                Text(text)
                    .font(item.kind == .screenHistory ? .body.monospaced() : AQDesign.TypeToken.code)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(
                maxHeight: item.kind == .screenHistory
                    ? screenHistoryTextMaxHeight
                    : DetailMetrics.textMaxHeight
            )
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    /// The house section label. Screen History keeps Dynamic Type so its own
    /// text-size control still grows the pane.
    @ViewBuilder private func groupLabel(_ text: String) -> some View {
        if item.kind == .screenHistory {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(AQDesign.TypeToken.sectionTracking)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .accessibilityLabel(text)
        } else {
            SectionLabel(text: text)
        }
    }

    /// Row detail is 12 pt metadata, or Dynamic Type in Screen History.
    private var detailFont: Font {
        item.kind == .screenHistory ? .caption : AQDesign.TypeToken.metadata
    }

    // MARK: - Preview

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .screenshot:
            if let image = ScreenshotThumbnailCache.thumbnail(forPath: item.value) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: DetailMetrics.previewMaxHeight)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                AQDesign.ColorToken.panelStroke,
                                lineWidth: AQDesign.hairline
                            )
                    )
            } else {
                placeholderCard(symbol: nil, text: "No preview")
            }
        case .clipboard:
            if let payload = previewPayload ?? item.clipboardPayload,
               payload.kind == .image,
               let data = payload.imageData,
               let image = NSImage(data: data) {
                clipboardImagePreview(image)
            } else if let image = filePreviewImage {
                clipboardImagePreview(image)
            } else {
                ScrollView {
                    Text(item.value)
                        .font(AQDesign.TypeToken.code)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: DetailMetrics.previewMaxHeight)
                .padding(House.Spacing.sm)
                .raisedCard()
            }
        case .snippet:
            ScrollView {
                Text(item.value)
                    .font(AQDesign.TypeToken.code)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DetailMetrics.previewMaxHeight)
            .padding(House.Spacing.sm)
            .raisedCard()
        case .color:
            if let color = viewModel.color(for: item) {
                // The one place a colour is the content, not the chrome.
                RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                    .fill(Color(
                        .sRGB,
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        opacity: color.alpha
                    ))
                    .frame(height: DetailMetrics.previewHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                AQDesign.ColorToken.panelStroke,
                                lineWidth: AQDesign.hairline
                            )
                    )
                    .accessibilityLabel("\(color.name) swatch, \(color.hexString)")
            }
        case .quickLink:
            VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                HStack(spacing: AQDesign.Space.standard) {
                    IconTile {
                        Image(systemName: item.requiresInput ? "text.cursor" : "link")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(item.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.value)
                    .font(AQDesign.TypeToken.code)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(House.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard()
        case .screenHistory:
            if let frame = viewModel.screenHistory.frame(for: item) {
                ScreenHistoryMomentPreview(
                    frame: frame,
                    boxes: viewModel.screenHistory.ocrBoxes(for: frame),
                    accessibilityLabel: screenHistoryPreviewLabel(frame)
                )
            } else {
                placeholderCard(symbol: "film", text: "Image preview unavailable")
                    .accessibilityLabel("Screen moment preview unavailable")
            }
        default:
            EmptyView()
        }
    }

    /// A quiet raised block standing in for a preview that is not there.
    private func placeholderCard(symbol: String?, text: String) -> some View {
        VStack(spacing: AQDesign.Space.standard) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(AQDesign.TypeToken.caption)
        .foregroundStyle(AQDesign.ColorToken.textTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: DetailMetrics.previewHeight)
        .raisedCard()
    }

    /// The clipboard detail preview card: a fitted image inside a rounded,
    /// stroked card. Shared by inline image payloads and file-reference
    /// thumbnails so both render identically.
    private func clipboardImagePreview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: DetailMetrics.previewMaxHeight)
            .clipShape(
                RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        AQDesign.ColorToken.panelStroke,
                        lineWidth: AQDesign.hairline
                    )
            )
    }

    /// Off-main decode of a clipboard file reference's image bytes for the
    /// detail preview. Reads the first file URL that is a supported image on
    /// disk and returns a downscaled NSImage; returns nil for a non-image file
    /// or a missing/unreadable file so the row falls back to the text card.
    nonisolated private static func fileReferenceThumbnail(from urlString: String) async -> NSImage? {
        guard let path = ClipboardFileReference.localFilePath(from: urlString),
              ClipboardFileReference.isImageFile(atPath: path) else { return nil }
        let cgImage = await Task.detached(priority: .utility) {
            ScreenshotTextIndex.downsampledImage(atPath: path, maximumPixels: 640)
        }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var rows: [(String, String)] {
        switch item.kind {
        case .screenshot:
            var list: [(String, String)] = [("Name", (item.value as NSString).lastPathComponent)]
            if let size = ScreenshotThumbnailCache.pixelSize(forPath: item.value) {
                list.append(("Dimensions", "\(Int(size.width)) × \(Int(size.height))"))
            }
            list.append(("Size", ScreenshotLibrary.sizeLabel(ScreenshotTextIndex.byteCount(of: item.value))))
            if let date = item.capturedAt {
                list.append(("Captured", date.formatted(date: .abbreviated, time: .shortened)))
            }
            if item.isPinned { list.append(("Pinned", "Yes")) }
            return list
        case .clipboard:
            if let payload = item.clipboardPayload, payload.kind == .image {
                var list: [(String, String)] = [("Type", "Image")]
                if let w = payload.imageWidth, let h = payload.imageHeight {
                    list.append(("Dimensions", "\(w) × \(h)"))
                }
                list.append(("Copied", item.detail.replacingOccurrences(of: "Pinned · ", with: "")))
                if item.isPinned { list.append(("Pinned", "Yes")) }
                return list
            }
            if let payload = item.clipboardPayload, payload.kind == .fileURL {
                var list: [(String, String)] = [("Type", "File")]
                if !payload.fileURLs.isEmpty {
                    let firstName = ClipboardFileReference.fileName(from: payload.fileURLs.first ?? "") ?? ""
                    if payload.fileURLs.count > 1 {
                        list.append(("Files", "\(payload.fileURLs.count)"))
                        list.append(("First", firstName))
                    } else {
                        list.append(("Name", firstName))
                    }
                }
                list.append(("Copied", item.detail.replacingOccurrences(of: "Pinned · ", with: "")))
                if item.isPinned { list.append(("Pinned", "Yes")) }
                return list
            }
            let words = item.value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            var list: [(String, String)] = [
                ("Characters", "\(item.value.count)"),
                ("Words", "\(words)"),
                ("Copied", item.detail.replacingOccurrences(of: "Pinned · ", with: "")),
            ]
            if item.isPinned { list.append(("Pinned", "Yes")) }
            if ItemActionCatalog.looksLikeURL(item.value) { list.append(("Type", "Link")) }
            return list
        case .snippet:
            let words = item.value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let lines = item.value.split(separator: "\n", omittingEmptySubsequences: false).count
            var list: [(String, String)] = [
                ("Characters", "\(item.value.count)"),
                ("Words", "\(words)"),
            ]
            if lines > 1 { list.append(("Lines", "\(lines)")) }
            if !item.detail.isEmpty { list.append(("Source", item.detail)) }
            if item.isPinned { list.append(("Pinned", "Yes")) }
            return list
        case .color:
            guard let color = viewModel.color(for: item) else { return [] }
            var list: [(String, String)] = color.allStrings.map { ($0.0.title, $0.1) }
            list.append(("Name", color.name))
            if let date = item.capturedAt {
                list.append(("Picked", date.formatted(date: .abbreviated, time: .shortened)))
            }
            if item.isPinned { list.append(("Pinned", "Yes")) }
            return list
        case .quickLink:
            let host = URLComponents(string: item.value.replacingOccurrences(
                of: "{{input}}", with: "input"
            ))?.host
            var list: [(String, String)] = [("Type", item.requiresInput ? "Smart Link" : "Link")]
            if let host { list.append(("Site", host)) }
            list.append(("Characters", "\(item.value.count)"))
            if item.requiresInput { list.append(("Input", "Required")) }
            // The row subtitle is usually the host; only show it when it adds something.
            if !item.detail.isEmpty, item.detail != host { list.append(("Source", item.detail)) }
            if item.isPinned { list.append(("Pinned", "Yes")) }
            return list
        case .screenHistory:
            guard let frame = viewModel.screenHistory.frame(for: item) else { return [] }
            var list: [(String, String)] = [
                ("Seen", frame.capturedAt.formatted(date: .abbreviated, time: .shortened)),
                ("Application", frame.application ?? "Unknown"),
                ("Source", frame.source == .owned ? "Owned" : "Coast"),
            ]
            if let title = frame.windowTitle { list.append(("Window", title)) }
            if let domain = frame.domain { list.append(("Site", domain)) }
            return list
        default:
            return []
        }
    }

    private var textTitle: String {
        switch item.kind {
        case .screenshot: "Text in image"
        case .screenHistory: "Text seen"
        default: ""
        }
    }

    private var longText: String? {
        if item.kind == .screenHistory {
            guard let frame = viewModel.screenHistory.frame(for: item) else { return nil }
            let text = frame.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "No text found" : String(text.prefix(4_000))
        }
        guard item.kind == .screenshot else { return nil }
        if let text = viewModel.screenshotText(for: item) {
            return text.isEmpty ? "No text found" : text
        }
        return viewModel.screenshotIndexProgress.isRunning ? "Reading text…" : "Not read yet"
    }

    private func screenHistoryPreviewLabel(_ frame: ScreenHistoryFrame) -> String {
        let app = frame.application ?? "unknown application"
        let text = frame.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = text.isEmpty ? "No text was recognized" : String(text.prefix(500))
        return "Screen moment from \(app). \(alternative)"
    }
}

private struct ScreenHistoryMomentPreview: View {
    let frame: ScreenHistoryFrame
    let boxes: [ScreenHistoryOCRBox]
    let accessibilityLabel: String
    @State private var image: NSImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                    ScreenHistoryOCRBoxOverlay(
                        imageSize: image.size,
                        displayGeometry: frame.displayGeometry,
                        boxes: boxes
                    )
                }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: DetailMetrics.previewHeight,
                        maxHeight: DetailMetrics.previewMaxHeight
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                AQDesign.ColorToken.panelStroke,
                                lineWidth: AQDesign.hairline
                            )
                    )
                    .accessibilityLabel(accessibilityLabel)
            } else {
                VStack(spacing: AQDesign.Space.standard) {
                    if !finished { ProgressView().controlSize(.small) }
                    Image(systemName: finished ? "film" : "clock")
                    Text(finished ? "Image preview unavailable" : "Loading local preview…")
                }
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: DetailMetrics.previewHeight)
                .raisedCard()
                .accessibilityLabel(
                    finished ? "Screen moment preview unavailable" : "Loading screen moment preview"
                )
            }
        }
        .task(id: "\(frame.source.rawValue):\(frame.sourceIdentifier):\(frame.contentHash)") {
            image = await ScreenHistoryMediaPreviewService.image(for: frame)
            finished = true
        }
    }
}

private struct ScreenHistoryOCRBoxOverlay: View {
    let imageSize: NSSize
    let displayGeometry: ScreenHistoryDisplayGeometry?
    let boxes: [ScreenHistoryOCRBox]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(boxes.prefix(300))) { box in
                    let rect = ScreenHistoryOCRBoxLayout.rect(
                        for: box,
                        imageSize: imageSize,
                        displayGeometry: displayGeometry,
                        containerSize: geometry.size
                    )
                    // A text bounding box is a square mark, not a control:
                    // ink at secondary strength, one hairline wide.
                    Rectangle()
                        .stroke(AQDesign.ColorToken.textSecondary, lineWidth: AQDesign.hairline)
                        .frame(
                            width: rect.width,
                            height: rect.height
                        )
                        .offset(
                            x: rect.minX,
                            y: rect.minY
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

enum ScreenHistoryOCRBoxLayout {
    static func rect(
        for box: ScreenHistoryOCRBox,
        imageSize: CGSize,
        displayGeometry: ScreenHistoryDisplayGeometry?,
        containerSize: CGSize
    ) -> CGRect {
        let sourceWidth = max(1, displayGeometry?.width ?? imageSize.width)
        let sourceHeight = max(1, displayGeometry?.height ?? imageSize.height)
        let scale = min(
            containerSize.width / sourceWidth,
            containerSize.height / sourceHeight
        )
        let fittedWidth = sourceWidth * scale
        let fittedHeight = sourceHeight * scale
        let xOffset = (containerSize.width - fittedWidth) / 2
        let yOffset = (containerSize.height - fittedHeight) / 2
        return CGRect(
            x: xOffset + (box.x - (displayGeometry?.x ?? 0)) * scale,
            y: yOffset + (box.y - (displayGeometry?.y ?? 0)) * scale,
            width: max(1, box.width * scale),
            height: max(1, box.height * scale)
        )
    }
}
