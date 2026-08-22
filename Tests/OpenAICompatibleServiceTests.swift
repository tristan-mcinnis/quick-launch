import Testing
import Foundation
@testable import QuickLaunch

// TDD (RED phase) — ApfelQuickService does not yet exist.
// Tests define the intended API for the buildRequest(prompt:) helper.
//
// Intended shape:
//   struct ApfelQuickService: QuickService {
//       let baseURL: URL       // e.g. http://127.0.0.1:11450
//       let modelName: String
//
//       func buildRequest(prompt: String) throws -> URLRequest
//       func send(prompt: String) -> AsyncThrowingStream<StreamDelta, Error>
//       func healthCheck() async throws -> Bool
//   }

@Suite("ApfelQuickService")
struct ApfelQuickServiceTests {

    private func makeService(port: Int = 11450) -> ApfelQuickService {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        return ApfelQuickService(baseURL: url, modelName: "test-model")
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
        let service = ApfelQuickService(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "test-model",
            apiKey: "secret-key",
            systemPrompt: "Return only the result.",
            ensureV1: false
        )

        let request = try service.buildRequest(prompt: "hello")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test func testBuildRequestUsesEditableSystemPrompt() throws {
        let service = ApfelQuickService(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "test-model",
            systemPrompt: "My custom action rules",
            ensureV1: false
        )

        let request = try service.buildRequest(prompt: "hello")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.first?["content"] as? String == "My custom action rules")
    }

    @Test func testVersionedBaseURLIsNotDuplicated() throws {
        let service = ApfelQuickService(
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
            modelName: "local-model",
            ensureV1: false
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
        let service = ApfelQuickService(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            modelName: "vision-model",
            ensureV1: false
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
}
