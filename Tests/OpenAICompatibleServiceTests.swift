import Testing
import Foundation
@testable import QuickLaunch

@Suite("OpenAICompatibleService")
struct OpenAICompatibleServiceTests {

    private func makeService(port: Int = 11450) -> OpenAICompatibleService {
        // Providers include `/v1` in their base URL when the endpoint needs it.
        let url = URL(string: "http://127.0.0.1:\(port)/v1")!
        return OpenAICompatibleService(baseURL: url, modelName: "test-model")
    }

    // MARK: - 1. HTTP method is POST

    @Test func testBuildRequestMethod() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hello")
        #expect(request.httpMethod == "POST")
    }

    // MARK: - 2. URL ends with /v1/chat/completions

    @Test func testBuildRequestURL() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hello")
        let urlString = request.url?.absoluteString ?? ""
        #expect(urlString.hasSuffix("/v1/chat/completions"))
    }

    // MARK: - 3. Content-Type header is application/json

    @Test func testBuildRequestContentType() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hello")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func testBuildRequestAddsBearerAPIKey() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "test-model",
            apiKey: "secret-key",
            systemPrompt: "Return only the result."
        )

        let request = try service.buildRequest(prompt: "hello")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test func testBuildRequestUsesEditableSystemPrompt() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "test-model",
            systemPrompt: "My custom action rules"
        )

        let request = try service.buildRequest(prompt: "hello")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.first?["content"] as? String == "My custom action rules")
    }

    @Test func testVersionedBaseURLIsNotDuplicated() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
            modelName: "local-model"
        )

        let request = try service.buildRequest(prompt: "hello")

        #expect(request.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
    }

    // MARK: - 4. Body JSON contains the user prompt somewhere in messages

    @Test func testBuildRequestBodyContainsPrompt() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "my test prompt")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        #expect(!messages.isEmpty)
        let hasPrompt = messages.contains { msg in
            (msg["content"] as? String) == "my test prompt"
        }
        #expect(hasPrompt)
    }

    // MARK: - 5. Body JSON has "stream": true

    @Test func testBuildRequestBodyHasStream() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hello")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let stream = try #require(json?["stream"] as? Bool)
        #expect(stream == true)
    }

    // MARK: - 6. Body JSON has "model" key

    @Test func testBuildRequestBodyHasModel() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hello")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] != nil)
    }

    // MARK: - 7. A system message precedes the user message

    @Test func testBuildRequestBodyHasSystemMessage() throws {
        let service = makeService()
        let request = try service.buildRequest(prompt: "hi")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        // First message should be the system prompt
        let first = try #require(messages.first)
        #expect((first["role"] as? String) == "system")
        let systemContent = (first["content"] as? String) ?? ""
        // Must instruct: direct answers, no preamble/postamble, no apology
        #expect(!systemContent.isEmpty)
        #expect(systemContent.lowercased().contains("direct") || systemContent.lowercased().contains("concise"))
    }

    // MARK: - 8. messages contains the user prompt as the second entry

    @Test func testBuildRequestBodyUserContent() throws {
        let service = makeService()
        let prompt = "what is the meaning of life?"
        let request = try service.buildRequest(prompt: prompt)
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        // User message is the last one
        let user = try #require(messages.last)
        #expect((user["role"] as? String) == "user")
        #expect((user["content"] as? String) == prompt)
    }

    // MARK: - 9. Empty string prompt builds a valid request (no throw)

    @Test func testBuildRequestEmptyPromptStillBuilds() throws {
        let service = makeService()
        // Should not throw — empty string is valid input
        let request = try service.buildRequest(prompt: "")
        #expect(request.httpMethod == "POST")
    }

    @Test func testBuildRequestAddsImageToLastUserMessage() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            modelName: "vision-model"
        )
        let image = QuickImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let request = try service.buildRequest(
            messages: [QuickMessage(role: .user, content: "What is shown?")],
            image: image
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let user = try #require(messages.last)
        let content = try #require(user["content"] as? [[String: Any]])

        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "What is shown?")
        #expect(content.last?["type"] as? String == "image_url")
        let imageURL = try #require(content.last?["image_url"] as? [String: Any])
        #expect((imageURL["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8080/chat/completions")
    }

    // MARK: - 10. Initialised with port 11451 → URL contains "11451"

    @Test func testBuildRequestDifferentPort() throws {
        let service = makeService(port: 11451)
        let request = try service.buildRequest(prompt: "hello")
        let urlString = request.url?.absoluteString ?? ""
        #expect(urlString.contains("11451"))
    }

    // MARK: - 11. Reasoning effort
    //
    // The endpoints agree on `reasoning_effort` and disagree on everything
    // else: DeepSeek's thinking-mode example also sends `thinking`.

    private func body(of service: OpenAICompatibleService) throws -> [String: Any] {
        let request = try service.buildRequest(prompt: "hello")
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bodyData(of service: OpenAICompatibleService) throws -> Data {
        try #require(try service.buildRequest(prompt: "hello").httpBody)
    }

    /// The body's JSON with keys sorted. JSON object key order is not part of
    /// the contract — and `JSONSerialization` does not promise one — so the
    /// content is compared in canonical order.
    private func canonicalBody(of service: OpenAICompatibleService) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: try bodyData(of: service))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func service(
        baseURL: String,
        model: String = "test-model",
        effort: ReasoningEffort?,
        format: ReasoningEffortWireFormat? = nil
    ) -> OpenAICompatibleService {
        OpenAICompatibleService(
            baseURL: URL(string: baseURL)!,
            modelName: model,
            reasoningEffort: effort,
            reasoningEffortFormat: format
        )
    }

    @Test func testReasoningEffortIsSentToAnOpenAIEndpoint() throws {
        let json = try body(of: service(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-5",
            effort: .high
        ))

        #expect(json["reasoning_effort"] as? String == "high")
        #expect(json["thinking"] == nil)
        #expect(Set(json.keys) == ["model", "stream", "messages", "reasoning_effort"])
    }

    @Test func testLowEffortIsSentVerbatim() throws {
        let json = try body(of: service(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-5",
            effort: .low
        ))

        #expect(json["reasoning_effort"] as? String == "low")
    }

    @Test func testMoonshotEndpointGetsTheFlatShapeOnly() throws {
        // Kimi K3 takes a top-level `reasoning_effort` and rejects the
        // `thinking` object its K2.x predecessors used.
        let json = try body(of: service(
            baseURL: "https://api.moonshot.ai/v1",
            model: "kimi-k3",
            effort: .high
        ))

        #expect(json["reasoning_effort"] as? String == "high")
        #expect(json["thinking"] == nil)
    }

    @Test func testDeepSeekEndpointGetsItsOwnShape() throws {
        let json = try body(of: service(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            effort: .high
        ))

        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(json["reasoning_effort"] as? String == "high")
    }

    @Test func testEndpointShapeCanBeOverridden() throws {
        // A proxy in front of DeepSeek speaks the same shape on a different
        // host, and a plain OpenAI-shaped server can sit on a DeepSeek host.
        let deepSeekBehindAProxy = try body(of: service(
            baseURL: "http://127.0.0.1:8078/v1",
            model: "deepseek-v4-flash",
            effort: .high,
            format: .deepSeek
        ))
        #expect(deepSeekBehindAProxy["thinking"] != nil)

        let plainServerOnADeepSeekHost = try body(of: service(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            effort: .high,
            format: .openAI
        ))
        #expect(plainServerOnADeepSeekHost["thinking"] == nil)
        #expect(plainServerOnADeepSeekHost["reasoning_effort"] as? String == "high")
    }

    @Test func testNoEffortLeavesTheBodyExactlyAsItWas() throws {
        // The body this service built before the setting existed, from a
        // service that was never told about effort at all.
        let today = try canonicalBody(of: makeService())

        let explicitNil = try canonicalBody(of: service(baseURL: "http://127.0.0.1:11450/v1", effort: nil))
        let modelDefault = try canonicalBody(of: service(baseURL: "http://127.0.0.1:11450/v1", effort: .modelDefault))
        let deepSeekDefault = try canonicalBody(of: service(baseURL: "https://api.deepseek.com", effort: .modelDefault))

        #expect(today == explicitNil)
        #expect(today == modelDefault)
        #expect(today == deepSeekDefault)

        let json = try body(of: makeService())
        #expect(Set(json.keys) == ["model", "stream", "messages"])
    }

    @Test func testNoEffortLeavesTheBodyExactlyAsItWasWithTools() throws {
        // The same constraint on the tool-calling shape, which is the other
        // body this service can send.
        let plain = OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:11450/v1")!,
            modelName: "test-model",
            webSearch: { _ in "" }
        )
        let unset = OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:11450/v1")!,
            modelName: "test-model",
            webSearch: { _ in "" },
            reasoningEffort: .modelDefault
        )

        #expect(try canonicalBody(of: plain) == canonicalBody(of: unset))
        #expect(try body(of: plain)["reasoning_effort"] == nil)
    }

    /// The gate the caller applies before it reaches the service: a model the
    /// curated table gives no effort control reads back as `.modelDefault`,
    /// whatever the user chose, and the service then sends nothing.
    @Test @MainActor func testEffortIsAbsentForAModelThatDoesNotSupportIt() throws {
        let providerID = UUID()
        let preferences = ModelPreferenceStore(fileURL: nil)
        preferences.setReasoningEffort(.high, providerID: providerID, model: "gemma-it")
        let profile = preferences.profile(providerID: providerID, model: "gemma-it")

        #expect(!profile.supportsReasoningEffort)
        #expect(profile.reasoningEffort == .modelDefault)

        let json = try body(of: service(
            baseURL: "http://127.0.0.1:8078/v1",
            model: "gemma-it",
            effort: profile.reasoningEffort
        ))

        #expect(json["reasoning_effort"] == nil)
        #expect(json["thinking"] == nil)
        #expect(Set(json.keys) == ["model", "stream", "messages"])
    }
}
