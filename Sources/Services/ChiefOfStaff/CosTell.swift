import Foundation

/// What `cos tell --json` prints: an answer to show as a reply, or a
/// proposal whose card waits for Do it. Any other kind reads as an answer.
struct CosTellReply: Sendable, Equatable, Decodable {
    enum Kind: String, Sendable, Equatable {
        case answer
        case proposal
    }

    var kind: Kind
    var text: String
    /// The new card's id, on a proposal.
    var card: String?

    init(kind: Kind, text: String, card: String? = nil) {
        self.kind = kind
        self.text = text
        self.card = card
    }

    private enum CodingKeys: String, CodingKey { case kind, text, card }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap(Kind.init(rawValue:)) ?? .answer
        card = try c.decodeIfPresent(String.self, forKey: .card).flatMap { $0.isEmpty ? nil : $0 }
        // A proposal with no card has nothing to show but its text.
        self.kind = kind == .proposal && card == nil ? .answer : kind
        let text = try c.decodeIfPresent(String.self, forKey: .text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An empty reply would leave the question unanswered.
        self.text = text.isEmpty ? (self.kind == .proposal ? "I made a card for this." : "No answer.") : text
    }

    /// The reply in `result`, or why there is none, in one sentence.
    static func parse(_ result: CosResult) throws -> CosTellReply {
        guard result.succeeded else {
            throw QuickServiceError.commandFailed(
                OutcomeLine.lastLine(of: result.stderr) ?? "The Chief of Staff did not answer (exit \(result.exitCode))."
            )
        }
        do {
            return try JSONDecoder().decode(CosTellReply.self, from: Data(result.stdout.utf8))
        } catch {
            throw QuickServiceError.commandFailed("The Chief of Staff's answer could not be read.")
        }
    }

    /// The text `cos tell` gets: what was typed, then one "Attached:" line
    /// per file or link, so it can name them. A picture or a selection has
    /// no path to give.
    static func message(_ text: String, attachments: [ChatAttachmentRef]) -> String {
        let lines = attachments.compactMap { ref in (ref.path ?? ref.url?.absoluteString).map { "Attached: " + $0 } }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([typed] + (lines.isEmpty ? [] : [""] + lines)).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The pinned conversation's "model": one `cos tell` call per question. It
/// streams the reply as one piece of text, with the new card's id when the
/// Chief of Staff made one, so the thread draws that card under the reply.
struct CosTellService: QuickService {
    let runner: any CosRunning
    let command: CosCommand
    /// Runs before the text is yielded, so the card is in the model when the
    /// reply draws.
    let onReply: @Sendable (CosTellReply) async -> Void

    static let status = "Telling the Chief of Staff…"

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(StreamDelta(text: nil, finishReason: nil, status: Self.status))
                do {
                    let reply = try CosTellReply.parse(try await runner.run(command))
                    try Task.checkCancellation()
                    await onReply(reply)
                    var delta = StreamDelta(text: reply.text, finishReason: "stop")
                    delta.cosCard = reply.kind == .proposal ? reply.card : nil
                    continuation.yield(delta)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async throws -> Bool { true }
}
