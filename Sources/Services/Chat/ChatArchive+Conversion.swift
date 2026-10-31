import Foundation
import HouseChatCore

extension ChatArchive {
    // MARK: - Conversion

    /// One legacy conversation as a durable record, preserving every
    /// Quick-Launch-only field in the namespaced `appPayload`.
    static func record(for conversation: QuickConversation) -> ConversationRecord {
        var payload = AppPayload(namespace: namespace)
        payload["providerID"] = .string(conversation.providerID.uuidString)
        payload["model"] = .string(conversation.model)
        if let customTitle = conversation.customTitle { payload["customTitle"] = .string(customTitle) }
        if let titleSource = conversation.titleSource { payload["titleSource"] = .string(titleSource) }
        payload["isPinned"] = .bool(conversation.isPinned)
        if let enabledTools = conversation.enabledTools {
            payload["enabledTools"] = .array(enabledTools.map { .string($0.rawValue) }.sorted { lhs, rhs in
                if case .string(let a) = lhs, case .string(let b) = rhs { return a < b }
                return false
            })
        }
        if let assistantID = conversation.assistantID {
            payload["assistantID"] = .string(assistantID.uuidString)
        }

        return ConversationRecord(
            id: conversation.id.uuidString,
            surface: surface,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            turns: conversation.messages.map(turn(for:)),
            appPayload: payload
        )
    }

    /// One legacy message as a turn, keeping the tool records in the turn's own
    /// namespaced payload.
    static func turn(for message: QuickMessage) -> TurnRecord {
        var payload = AppPayload(namespace: namespace)
        if let tools = message.toolRecords {
            payload["toolRecords"] = jsonValue(tools)
        }
        return TurnRecord(
            id: message.id.uuidString,
            role: TurnRole(rawValue: message.role.rawValue) ?? .unknown,
            text: message.content,
            attachments: (message.attachments ?? []).map(attachment(for:)),
            appPayload: payload.isEmpty ? nil : payload
        )
    }

    /// One legacy attachment reference as a record. No bytes are invented:
    /// `artifacts` is nil, so the archive reports the bytes as missing.
    static func attachment(for reference: ChatAttachmentRef) -> AttachmentRecord {
        AttachmentRecord(
            id: reference.id.uuidString,
            kind: AttachmentKind(rawValue: reference.kind.rawValue) ?? .other,
            kindRaw: reference.kind.rawValue,
            name: reference.name,
            byteCount: reference.byteCount,
            pageCount: reference.pageCount,
            characterCount: reference.characterCount,
            truncation: truncation(for: reference.truncation),
            contentHash: reference.contentHash,
            extractorVersion: reference.extractorVersion,
            path: reference.path,
            url: reference.url,
            pixelWidth: reference.pixelWidth,
            pixelHeight: reference.pixelHeight,
            addedAt: reference.addedAt,
            artifacts: nil
        )
    }

    static func truncation(for truncation: AttachmentTruncation?) -> TextTruncation? {
        guard let truncation else { return nil }
        return TextTruncation(
            keptCharacters: truncation.keptCharacters,
            totalCharacters: truncation.totalCharacters,
            unit: truncation.unit.flatMap { DocumentUnit(rawValue: $0.rawValue) },
            keptUnits: truncation.keptUnits,
            totalUnits: truncation.totalUnits
        )
    }

    // MARK: - Reverse conversion (projection rebuild)

    static func legacyConversation(for record: ConversationRecord) -> QuickConversation? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        let payload = record.appPayload?.namespace == namespace ? record.appPayload : nil
        guard let providerID = payload?["providerID"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        let model = payload?["model"]?.stringValue ?? ""
        let enabledTools: Set<ChatToolKind>? = payload?["enabledTools"]?.arrayValue.map { values in
            Set(values.compactMap { $0.stringValue.flatMap(ChatToolKind.init(rawValue:)) })
        }
        let assistantID = payload?["assistantID"]?.stringValue.flatMap(UUID.init(uuidString:))
        return QuickConversation(
            id: id,
            createdAt: record.createdAt ?? Date(),
            updatedAt: record.updatedAt ?? Date(),
            providerID: providerID,
            model: model,
            messages: record.turns.compactMap(legacyMessage(for:)),
            customTitle: payload?["customTitle"]?.stringValue,
            titleSource: payload?["titleSource"]?.stringValue,
            isPinned: payload?["isPinned"]?.boolValue ?? false,
            enabledTools: enabledTools,
            assistantID: assistantID
        )
    }

    static func legacyMessage(for turn: TurnRecord) -> QuickMessage? {
        guard let id = UUID(uuidString: turn.id),
              let role = QuickMessage.Role(rawValue: turn.role.rawValue)
        else { return nil }
        let payload = turn.appPayload?.namespace == namespace ? turn.appPayload : nil
        return QuickMessage(
            id: id,
            role: role,
            content: turn.text,
            toolRecords: payload?["toolRecords"].flatMap { Self.decodeValue($0, as: [ChatToolRecord].self) },
            attachments: turn.attachments.isEmpty ? nil : turn.attachments.map(legacyReference(for:))
        )
    }

    static func legacyReference(for record: AttachmentRecord) -> ChatAttachmentRef {
        ChatAttachmentRef(
            id: UUID(uuidString: record.id) ?? UUID(),
            kind: ChatAttachmentKind(rawValue: record.kindRaw ?? record.kind.rawValue) ?? .text,
            name: record.name,
            byteCount: record.byteCount,
            pageCount: record.pageCount,
            characterCount: record.characterCount,
            truncation: record.truncation.map { trunc in
                AttachmentTruncation(
                    keptCharacters: trunc.keptCharacters,
                    totalCharacters: trunc.totalCharacters,
                    unit: trunc.unit.flatMap { AttachmentTruncation.Unit(rawValue: $0.rawValue) },
                    keptUnits: trunc.keptUnits,
                    totalUnits: trunc.totalUnits
                )
            },
            contentHash: record.contentHash,
            extractorVersion: record.extractorVersion,
            path: record.path,
            url: record.url,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            addedAt: record.addedAt ?? Date()
        )
    }

    // MARK: - Artifacts for a turn

    /// The bytes this turn archives and the snapshot refs its receipt should
    /// carry, built from what the reader already handed over.
    ///
    /// **No source path is read here.** A file that changed or was deleted
    /// after it was read cannot defeat the snapshot: the bytes come from
    /// `AttachmentContent`, and when the reader did not keep them, the role
    /// stays missing rather than being faked from a normalized image.
    ///
    /// A document the shared extractor read is stored behind the versioned
    /// `ExtractionArtifact` header, so the structured sections and locations
    /// survive for a resume. Links and selections store plain UTF-8 text.
    static func prepareArtifacts(
        for contents: [AttachmentContent],
        requestSnapshot: Data? = nil,
        requestSnapshotKind: String? = nil
    ) -> (artifacts: [PendingArtifact], snapshotRefs: [AttachmentSnapshotRef]) {
        var artifacts: [PendingArtifact] = []
        var refs: [AttachmentSnapshotRef] = []

        for (index, content) in contents.enumerated() {
            let ref = content.ref
            let attachmentID = ref.id.uuidString

            if let original = content.originalBytes,
               ref.contentHash == nil || SHA256Digest.hex(original) == ref.contentHash {
                artifacts.append(PendingArtifact(
                    role: .original,
                    data: original,
                    fileExtension: fileExtension(for: ref),
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(original),
                    kind: "original",
                    byteCount: original.count
                ))
            }

            if let image = content.normalizedImage {
                artifacts.append(PendingArtifact(
                    role: .normalizedImage,
                    data: image.data,
                    fileExtension: image.mimeType == "image/jpeg" ? "jpg" : "png",
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(image.data),
                    kind: "normalizedImage",
                    byteCount: image.data.count
                ))
            }

            if let extraction = extractionArtifact(for: content) {
                artifacts.append(PendingArtifact(
                    role: .extractedText,
                    data: extraction.data,
                    fileExtension: extraction.fileExtension,
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(extraction.data),
                    kind: extraction.kind,
                    byteCount: extraction.data.count,
                    characterCount: extraction.characterCount
                ))
            }
        }

        if let snapshot = requestSnapshot, !snapshot.isEmpty {
            artifacts.append(PendingArtifact(
                role: .requestSnapshot,
                data: snapshot,
                fileExtension: requestSnapshotKind ?? "json"
            ))
            refs.append(AttachmentSnapshotRef(
                snapshotData: snapshot,
                kind: requestSnapshotKind ?? "requestSnapshot"
            ))
        }
        return (artifacts, refs)
    }

    /// The one extraction artifact for a content: the versioned structured
    /// document when the shared reader produced one, plain text otherwise.
    /// Nil when there is neither.
    static func extractionArtifact(
        for content: AttachmentContent
    ) -> (data: Data, fileExtension: String, kind: String, characterCount: Int?)? {
        if let document = content.extractedDocument {
            guard let data = ExtractionArtifact.encode(document: document) else { return nil }
            return (
                data,
                "json",
                "extractedDocument",
                document.characterCount ?? content.text?.count
            )
        }
        guard let text = content.text, !text.isEmpty else { return nil }
        return (Data(text.utf8), "txt", "extractedText", text.count)
    }

    /// Compatibility shim for callers that only need the artifact list.
    static func pendingArtifacts(for contents: [AttachmentContent]) -> [PendingArtifact] {
        prepareArtifacts(for: contents).artifacts
    }

    /// The receipt written at Send. It already carries the snapshot hash of
    /// every byte this commit writes, so the reference scan sees them.
    static func receipt(for submission: TurnSubmission, attachmentRefs: [AttachmentSnapshotRef]) -> RequestReceipt {
        var receipt = RequestReceipt(
            id: submission.receiptID ?? UUID().uuidString,
            selection: submission.model,
            status: .pending,
            context: submission.context,
            attachmentRefs: attachmentRefs,
            toolRounds: submission.toolRounds,
            endpoint: submission.endpoint,
            startedAt: submission.startedAt ?? Date()
        )
        if let tools = submission.tools {
            receipt.extra["tools"] = .array(
                tools.map { .string($0.rawValue) }.sorted { lhs, rhs in
                    if case .string(let a) = lhs, case .string(let b) = rhs { return a < b }
                    return false
                }
            )
        }
        return receipt.sanitizedForStorage()
    }

    static func fileExtension(for ref: ChatAttachmentRef) -> String? {
        if let path = ref.path {
            let ext = URL(fileURLWithPath: path).pathExtension
            if !ext.isEmpty { return ext }
        }
        return ref.kind.rawValue
    }

    // MARK: - JSON helpers

    static func jsonValue<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? HouseChatCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    static func decodeValue<T: Decodable>(_ value: JSONValue, as type: T.Type) -> T? {
        guard let data = try? HouseChatCoding.makeEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
