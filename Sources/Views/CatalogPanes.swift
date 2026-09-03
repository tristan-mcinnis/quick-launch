import AppKit
import SwiftUI

/// Emoji & Symbols as a grid: Frequently Used first, then everything that
/// matches. Arrow keys move the highlight; Return pastes, ⌘↩ copies.
struct EmojiGridView: View {
    @Bindable var viewModel: QuickViewModel
    static let columns = 9
    static let cellHeight: CGFloat = 52
    static let headerHeight: CGFloat = 24

    var body: some View {
        let items = viewModel.launcherMatches
        let sections = viewModel.gridSections
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                HStack(spacing: 6) {
                    Text(section.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                    Text("\(section.range.count)")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(height: Self.headerHeight)
                .padding(.horizontal, 12)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: Self.columns),
                    spacing: 4
                ) {
                    ForEach(section.range, id: \.self) { index in
                        if case .item(let item) = items[index] {
                            Button {
                                viewModel.applicationSelectionIndex = index
                                Task { await viewModel.performLauncherResult(items[index]) }
                            } label: {
                                Text(item.value)
                                    .font(.largeTitle)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.cellHeight - 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                                            .fill(index == viewModel.applicationSelectionIndex
                                                  ? AQDesign.ColorToken.selectionFill
                                                  : AQDesign.ColorToken.keyCapFill.opacity(0.6))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                                            .strokeBorder(
                                                index == viewModel.applicationSelectionIndex
                                                    ? AQDesign.ColorToken.emphasis.opacity(0.6)
                                                    : .clear,
                                                lineWidth: 1
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
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Raycast-style detail beside a list: a preview and an Information block.
struct CatalogDetailPane: View {
    @Bindable var viewModel: QuickViewModel
    let item: LauncherCatalogItem
    @ScaledMetric(relativeTo: .body) private var screenHistoryTextMaxHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 6) {
                Text("Information")
                    .font(item.kind == .screenHistory ? .caption.weight(.semibold) : AQDesign.TypeToken.label)
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .top) {
                            Text(row.0)
                                .font(item.kind == .screenHistory ? .caption : AQDesign.TypeToken.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(row.1)
                                .font(item.kind == .screenHistory ? .caption : AQDesign.TypeToken.caption)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(item.kind == .screenHistory ? 3 : 2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ScreenHistoryAccessibilityPresentation.informationGroupName)
            if let text = longText {
                Text(textTitle)
                    .font(item.kind == .screenHistory ? .caption.weight(.semibold) : AQDesign.TypeToken.label)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(text)
                        .font(item.kind == .screenHistory ? .body.monospaced() : .system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: item.kind == .screenHistory ? screenHistoryTextMaxHeight : 120)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
            guard item.kind == .screenHistory,
                  let frame = viewModel.screenHistory.frame(for: item) else { return }
            await viewModel.screenHistory.loadOCRBoxes(for: frame)
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .screenshot:
            if let image = ScreenshotThumbnailCache.thumbnail(forPath: item.value) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AQDesign.ColorToken.panelStroke))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AQDesign.ColorToken.keyCapFill)
                    .frame(height: 120)
                    .overlay(Text("No preview").font(AQDesign.TypeToken.caption).foregroundStyle(.secondary))
            }
        case .clipboard, .snippet:
            ScrollView {
                Text(item.value)
                    .font(AQDesign.TypeToken.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(AQDesign.ColorToken.keyCapFill))
        case .color:
            if let color = viewModel.color(for: item) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(
                        .sRGB,
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        opacity: color.alpha
                    ))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AQDesign.ColorToken.panelStroke)
                    )
                    .accessibilityLabel("\(color.name) swatch, \(color.hexString)")
            }
        case .quickLink:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: item.requiresInput ? "text.cursor" : "link")
                        .foregroundStyle(AQDesign.ColorToken.emphasis)
                    Text(item.title)
                        .font(AQDesign.TypeToken.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.value)
                    .font(AQDesign.TypeToken.code)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(AQDesign.ColorToken.keyCapFill))
        case .screenHistory:
            if let frame = viewModel.screenHistory.frame(for: item) {
                ScreenHistoryMomentPreview(
                    frame: frame,
                    boxes: viewModel.screenHistory.ocrBoxes(for: frame),
                    accessibilityLabel: screenHistoryPreviewLabel(frame)
                )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AQDesign.ColorToken.keyCapFill)
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "film")
                            Text("Image preview unavailable")
                        }
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    )
                    .accessibilityLabel("Screen moment preview unavailable")
            }
        default:
            EmptyView()
        }
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
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AQDesign.ColorToken.panelStroke))
                    .accessibilityLabel(accessibilityLabel)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AQDesign.ColorToken.keyCapFill)
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            if !finished { ProgressView().controlSize(.small) }
                            Image(systemName: finished ? "film" : "clock")
                            Text(finished ? "Image preview unavailable" : "Loading local preview…")
                        }
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    )
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
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(AQDesign.ColorToken.emphasis.opacity(0.55), lineWidth: 1)
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
