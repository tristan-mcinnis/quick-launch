import Foundation

/// The on-device voice seam. One implementation talks to the `local-tts`
/// launchd agent; tests substitute their own.
protocol LocalSpeechServicing: Sendable {
    /// True when the local service answers `GET /health` with `ok`.
    func isHealthy() async -> Bool
    /// Synthesises `text` and plays it, returning when playback ends or
    /// ``stop()`` cuts it short.
    func speak(_ text: String) async throws
    /// Kills the player. Safe to call when nothing is speaking.
    func stop() async
}
