import AppKit
import SwiftUI
import HouseDesign

/// What one Markdown table block carries: header cells, body rows, and column
/// alignments extracted from the AST so tables draw as aligned Slate grids
/// instead of tab-separated prose.
struct MarkdownTableContent: Equatable, Sendable {
    enum ColumnAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing

        var textAlignment: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    /// Header cell inline-markdown strings, in column order.
    let headers: [String]
    /// Body rows of inline-markdown strings, each padded/trimmed to column count.
    let rows: [[String]]
    /// Column alignments matching `headers`.
    let alignments: [ColumnAlignment]

    var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    /// Plain text representation for Find in Chat and accessibility.
    var plainText: String {
        var lines: [String] = []
        if !headers.isEmpty {
            lines.append(headers.map(Self.stripInlineMarkdown).joined(separator: " | "))
        }
        for row in rows {
            lines.append(row.map(Self.stripInlineMarkdown).joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        let cols = columnCount
        let bodyRows = rows.count
        return "Table, \(cols) \(cols == 1 ? "column" : "columns"), \(bodyRows) \(bodyRows == 1 ? "row" : "rows")"
    }

    func alignment(for column: Int) -> ColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// Renders inline markdown (bold, italic, inline code, links) for a single cell.
    static func inlineAttributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }

    /// Strips basic inline markdown markers for plain-text search.
    static func stripInlineMarkdown(_ raw: String) -> String {
        String(inlineAttributed(raw).characters)
    }
}

/// Measurements for `MarkdownTableView`, shared with `MarkdownRenderer.measuredHeight`.
enum MarkdownTableMetrics {
    static let cornerRadius: CGFloat = AQDesign.fieldCornerRadius
    static let cellHorizontalPadding: CGFloat = House.Spacing.sm
    static let cellVerticalPadding: CGFloat = House.Spacing.xs
    static let headerRowEstimate: CGFloat = House.Control.row
    static let bodyRowEstimate: CGFloat = House.Control.row

    static func height(of content: MarkdownTableContent, width: CGFloat) -> CGFloat {
        let headerCount: CGFloat = content.headers.isEmpty ? 0 : 1
        let bodyCount = CGFloat(content.rows.count)
        let dividers = max(0, headerCount + bodyCount - 1) * House.hairline
        return headerCount * headerRowEstimate + bodyCount * bodyRowEstimate + dividers + House.Spacing.xxs * 2
    }
}

/// A Slate-styled Markdown table card: subtle header well, hairline dividers,
/// aligned columns, and horizontal scrolling for wide tables.
struct MarkdownTableView: View {
    let content: MarkdownTableContent
    var findRanges: [TextRange] = []
    var findCurrent: TextRange? = nil
    @State private var headerHeight: CGFloat = 0

    /// Tables with 4+ columns scroll horizontally so cells stay readable
    /// instead of squeezing into narrow single-word slivers.
    private var scrollsHorizontally: Bool {
        content.columnCount >= 4
    }

    /// Column 0 hugs its text when it holds short row labels (like "Lineup"
    /// or "Access") beside wider value columns, so it does not hog a third
    /// of the table width.
    private func hugsContent(column: Int) -> Bool {
        guard !scrollsHorizontally, column == 0, content.columnCount >= 2 else { return false }
        let headerLen = content.headers.first.map { MarkdownTableContent.stripInlineMarkdown($0).count } ?? 0
        let maxBodyLen = content.rows.compactMap { $0.first }
            .map { MarkdownTableContent.stripInlineMarkdown($0).count }
            .max() ?? 0
        return max(headerLen, maxBodyLen) <= 22
    }

    var body: some View {
        Group {
            if scrollsHorizontally {
                ScrollView(.horizontal, showsIndicators: true) {
                    tableGrid
                        .frame(minWidth: House.Layout.quickAIAnswerMaxWidth - House.Spacing.xs, alignment: .leading)
                }
            } else {
                tableGrid
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MarkdownTableMetrics.cornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: MarkdownTableMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarkdownTableMetrics.cornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
        )
        .padding(.vertical, House.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilityLabel)
    }

    private var tableGrid: some View {
        let colCount = content.columnCount
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !content.headers.isEmpty {
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        let text = col < content.headers.count ? content.headers[col] : ""
                        let align = content.alignment(for: col)
                        cellText(text, isHeader: true, alignment: align, hugs: hugsContent(column: col))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if height > headerHeight { headerHeight = height }
                            }
                    }
                }

                if !content.rows.isEmpty {
                    HouseDivider()
                        .gridCellUnsizedAxes(.horizontal)
                }
            }

            ForEach(Array(content.rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    HouseDivider()
                        .gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        let text = col < row.count ? row[col] : ""
                        let align = content.alignment(for: col)
                        cellText(text, isHeader: false, alignment: align, hugs: hugsContent(column: col))
                    }
                }
            }
        }
        .background(alignment: .top) {
            if !content.headers.isEmpty, headerHeight > 0 {
                AQDesign.ColorToken.well
                    .frame(height: headerHeight)
            }
        }
    }

    private func cellText(
        _ raw: String,
        isHeader: Bool,
        alignment: MarkdownTableContent.ColumnAlignment,
        hugs: Bool
    ) -> some View {
        Text(MarkdownTableContent.inlineAttributed(raw))
            .font(isHeader ? AQDesign.TypeToken.label : AQDesign.TypeToken.body)
            .foregroundStyle(isHeader ? AQDesign.ColorToken.textSecondary : AQDesign.ColorToken.textPrimary)
            .multilineTextAlignment(alignment.textAlignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: hugs, vertical: true)
            .frame(
                maxWidth: hugs ? nil : (scrollsHorizontally ? House.Layout.chatRail : .infinity),
                alignment: alignment.frameAlignment
            )
            .padding(.horizontal, MarkdownTableMetrics.cellHorizontalPadding)
            .padding(.vertical, MarkdownTableMetrics.cellVerticalPadding)
    }
}
