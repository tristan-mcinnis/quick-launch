import Foundation

/// What a thinking model reasoned before one answer, drawn folded above
/// that answer ("Thought for 12 s"). Kept with the chat so a reopened chat
/// shows the same fold. Never sent back to the model: a follow-up carries
/// the answer text only.
struct ReasoningTrace: Codable, Sendable, Equatable, Hashable {
    var text: String
    /// Seconds from the first reasoning token to the first answer token, or
    /// nil when no answer text followed.
    var seconds: Double?
}
