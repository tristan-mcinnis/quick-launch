import SwiftUI
import Combine
import HouseDesign

/// One launcher row: the 26 pt icon tile, `label` title, `meta` detail,
/// and the trailing hotkey, status light, or type. The Quick AI surface
/// draws Recent Chats with the same row.
struct LauncherResultRow: View {
    let result: LauncherSearchResult
    let isSelected: Bool
    var hotkey: ActionHotkey? = nil
    var position: Int? = nil
    var total: Int? = nil
    var showsTypeLabel = true

    var body: some View {
        HStack(spacing: AQDesign.Space.row) {
            icon
            if let chatSnippet {
                ChatSnippetRowText(title: title, detail: detail, snippet: chatSnippet)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AQDesign.Space.standard) {
                    Text(title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            // A snippet row runs its own count and time to the trailing edge.
            if chatSnippet == nil { Spacer(minLength: AQDesign.Space.standard) }
            if case .item(let item) = result, item.isPinned {
                Image(systemName: "pin.fill")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityLabel("Pinned")
            }
            if let hotkey {
                KeyCapGroup(keys: hotkey.keyCaps)
                    .accessibilityLabel("Hotkey \(hotkey.displayName)")
            } else if let statusLight {
                StatusLightLabel(light: statusLight)
            } else if chatSnippet == nil, showsTypeLabel {
                Text(resultType)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: AQDesign.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    /// Every row glyph sits in the same 26 pt tile, so titles line up
    /// whatever the symbol or icon width.
    @ViewBuilder private var icon: some View {
        switch result {
        case .application(let application):
            IconTile(fillsTile: true) {
                Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                    .resizable().scaledToFit()
            }
        case .catalog(let scope, _):
            IconTile {
                Image(systemName: scope.systemImage)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
        case .item(let item):
            if item.kind == .emoji {
                IconTile {
                    Text(item.value).font(AQDesign.TypeToken.body)
                }
            } else if item.kind == .screenshot,
                      let thumbnail = ScreenshotThumbnailCache.thumbnail(forPath: item.value, maximumPixels: 96) {
                IconTile(fillsTile: true) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                }
            } else {
                IconTile {
                    Image(systemName: item.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                }
            }
        }
    }

    private var title: String {
        switch result {
        case .application(let app): app.name
        case .catalog(let scope, _): scope.title
        case .item(let item): item.title
        }
    }
    private var statusLight: LauncherStatusLight? {
        if case .item(let item) = result { return item.statusLight }
        return nil
    }
    /// A chat a search found by its text: the row shows where.
    private var chatSnippet: ChatSnippet? {
        if case .item(let item) = result { return item.chatSnippet }
        return nil
    }
    private var detail: String {
        switch result {
        case .application: "Application"
        case .catalog(_, let count): count > 0 ? QuickViewModel.catalogCountDetail(count) : ""
        case .item(let item): item.detail
        }
    }
    private var action: String {
        switch result {
        case .application: "Open"
        case .catalog: "Browse"
        case .item(let item): item.defaultActionTitle
        }
    }

    private var resultType: String { Self.typeLabel(for: result) }

    /// The `meta` type label on a row's right edge. A chat row reads "Chat";
    /// "AI Chat" names only the window.
    static func typeLabel(for result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Application"
        case .catalog: "Catalog"
        case .item(let item):
            switch item.kind {
            case .application: "Application"
            case .snippet: "Snippet"
            case .quickLink: "Quicklink"
            case .clipboard: "Clipboard"
            case .emoji: "Emoji"
            case .screenshot: "Screenshot"
            case .conversation: "Chat"
            case .askAI: "AI Command"
            case .folder: "Folder"
            case .answer: item.isInlineTranslation ? "Translate" : "Answer"
            case .command: "Command"
            }
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        if let position, let total { parts.append("\(position) of \(total)") }
        if isSelected { parts.append("\(action) with Return") }
        return parts.joined(separator: ", ")
    }
}
