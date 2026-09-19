import Testing
import Foundation
import Network
@testable import QuickLaunch

// Real-HTTP integration tests for OpenAICompatibleService.
// These spin up an in-process HTTP server on a random local port,
// point OpenAICompatibleService at it, and verify the full streaming flow:
// buildRequest → URLSession.bytes → SSEParser → StreamDelta yield.

@Suite("OpenAICompatibleService Integration", .serialized)
struct OpenAICompatibleServiceIntegrationTests {

    // MARK: — Streams a simple 3-delta response

    @Test func testStreamsThreeDeltas() async throws {
        let sseLines = [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"index\":0}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"},\"index\":0}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"index\":0}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"!\"},\"index\":0,\"finish_reason\":\"stop\"}]}",
            "",
            "data: [DONE]",
            "",
        ]
        let server = try LocalHTTPServer(responseBody: sseLines.joined(separator: "\r\n"))
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, modelName: "test-model")
        var collected = ""
        for try await delta in service.send(prompt: "hi") {
            if let text = delta.text { collected += text }
        }
        #expect(collected == "Hello!")
    }

    // MARK: — Server rejects missing "model" field

    @Test func testRequestBodyActuallyIncludesModelField() async throws {
        // This test exercises the real request body by running it through
        // JSONSerialization on the server side and verifying the model field
        // is present — catching the regression where apfel rejects bodies
        // missing "model".
        let server = try LocalHTTPServer(
            responseBody: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"index\":0}]}\r\n\r\ndata: [DONE]\r\n\r\n",
            bodyValidator: { body in
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return false
                }
                return json["model"] != nil && json["messages"] != nil && json["stream"] as? Bool == true
            }
        )
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, modelName: "test-model")
        var collected = ""
        for try await delta in service.send(prompt: "x") {
            if let text = delta.text { collected += text }
        }
        #expect(collected == "ok")
        #expect(await server.bodyWasValid == true)
    }

    // MARK: — 4xx response surfaces an error

    @Test func testServerErrorResponseSurfacesError() async throws {
        let server = try LocalHTTPServer(
            responseBody: "{\"error\":\"bad request\"}",
            statusCode: 400
        )
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, modelName: "test-model")
        do {
            for try await _ in service.send(prompt: "hi") {}
            Issue.record("Expected error to be thrown")
        } catch {
            // Any error is fine — the service should surface the failure
        }
    }

    // MARK: — A non-2xx body is surfaced, not swallowed

    @Test func testProviderErrorMessageReachesTheCaller() async throws {
        let server = try LocalHTTPServer(
            responseBody: "{\"error\":{\"message\":\"Incorrect API key provided\"}}",
            statusCode: 401
        )
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, modelName: "test-model")
        do {
            for try await _ in service.send(prompt: "hi") {}
            Issue.record("Expected the 401 to be thrown")
        } catch {
            #expect(error.localizedDescription.contains("401"))
            #expect(error.localizedDescription.contains("Incorrect API key provided"))
        }
    }

    // MARK: — A 200 with no parseable choice is an error, not an empty turn

    @Test func testAStreamWithoutChoicesThrowsInsteadOfCompletingEmpty() async throws {
        let server = try LocalHTTPServer(
            responseBody: "data: {\"id\":\"a\"}\r\n\r\ndata: {\"id\":\"b\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        )
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, modelName: "test-model")
        do {
            for try await _ in service.send(prompt: "hi") {}
            Issue.record("Expected an empty stream to be thrown")
        } catch {
            #expect(error.localizedDescription.contains("no content"))
        }
    }

    // MARK: — The chosen reasoning effort reaches the server

    @Test func testReasoningEffortIsSentOnTheWire() async throws {
        let server = try LocalHTTPServer(
            responseBody: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"index\":0}]}\r\n\r\ndata: [DONE]\r\n\r\n",
            bodyValidator: { body in
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return false
                }
                return json["reasoning_effort"] as? String == "high"
                    && json["model"] as? String == "test-model"
            }
        )
        defer { Task { await server.stop() } }
        let port = try await server.start()

        let service = OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!,
            modelName: "test-model",
            reasoningEffort: .high
        )
        for try await _ in service.send(prompt: "hi") {}

        #expect(await server.bodyWasValid == true)
    }
}

// MARK: — Tiny atomic flag for cross-thread one-shot signalling

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryToggle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: — Minimal in-process HTTP server

private actor LocalHTTPServer {
    let responseBody: String
    let statusCode: Int
    let bodyValidator: (@Sendable (Data) -> Bool)?
    private var listener: NWListener?
    private(set) var bodyWasValid: Bool = false

    init(responseBody: String, statusCode: Int = 200, bodyValidator: (@Sendable (Data) -> Bool)? = nil) throws {
        self.responseBody = responseBody
        self.statusCode = statusCode
        self.bodyValidator = bodyValidator
    }

    func start() async throws -> Int {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [responseBody, statusCode, bodyValidator] connection in
            let conn = connection
            conn.start(queue: .global())
            Self.handleConnection(conn, responseBody: responseBody, statusCode: statusCode, bodyValidator: bodyValidator) { valid in
                if valid {
                    Task { await self.markValid() }
                }
            }
        }
        self.listener = listener

        // Wait for listener to reach .ready state and have a port
        let resumed = AtomicFlag()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                guard resumed.tryToggle() else { return }
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        cont.resume(returning: Int(p))
                    } else {
                        cont.resume(throwing: NSError(domain: "LocalHTTPServer", code: 2))
                    }
                case .failed(let err):
                    cont.resume(throwing: err)
                default:
                    // Reset so future state events can try again — but in practice
                    // .ready or .failed are terminal for our needs
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func markValid() { bodyWasValid = true }

    nonisolated private static func handleConnection(
        _ conn: NWConnection,
        responseBody: String,
        statusCode: Int,
        bodyValidator: (@Sendable (Data) -> Bool)?,
        onValid: @escaping (Bool) -> Void
    ) {
        var received = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let d = data { received.append(d) }
                // Check if we've read the full HTTP request (headers + body)
                // Minimal check: if we see \r\n\r\n and there's content-length bytes after, or the connection is complete
                if let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    let body = received[headerEnd.upperBound...]
                    let contentLength = Self.parseContentLength(headers)
                    if body.count >= contentLength {
                        // Full request received
                        if let validator = bodyValidator {
                            let valid = validator(Data(body))
                            onValid(valid)
                        } else {
                            onValid(true)
                        }
                        sendResponse(conn, responseBody: responseBody, statusCode: statusCode)
                        return
                    }
                }
                if isComplete || error != nil {
                    sendResponse(conn, responseBody: responseBody, statusCode: statusCode)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    nonisolated private static func parseContentLength(_ headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    nonisolated private static func sendResponse(_ conn: NWConnection, responseBody: String, statusCode: Int) {
        let statusText = statusCode == 200 ? "OK" : "Error"
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: text/event-stream\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
