import Foundation
import Testing
@testable import HouseChatCore

@Suite("Endpoints and secrets")
struct EndpointAndSecretTests {
    @Test("An endpoint drops userinfo, the query string, and the fragment")
    func sanitizesURL() throws {
        let url = try #require(URL(string: "https://user:secret@api.example.com:8443/v1/chat?api_key=sk-live-123&token=abc#frag"))
        let endpoint = try #require(EndpointDescriptor(url: url))

        #expect(endpoint.sanitized == "https://api.example.com:8443/v1/chat")
        #expect(endpoint.host == "api.example.com")
        #expect(endpoint.port == 8443)
        #expect(endpoint.path == "/v1/chat")
        for secret in ["secret", "user", "api_key", "sk-live-123", "token", "abc", "frag"] {
            #expect(!endpoint.sanitized.contains(secret), "leaked \(secret)")
        }
    }

    @Test("A local socket or relative URL has no endpoint descriptor")
    func rejectsHostlessURLs() {
        #expect(EndpointDescriptor(url: URL(fileURLWithPath: "/tmp/socket")) == nil)
        #expect(EndpointDescriptor(url: URL(string: "/v1/chat")!) == nil)
        #expect(EndpointDescriptor.sanitized(URL(string: "https://host/v1?key=1")!) == "https://host/v1")
    }

    @Test("A stored receipt can never serialize a credential")
    func receiptHasNoSecrets() throws {
        let url = try #require(URL(string: "https://user:secret@api.example.com/v1/chat?api_key=sk-123"))
        let receipt = RequestReceipt(
            selection: ModelSelection(
                chosen: ModelChoice(provider: "openai", model: "gpt-4o", thinking: "low"),
                effective: ModelChoice(provider: "local", model: "gemma", thinking: "off")
            ),
            status: .completed,
            endpoint: EndpointDescriptor(url: url)
        )
        let text = String(decoding: try HouseChatCoding.makeEncoder().encode(receipt), as: UTF8.self)

        for secret in ["secret", "api_key", "sk-123", "Authorization", "Bearer", "credential", "password"] {
            #expect(!text.contains(secret), "receipt leaked \(secret)")
        }
        #expect(text.contains("api.example.com"))
        #expect(text.contains("gpt-4o"))
        #expect(text.contains("gemma"))
    }

    @Test("Endpoints survive a receipt round trip without the query string")
    func endpointRoundTrip() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/responses?debug=1"))
        let receipt = RequestReceipt(endpoint: EndpointDescriptor(url: url))
        let data = try HouseChatCoding.makeEncoder().encode(receipt)
        let decoded = try HouseChatCoding.makeDecoder().decode(RequestReceipt.self, from: data)
        #expect(decoded.endpoint == receipt.endpoint)
        #expect(decoded.endpoint?.sanitized == "https://api.example.com/v1/responses")
    }

    @Test("A legacy receipt with no endpoint decodes with it nil")
    func legacyReceiptWithoutEndpoint() throws {
        let json = #"{"id":"r","status":"completed","attachmentRefs":[],"toolRounds":[],"usage":{"totalTokens":10}}"#
        let receipt = try HouseChatCoding.makeDecoder().decode(RequestReceipt.self, from: Data(json.utf8))
        #expect(receipt.endpoint == nil)
        #expect(receipt.usage?.totalTokens == 10)
    }
}

@Suite("App payload")
struct AppPayloadTests {
    @Test("A QL payload keeps its own fields out of the shared schema")
    func quickLaunchPayload() throws {
        let payload = AppPayload(namespace: "quick-launch", [
            "titleSource": .string("manual"),
            "assistantID": .string("assistant-1"),
            "enabledTools": .array([.string("web_search"), .string("vault_search")]),
            "cards": .array([.object(["kind": .string("summary"), "pinned": .bool(true)])]),
            "toolRecords": .array([.object(["name": .string("web_search"), "status": .string("ok")])]),
        ])
        let conversation = ConversationRecord(
            id: "ql-1",
            surface: .quickLaunch,
            title: "Chat",
            turns: [TurnRecord(role: .assistant, text: "hi", appPayload: AppPayload(namespace: "quick-launch", ["assistantID": .string("assistant-1")]))],
            appPayload: payload
        )

        let data = try HouseChatCoding.makeEncoder().encode(conversation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The app's keys are inside appPayload, not at the record's top level.
        #expect(object["titleSource"] == nil)
        #expect(object["assistantID"] == nil)
        let stored = try #require(object["appPayload"] as? [String: Any])
        #expect(stored["namespace"] as? String == "quick-launch")
        let values = try #require(stored["values"] as? [String: Any])
        #expect(values["titleSource"] as? String == "manual")
        #expect((values["enabledTools"] as? [Any])?.count == 2)
        #expect((values["cards"] as? [Any])?.count == 1)

        let decoded = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
        #expect(decoded == conversation)
        #expect(decoded.appPayload?["assistantID"] == JSONValue.string("assistant-1"))
        #expect(decoded.turns[0].appPayload?["assistantID"] == JSONValue.string("assistant-1"))
    }

    @Test("Merging two payloads keeps the later value for the same key")
    func merging() {
        let base = AppPayload(namespace: "rti", ["a": .number(1), "b": .number(2)])
        let overlay = AppPayload(namespace: "rti", ["b": .number(3), "c": .number(4)])
        let merged = base.merging(overlay)
        #expect(merged["a"] == .number(1))
        #expect(merged["b"] == .number(3))
        #expect(merged["c"] == .number(4))
        #expect(base.merging(nil) == base)
    }

    @Test("A conversation with no app payload decodes and encodes without the key")
    func absentPayload() throws {
        let data = try HouseChatCoding.makeEncoder().encode(ConversationRecord(id: "plain"))
        #expect(!String(decoding: data, as: UTF8.self).contains("appPayload"))
        let decoded = try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
        #expect(decoded.appPayload == nil)
        #expect(decoded.extra.isEmpty)
    }
}
