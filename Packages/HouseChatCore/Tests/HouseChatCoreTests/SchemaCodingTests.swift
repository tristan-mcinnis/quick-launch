import Foundation
import Testing
@testable import HouseChatCore

@Suite("Chat schema coding")
struct SchemaCodingTests {
    @Test("A full conversation round trips through JSON")
    func roundTrip() throws {
        let record = Fixtures.conversation()
        let encoder = HouseChatCoding.makeEncoder(prettyPrinted: true)
        let data = try encoder.encode(record)
        let decoded = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)

        #expect(decoded == record)
        #expect(decoded.surface == .quickLaunch)
        #expect(decoded.turns.count == 2)
        #expect(decoded.turns[0].attachments.first?.kind == .pdf)
        #expect(decoded.turns[0].request?.selection?.chosen?.thinking == "medium")
        #expect(decoded.turns[0].request?.selection?.effective?.thinking == "high")
        #expect(decoded.turns[0].request?.toolRounds.first?.calls.first?.name == "search_vault")
        #expect(decoded.turns[0].request?.timings.retries == 0)
        #expect(decoded.turns[0].request?.usage?.totalTokens == 1_540)
        #expect(decoded.turns[1].model?.effective?.model == "deepseek-reasoner")
        #expect(decoded.sessionLinks.first?.id == "window-1")
        #expect(decoded.contentHashes == [String(repeating: "a", count: 64)])
    }

    @Test("A legacy record without optional metadata decodes; identity and content stay required")
    func legacyMinimal() throws {
        let json = #"{"id":"legacy-1","turns":[{"id":"t1","role":"user","text":"hi","attachments":[],"toolRounds":[],"sessionLinks":[]}]}"#
        let record = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: Data(json.utf8))

        #expect(record.id == "legacy-1")
        #expect(record.schemaVersion == HouseChatCoding.schemaVersion)
        #expect(record.surface == nil)
        #expect(record.title == nil)
        #expect(record.turns.count == 1)
        #expect(record.turns[0].id == "t1")
        #expect(record.turns[0].role == .user)
        #expect(record.turns[0].text == "hi")
        #expect(record.turns[0].attachments.isEmpty)
        #expect(record.turns[0].request == nil)
        #expect(record.turns[0].model == nil)
        #expect(record.extra.isEmpty)
    }

    @Test("A record missing identity or content fails to decode instead of being invented")
    func missingIdentityIsCorrupt() throws {
        let decoder = HouseChatCoding.makeDecoder()
        let cases: [String] = [
            #"{"turns":[]}"#,
            #"{"id":"c","turns":[{"role":"user","text":"hi"}]}"#,
            #"{"id":"c","turns":[{"id":"t","text":"hi"}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user"}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[{"kind":"pdf","name":"a.pdf"}]}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[{"id":"a","name":"a.pdf"}]}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[{"id":"a","kind":"pdf"}]}]}"#,
        ]
        for json in cases {
            #expect(throws: DecodingError.self) {
                try decoder.decode(ConversationRecord.self, from: Data(json.utf8))
            }
        }
    }

    @Test("A content-bearing array must be present and non-null; an empty array is legal")
    func contentArraysAreRequired() throws {
        let decoder = HouseChatCoding.makeDecoder()
        let malformed: [String] = [
            #"{"id":"c"}"#,
            #"{"id":"c","turns":null}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi"}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":null,"toolRounds":[],"sessionLinks":[]}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[],"toolRounds":null,"sessionLinks":[]}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[],"toolRounds":[],"sessionLinks":null}]}"#,
        ]
        for json in malformed {
            #expect(throws: DecodingError.self, "\(json)") {
                try decoder.decode(ConversationRecord.self, from: Data(json.utf8))
            }
        }

        // An explicit empty array is a legitimately empty list, not damage.
        let empty = #"{"id":"c","turns":[]}"#
        let record = try decoder.decode(ConversationRecord.self, from: Data(empty.utf8))
        #expect(record.turns.isEmpty)

        let receiptCases: [String] = [
            #"{"id":"r","status":"completed"}"#,
            #"{"id":"r","status":"completed","attachmentRefs":null,"toolRounds":[]}"#,
            #"{"id":"r","status":"completed","attachmentRefs":[],"toolRounds":null}"#,
        ]
        for json in receiptCases {
            #expect(throws: DecodingError.self, "\(json)") {
                try decoder.decode(RequestReceipt.self, from: Data(json.utf8))
            }
        }
        let receipt = try decoder.decode(
            RequestReceipt.self,
            from: Data(#"{"id":"r","status":"completed","attachmentRefs":[],"toolRounds":[]}"#.utf8)
        )
        #expect(receipt.attachmentRefs.isEmpty)
        #expect(receipt.toolRounds.isEmpty)
    }

    @Test("A pre-pass record fails closed on the content arrays the pass made required")
    func prePassRecordFailsClosed() throws {
        let decoder = HouseChatCoding.makeDecoder()
        // The shape an earlier build wrote: identity and text, then nothing the
        // pass made required. No migration reads it; a caller reports the
        // record as unreadable rather than seeing an empty history.
        let prePass = #"""
        {"id":"legacy","schemaVersion":3,"title":"Before","turns":[{"id":"t1","role":"user","text":"hi"},{"id":"t2","role":"assistant","text":"ok"}]}
        """#
        #expect(throws: DecodingError.self) {
            try decoder.decode(ConversationRecord.self, from: Data(prePass.utf8))
        }
        // A record with no `turns` key at all is not an empty conversation.
        #expect(throws: DecodingError.self) {
            try decoder.decode(ConversationRecord.self, from: Data(#"{"id":"legacy","title":"Before"}"#.utf8))
        }
        // An explicit null is not an empty list either.
        #expect(throws: DecodingError.self) {
            try decoder.decode(ConversationRecord.self, from: Data(#"{"id":"legacy","turns":null}"#.utf8))
        }
    }

    @Test("An extracted document needs its kind and name; an empty object does not decode")
    func extractedDocumentNeedsIdentity() throws {
        let decoder = HouseChatCoding.makeDecoder()
        let malformed: [String] = [
            #"{}"#,
            #"{"kind":"pdf"}"#,
            #"{"name":"report.pdf"}"#,
            #"{"kind":"pdf","name":""}"#,
            #"{"kind":5,"name":"report.pdf"}"#,
        ]
        for json in malformed {
            #expect(throws: DecodingError.self, "\(json)") {
                try decoder.decode(ExtractedDocument.self, from: Data(json.utf8))
            }
        }
        let document = try decoder.decode(
            ExtractedDocument.self,
            from: Data(#"{"kind":"pdf","name":"report.pdf"}"#.utf8)
        )
        #expect(document.kind == .pdf)
        #expect(document.name == "report.pdf")
        #expect(document.text == nil)
    }

    @Test("Unknown keys survive a decode and an encode")
    func unknownKeysRoundTrip() throws {
        let json = #"""
        {"id":"c","turns":[{"id":"t","role":"assistant","text":"ok","attachments":[],"toolRounds":[],"sessionLinks":[],"futureTurnField":7}],"futureFlag":true,"futureObject":{"a":[1,2]}}
        """#
        let record = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        #expect(record.extra["futureFlag"] == .bool(true))
        #expect(record.extra["futureObject"]?.objectValue?["a"] != nil)
        #expect(record.turns[0].extra["futureTurnField"] == .number(7))

        let data = try HouseChatCoding.makeEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["futureFlag"] as? Bool == true)
        #expect((object["futureObject"] as? [String: Any])?["a"] != nil)
        let turns = try #require(object["turns"] as? [[String: Any]])
        #expect(turns[0]["futureTurnField"] as? Int == 7)
    }

    @Test("An unrecognized role, kind, or status decodes to its fallback, not a failure")
    func unknownEnumFallbacks() throws {
        let json = #"""
        {"id":"c","turns":[{"id":"t","role":"debugger","text":"x","attachments":[{"id":"a","kind":"spreadsheet","name":"s.xlsx"}],"toolRounds":[],"sessionLinks":[]}]}
        """#
        let record = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        #expect(record.turns[0].role == .unknown)
        #expect(record.turns[0].attachments[0].kind == .other)
        #expect(record.turns[0].attachments[0].kindRaw == "spreadsheet")
        #expect(record.turns[0].attachments[0].name == "s.xlsx")

        let receipt = RequestReceipt(status: .unknown)
        let receiptJSON = try HouseChatCoding.makeEncoder().encode(receipt)
        let text = String(decoding: receiptJSON, as: UTF8.self)
        #expect(text.contains("\"unknown\""))

        #expect(ToolRoundStatus(rawValue: "exploded") == nil)
        let roundJSON = Data(#"{"id":"r","status":"exploded"}"#.utf8)
        let round = try HouseChatCoding.makeDecoder().decode(ToolRound.self, from: roundJSON)
        #expect(round.status == .unknown)
    }

    @Test("Dates are ISO 8601 with fractional seconds and survive the round trip")
    func dateCoding() throws {
        let date = Date(timeIntervalSince1970: 1_789_000_000.25)
        let text = HouseChatCoding.string(from: date)
        #expect(text.hasPrefix("2026-"))
        #expect(text.contains("T"))
        #expect(HouseChatCoding.date(from: text) == date)
        #expect(HouseChatCoding.date(from: "2026-09-17T03:40:25Z") != nil)

        let record = ConversationRecord(id: "c", createdAt: date, updatedAt: date)
        let data = try HouseChatCoding.makeEncoder().encode(record)
        let string = String(decoding: data, as: UTF8.self)
        #expect(string.contains(HouseChatCoding.string(from: date)))
        let decoded = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
        #expect(decoded.createdAt == date)
    }

    @Test("An image attachment keeps every fact it was given, and never fabricates one")
    func imageAttachmentKeepsFacts() throws {
        let attachment = AttachmentRecord(
            kind: .image,
            name: "shot.png",
            byteCount: 100,
            contentHash: String(repeating: "d", count: 64),
            extractorVersion: 1,
            path: "/tmp/shot.png",
            pixelWidth: 800,
            pixelHeight: 600
        )
        #expect(attachment.contentHash == String(repeating: "d", count: 64))
        #expect(attachment.path == "/tmp/shot.png")
        #expect(attachment.extractorVersion == 1)
        #expect(attachment.pixelWidth == 800)

        // Stored image metadata survives a decode; absent metadata stays absent.
        let json = #"{"id":"a","kind":"image","name":"shot.png","contentHash":"dddd","path":"/tmp/shot.png","pixelWidth":800,"pixelHeight":600}"#
        let decoded = try HouseChatCoding.makeDecoder().decode(AttachmentRecord.self, from: Data(json.utf8))
        #expect(decoded.contentHash == "dddd")
        #expect(decoded.path == "/tmp/shot.png")

        let bare = AttachmentRecord(kind: .image, name: "pasted.png", pixelWidth: 10, pixelHeight: 10)
        #expect(bare.contentHash == nil)
        #expect(bare.path == nil)
    }

    @Test("Envelopes carry a format marker and a schema version")
    func envelope() throws {
        let envelope = ConversationEnvelope(savedAt: Date(timeIntervalSince1970: 0), conversation: Fixtures.conversation())
        let data = try HouseChatCoding.makeEncoder().encode(envelope)
        let decoded = try HouseChatCoding.makeDecoder().decode(ConversationEnvelope.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.format == "house-chat-conversation")
        #expect(decoded.schemaVersion == 1)
    }
}
