import Foundation

/// What `POST /v1/audio/speech` expects, mirrored from local-tts's
/// OpenAI-compatible contract. Not private, so tests can encode one and
/// check the body shape without a network stub.
struct LocalSpeechRequestBody: Codable, Equatable {
    var input: String
    var voice: String
    var responseFormat: String

    enum CodingKeys: String, CodingKey {
        case input, voice
        case responseFormat = "response_format"
    }
}

private struct LocalSpeechHealthResponse: Decodable {
    let status: String
}

enum LocalSpeechError: LocalizedError {
    case synthesisFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .synthesisFailed(let status):
            "Local TTS could not synthesize that text (status \(status))."
        }
    }
}

/// Talks to the local-tts launchd agent on 127.0.0.1:8081: an OpenAI-shaped
/// `/v1/audio/speech` for synthesis and a plain `/health` for liveness.
/// Playback runs through `afplay` via `ProcessRunner`, never a shell.
/// `stop()` cancels the in-flight playback `Task`; `ProcessRunner.run`
/// terminates the child on cancellation, so one cancel does both.
actor LocalSpeechService: LocalSpeechServicing {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8081")!
    static let defaultVoice = "vctk-p225.wav"

    private let baseURL: URL
    private let voice: String
    private let session: URLSession
    private let afplay = URL(fileURLWithPath: "/usr/bin/afplay")
    private var playbackTask: Task<ProcessResult, Error>?

    init(baseURL: URL = LocalSpeechService.defaultBaseURL, voice: String = LocalSpeechService.defaultVoice, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.voice = voice
        self.session = session
    }

    func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return try JSONDecoder().decode(LocalSpeechHealthResponse.self, from: data).status == "ok"
        } catch {
            return false
        }
    }

    func speak(_ text: String) async throws {
        let request = try Self.speechRequest(for: text, voice: voice, baseURL: baseURL)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalSpeechError.synthesisFailed(status: status)
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-tts-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try data.write(to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let task = Task { try await ProcessRunner.run(executable: afplay, arguments: [wavURL.path]) }
        playbackTask = task
        defer { playbackTask = nil }
        _ = try await task.value
    }

    func stop() async {
        playbackTask?.cancel()
    }

    /// Pure request builder, pulled out so tests can inspect the body
    /// without a network stub.
    nonisolated static func speechRequest(
        for text: String,
        voice: String = LocalSpeechService.defaultVoice,
        baseURL: URL = LocalSpeechService.defaultBaseURL
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(
            LocalSpeechRequestBody(input: text, voice: voice, responseFormat: "wav")
        )
        return request
    }
}
