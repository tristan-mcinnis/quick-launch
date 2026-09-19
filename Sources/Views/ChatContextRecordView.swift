import AppKit
import Foundation
import HouseChatCore
import SwiftUI

/// A read-only projection of one chat's durable archive record, for the
/// thread to draw: the receipt behind each answer and the material earlier
/// turns carry.
///
/// Nothing here writes. The view model owns the archive; this reads what it
/// already wrote through the archive's own presentation calls
/// (`load(id:)`, `retainedSources(conversationID:)`), so the thread can
/// never invent a route, a timing, or a retained file that is not on disk.
struct ChatArchiveProjection: Equatable {
    var record: ConversationRecord?
    /// Every archived source in the chat, with the roles that are missing.
    var sources: [RetainedSource] = []
    var usage: ChatArchiveUsage?
    /// Set when the chat has a record that could not be read at all.
    var loadFailure: String?

    static let unavailable = ChatArchiveProjection()

    /// Reads the open chat. A chat with no record is not an error: it has
    /// simply never been written, so there is nothing to show.
    @MainActor
    static func load(from archive: ChatArchive?, conversationID: UUID?) async -> ChatArchiveProjection {
        guard let archive, let conversationID else { return .unavailable }
        let id = conversationID.uuidString
        do {
            let record = try await archive.load(id: id)
            let sources = (try? await archive.retainedSources(conversationID: id)) ?? []
            let usage = try? await archive.usage()
            return ChatArchiveProjection(record: record, sources: sources, usage: usage, loadFailure: nil)
        } catch {
            return ChatArchiveProjection(loadFailure: "This chat is not in the archive.")
        }
    }

    /// One archived turn by the id the live message carries.
    func turn(_ id: UUID) -> TurnRecord? {
        record?.turns.first { $0.id == id.uuidString }
    }

    /// The question a turn answers: the nearest user turn before it.
    func question(before id: UUID) -> TurnRecord? {
        guard let turns = record?.turns,
              let index = turns.firstIndex(where: { $0.id == id.uuidString })
        else { return nil }
        return turns[..<index].last { $0.role == .user }
    }

    /// The archive's own view of one attachment, missing roles included.
    func source(_ attachmentID: String) -> RetainedSource? {
        sources.first { $0.attachment.id == attachmentID }
    }
}

/// One previous turn's material, as the archive holds it: the bytes when
/// they were kept, and an explicit "Missing" when they were not. A legacy
/// reference with no archived artifact never claims to be openable.
struct ChatRetainedMaterial: Identifiable, Equatable {
    enum Status: Equatable {
        case retained
        case partial
        case missing

        var label: String {
            switch self {
            case .retained: "Retained"
            case .partial: "Partial"
            case .missing: "Missing"
            }
        }
    }

    let id: String
    let name: String
    let status: Status
    let detail: String
    let original: ArtifactRef?
    let normalizedImage: ArtifactRef?
    let extractedText: ArtifactRef?

    var hasBytes: Bool { original != nil || normalizedImage != nil || extractedText != nil }

    /// The archive's own account of the attachment, missing roles included.
    init(source: RetainedSource) {
        let record = source.attachment
        id = record.id
        name = record.name
        original = source.original
        normalizedImage = source.normalizedImage
        extractedText = source.extractedText
        if !source.hasBytes {
            status = .missing
        } else if source.original == nil || record.truncation != nil || !source.damagedRoles.isEmpty {
            status = .partial
        } else {
            status = .retained
        }
        var parts = [Self.kindLabel(record)]
        if let byteCount = record.byteCount, byteCount > 0 {
            parts.append(byteCount.formatted(.byteCount(style: .file)))
        }
        if let characters = record.characterCount, characters > 0 {
            parts.append("\(characters.formatted()) characters")
        }
        if record.truncation != nil { parts.append("trimmed") }
        if !source.missingRoles.isEmpty {
            parts.append("no \(source.missingRoles.map(Self.roleLabel).joined(separator: ", "))")
        }
        if !source.damagedRoles.isEmpty {
            parts.append("\(source.damagedRoles.map(Self.roleLabel).joined(separator: ", ")) unreadable")
        }
        detail = parts.joined(separator: " · ")
    }

    /// The turn's own record, for a projection that has not read the
    /// archive's source list. The status is derived the same way, so the two
    /// paths never disagree about what is missing.
    init(record: AttachmentRecord) {
        let original = record.artifacts?.original
        let image = record.artifacts?.normalizedImage
        let text = record.artifacts?.extractedText
        var missing: [String] = []
        if original == nil { missing.append("original") }
        if image == nil { missing.append("normalizedImage") }
        if text == nil { missing.append("extractedText") }
        self.init(source: RetainedSource(
            attachment: record,
            original: original,
            normalizedImage: image,
            extractedText: text,
            missingRoles: missing
        ))
    }

    private static func roleLabel(_ role: String) -> String {
        switch role {
        case "original": "original file"
        case "normalizedImage": "image as sent"
        case "extractedText": "extracted text"
        default: role
        }
    }

    private static func kindLabel(_ record: AttachmentRecord) -> String {
        switch record.kind {
        case .pdf: "PDF"
        case .word: "Document"
        case .powerpoint: "Presentation"
        case .excel: "Spreadsheet"
        case .html: "Page"
        case .markdown: "Markdown"
        case .code: "Code"
        case .image: "Image"
        case .screenshot: "Screenshot"
        case .link: "Link"
        case .selection: "Selection"
        case .text: "Text"
        case .other: record.kindRaw?.capitalized ?? "File"
        }
    }
}

/// One answer's route, reasoning, reading and timings, reduced to lines the
/// thread can draw. Truthful at every step: a turn with no receipt says so
/// rather than borrowing the current settings.
struct ChatAnswerReceiptSummary: Equatable {
    var route: String
    var reasoning: String?
    var context: String
    var timings: String?
    var usage: String?
    var outcome: String?
    var materials: [ChatRetainedMaterial]
    var hasReceipt: Bool

    /// A turn the archive holds no receipt for.
    static let unrecorded = ChatAnswerReceiptSummary(
        route: "Not recorded",
        reasoning: nil,
        context: "This answer is not in the archive.",
        timings: nil,
        usage: nil,
        outcome: nil,
        materials: [],
        hasReceipt: false
    )

    init(
        route: String,
        reasoning: String?,
        context: String,
        timings: String?,
        usage: String?,
        outcome: String?,
        materials: [ChatRetainedMaterial],
        hasReceipt: Bool
    ) {
        self.route = route
        self.reasoning = reasoning
        self.context = context
        self.timings = timings
        self.usage = usage
        self.outcome = outcome
        self.materials = materials
        self.hasReceipt = hasReceipt
    }

    init(answer: TurnRecord, question: TurnRecord?, projection: ChatArchiveProjection) {
        let receipt = answer.request
        let selection = receipt?.selection ?? answer.model
        let chosen = selection?.chosen
        let effective = selection?.effective
        let used = effective.flatMap { $0.isEmpty ? nil : $0 } ?? chosen

        var routeParts: [String] = []
        if let provider = used?.provider, !provider.isEmpty { routeParts.append(provider) }
        if let model = used?.model, !model.isEmpty { routeParts.append(model) }
        if routeParts.isEmpty { routeParts.append("No route recorded") }
        // A swap is the one thing a route line must never hide.
        let fellBack = (chosen != nil && effective != nil && chosen != effective && !(effective?.isEmpty ?? true))
            ? " (fell back from \(chosen?.model ?? chosen?.provider ?? "another model"))"
            : ""
        let routeLine = routeParts.joined(separator: " · ") + fellBack

        let reasoningLine: String?
        if let thinking = used?.thinking, !thinking.isEmpty {
            reasoningLine = "Reasoning \(thinking)"
        } else if receipt != nil {
            reasoningLine = "Reasoning by provider default"
        } else {
            reasoningLine = nil
        }

        let contextLine: String
        if let context = receipt?.context {
            var parts: [String] = [context.scope?.scopeLabel ?? "No reading recorded"]
            if let source = context.sourceCharacters, let budget = context.budgetCharacters, budget > 0 {
                parts.append("\(source.formatted()) of \(budget.formatted()) characters")
            }
            if let labels = context.coverageLabels, !labels.isEmpty {
                parts.append("\(labels.count) chunk\(labels.count == 1 ? "" : "s")")
            }
            if context.complete == false { parts.append("partial") }
            if context.matched == false { parts.append("no match") }
            if let rationale = context.rationale, !rationale.isEmpty { parts.append(rationale) }
            contextLine = parts.joined(separator: " · ")
        } else {
            contextLine = receipt == nil ? "No reading recorded" : "No reading decision recorded"
        }

        let timingsLine: String?
        if let receipt {
            var parts: [String] = []
            if let total = receipt.timings.totalSeconds { parts.append(Self.duration(total)) }
            if let first = receipt.timings.firstTokenSeconds {
                parts.append("first token \(Self.duration(first))")
            }
            if let tool = receipt.timings.toolSeconds, tool > 0 { parts.append("tools \(Self.duration(tool))") }
            if let retrieval = receipt.timings.retrievalSeconds, retrieval > 0 {
                parts.append("retrieval \(Self.duration(retrieval))")
            }
            if let extraction = receipt.timings.extractionSeconds, extraction > 0 {
                parts.append("extraction \(Self.duration(extraction))")
            }
            timingsLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            timingsLine = nil
        }

        let usageLine: String?
        if let tokenUsage = receipt?.usage {
            var parts: [String] = []
            if let input = tokenUsage.inputTokens { parts.append("\(input.formatted()) in") }
            if let output = tokenUsage.outputTokens { parts.append("\(output.formatted()) out") }
            usageLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            usageLine = nil
        }

        let outcomeLine: String?
        let rawStatus = receipt?.status.rawValue
        if let rawStatus,
           rawStatus != RequestStatus.completed.rawValue,
           rawStatus != RequestStatus.unknown.rawValue {
            outcomeLine = receipt?.error.map { "\(rawStatus): \($0)" } ?? rawStatus.capitalized
        } else if let error = receipt?.error, !error.isEmpty {
            outcomeLine = error
        } else {
            outcomeLine = nil
        }

        self.init(
            route: routeLine,
            reasoning: reasoningLine,
            context: contextLine,
            timings: timingsLine,
            usage: usageLine,
            outcome: outcomeLine,
            materials: (question?.attachments ?? []).map { attachment in
                projection.source(attachment.id).map(ChatRetainedMaterial.init(source:))
                    ?? ChatRetainedMaterial(record: attachment)
            },
            hasReceipt: receipt != nil
        )
    }

    /// Seconds as a reader's duration: 0.80 s, 12.4 s, 1 m 04 s.
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.2f s", seconds) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%d m %02d s", whole / 60, whole % 60)
    }
}

private extension RetrievalScope {
    var scopeLabel: String {
        switch self {
        case .none: "No sources"
        case .currentSource: "Attached sources"
        case .history: "Earlier turns"
        case .currentSourceAndHistory: "Attached sources and earlier turns"
        }
    }
}

/// Opens and exports the bytes the archive kept for one material. Read-only:
/// a material with no archived artifact is refused with words rather than
/// re-read from the path it once came from.
@MainActor
enum ChatRetainedMaterialIO {
    static let noArchive = "The chat archive is unavailable."

    static func open(
        _ material: ChatRetainedMaterial,
        conversationID: String?,
        archive: ChatArchive?
    ) async -> String? {
        guard let role = preferredRole(material) else { return notRetained(material) }
        guard let conversationID else { return noArchive }
        guard let archive else { return noArchive }
        do {
            guard let data = try await archive.retainedBytes(
                conversationID: conversationID,
                attachmentID: material.id,
                role: role
            ) else { return notRetained(material) }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-launch-chat-assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(fileName(material, role))
            try data.write(to: file, options: .atomic)
            NSWorkspace.shared.open(file)
            return nil
        } catch {
            return "Could not open \(material.name): \(error.localizedDescription)"
        }
    }

    static func export(
        _ material: ChatRetainedMaterial,
        conversationID: String?,
        archive: ChatArchive?
    ) async -> String? {
        guard let role = preferredRole(material) else { return notRetained(material) }
        guard let conversationID else { return noArchive }
        guard let archive else { return noArchive }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(material, role)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        do {
            guard let data = try await archive.retainedBytes(
                conversationID: conversationID,
                attachmentID: material.id,
                role: role
            ) else { return notRetained(material) }
            try data.write(to: destination, options: .atomic)
            return "Exported \(panel.nameFieldStringValue)"
        } catch {
            return "Could not export \(material.name): \(error.localizedDescription)"
        }
    }

    /// The original bytes first, then the image as it was sent, then the
    /// extracted text.
    static func preferredRole(_ material: ChatRetainedMaterial) -> ArtifactRef.Kind? {
        if material.original != nil { return .original }
        if material.normalizedImage != nil { return .normalizedImage }
        if material.extractedText != nil { return .extractedText }
        return nil
    }

    static func notRetained(_ material: ChatRetainedMaterial) -> String {
        "\(material.name) was not retained, so there are no bytes to open."
    }

    private static func fileName(_ material: ChatRetainedMaterial, _ role: ArtifactRef.Kind) -> String {
        let ref = role == .original
            ? material.original
            : (role == .normalizedImage ? material.normalizedImage : material.extractedText)
        guard let ext = ref?.fileExtension, !ext.isEmpty else { return material.name }
        return material.name.lowercased().hasSuffix(".\(ext.lowercased())")
            ? material.name
            : "\(material.name).\(ext)"
    }
}

/// The compact answer detail under a turn: one line naming the route, the
/// reading and the time, opening to the full receipt and the material the
/// question carried. House chrome: a raised card at `Radius.lg`, ink tiers,
/// the danger token only for a material whose bytes are gone.
struct ChatAnswerContextRecord: View {
    let summary: ChatAnswerReceiptSummary
    /// Set when the archive itself could not be read.
    var archiveFailure: String? = nil
    var onOpen: ((ChatRetainedMaterial) async -> String?)? = nil
    var onExport: ((ChatRetainedMaterial) async -> String?)? = nil

    @State private var expanded: Bool
    @State private var actionNotice: String?

    init(
        summary: ChatAnswerReceiptSummary,
        archiveFailure: String? = nil,
        onOpen: ((ChatRetainedMaterial) async -> String?)? = nil,
        onExport: ((ChatRetainedMaterial) async -> String?)? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.summary = summary
        self.archiveFailure = archiveFailure
        self.onOpen = onOpen
        self.onExport = onExport
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            disclosure
            if expanded { detail }
            if let actionNotice {
                Text(actionNotice)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer detail")
    }

    private var disclosure: some View {
        Button {
            expanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: House.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(AQDesign.TypeToken.footnote.weight(.semibold))
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: House.Control.keyCap)
                        .accessibilityHidden(true)
                    Text(summary.route)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: House.Spacing.xs)
                    if let timings = summary.timings {
                        Text(timings)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                HStack(spacing: House.Spacing.xs) {
                    Text(summary.context)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, House.Control.keyCap + House.Spacing.xs)
                    Spacer(minLength: 0)
                    if !summary.materials.isEmpty {
                        Text("\(summary.materials.count) source\(summary.materials.count == 1 ? "" : "s")")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .fixedSize()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer detail")
        .accessibilityValue(expanded ? "Open" : "Closed")
        .accessibilityHint(expanded ? "Hide the route and sources" : "Show the route, timings and sources")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let archiveFailure {
                receiptRow("Archive", archiveFailure)
            }
            if !summary.hasReceipt {
                receiptRow("Receipt", "None saved for this answer.")
            }
            if let reasoning = summary.reasoning { receiptRow("Reasoning", reasoning) }
            receiptRow("Reading", summary.context)
            if let timings = summary.timings { receiptRow("Timing", timings) }
            if let usage = summary.usage { receiptRow("Usage", usage) }
            if let outcome = summary.outcome { receiptRow("Outcome", outcome) }
            if !summary.materials.isEmpty { materials }
        }
        .padding(House.Spacing.sm)
        .raisedCard(radius: House.Radius.lg, fill: AQDesign.ColorToken.raisedSurface)
        .houseShadow(AQDesign.Shadow.card)
        .padding(.leading, House.Control.keyCap + House.Spacing.xs)
    }

    private func receiptRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            Text(label)
                .font(AQDesign.TypeToken.section)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .frame(width: House.Spacing.xxxxl, alignment: .leading)
            Text(value)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var materials: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text("Sources")
                .font(AQDesign.TypeToken.section)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
            ForEach(summary.materials) { material in
                materialRow(material)
            }
        }
    }

    private func materialRow(_ material: ChatRetainedMaterial) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: material.status == .missing ? "exclamationmark.triangle" : "doc.text")
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(material.status == .missing
                    ? AQDesign.ColorToken.danger
                    : AQDesign.ColorToken.textTertiary)
                .frame(width: House.Control.keyCap)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(material.name)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(material.detail)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: House.Spacing.xs)
            Text(material.status.label)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(material.status == .missing
                    ? AQDesign.ColorToken.danger
                    : AQDesign.ColorToken.textTertiary)
                .fixedSize()
            if material.hasBytes {
                Button("Open") {
                    Task { actionNotice = await onOpen?(material) }
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityLabel("Open \(material.name)")
                Button("Export") {
                    Task { actionNotice = await onExport?(material) }
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityLabel("Export \(material.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(material.name), \(material.status.label), \(material.detail)")
    }
}
