import Foundation

struct StreamDelta: Sendable {
    let text: String?
    let finishReason: String?
    /// Short progress note while the service works between answer tokens
    /// (for example "Searching the web…" during a tool call). Never part
    /// of the answer text.
    var status: String? = nil
    /// Set when the model paused to ask the user a multiple-choice question.
    /// The UI renders the card; the answer travels back through the
    /// service's `askUserQuestion` closure, not through this stream.
    var question: AskUserQuestion? = nil
    /// A tool call finished: its line for the thread and the sources it
    /// found. The view model keeps it with the answer this stream becomes.
    var toolRecord: ChatToolRecord? = nil
}
