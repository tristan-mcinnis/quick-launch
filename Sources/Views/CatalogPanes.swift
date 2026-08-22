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
                                    .font(.system(size: 26))
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
                                                    ? AQDesign.ColorToken.accent.opacity(0.6)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            Text("Information")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.1)
                            .font(AQDesign.TypeToken.caption)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            if let text = longText {
                Text(textTitle)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .clipboard:
            ScrollView {
                Text(item.value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(AQDesign.ColorToken.keyCapFill))
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
        default:
            return []
        }
    }

    private var textTitle: String { item.kind == .screenshot ? "Text in image" : "" }

    private var longText: String? {
        guard item.kind == .screenshot else { return nil }
        if let text = viewModel.screenshotText(for: item) {
            return text.isEmpty ? "No text found" : text
        }
        return viewModel.screenshotIndexProgress.isRunning ? "Reading text…" : "Not read yet"
    }
}
