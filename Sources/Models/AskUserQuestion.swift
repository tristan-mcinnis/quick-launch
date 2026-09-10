import Foundation

/// One choice in the model's inline multiple-choice question.
struct AskUserQuestionOption: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The short option text the user picks, e.g. "Paste into Safari".
    let label: String
    /// Optional one-line explanation under the label.
    let detail: String?

    init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    var id: String { label }
}

/// A short multiple-choice question the model asked mid-answer. Raycast
/// renders one inline in the conversation, the user picks an option, and the
/// answer continues with that choice. The card is stored on the assistant
/// message so the transcript keeps the record of what was asked and picked.
struct AskUserQuestion: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// "A few options" in Raycast's manual; the card is not a menu, so the
    /// useful band is small. Fewer than two is not a question, more than five
    /// does not fit in one glance.
    static let minimumOptions = 2
    static let maximumOptions = 5

    let id: UUID
    /// The question, one short sentence.
    let question: String
    /// The choices, in the order they are shown. Always 2...5.
    let options: [AskUserQuestionOption]
    /// The option the user picked, once it is picked. Nil while the card is
    /// still waiting, which is how the card knows it is live.
    var selectedIndex: Int?

    init(
        id: UUID = UUID(),
        question: String,
        options: [AskUserQuestionOption],
        selectedIndex: Int? = nil
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.selectedIndex = selectedIndex
    }

    var isAnswered: Bool { selectedIndex != nil }

    /// The label the user picked, or nil while the card is still waiting.
    var chosenLabel: String? {
        guard let selectedIndex, options.indices.contains(selectedIndex) else { return nil }
        return options[selectedIndex].label
    }
}

/// The user's pick, handed back to the tool loop as the tool result.
struct AskUserQuestionAnswer: Sendable, Equatable {
    let label: String
    let detail: String?
}

/// Turns the model's `ask_user_question` arguments into a card.
///
/// Every failure returns nil rather than throwing: an unusable call must not
/// end the turn, it must fall back to the model answering normally. The
/// caller feeds the reason back as the tool result.
enum AskUserQuestionParser {
    static func parse(arguments: String) -> AskUserQuestion? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(object: object)
    }

    static func parse(object: [String: Any]) -> AskUserQuestion? {
        guard let question = (object["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !question.isEmpty
        else { return nil }
        guard let rawOptions = object["options"] as? [[String: Any]] else { return nil }
        let options = rawOptions
            .compactMap(option(from:))
            .prefix(AskUserQuestion.maximumOptions)
        guard options.count >= AskUserQuestion.minimumOptions else { return nil }
        return AskUserQuestion(question: question, options: Array(options))
    }

    private static func option(from object: [String: Any]) -> AskUserQuestionOption? {
        guard let label = (object["label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty
        else { return nil }
        let detail = (object["detail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AskUserQuestionOption(
            label: label,
            detail: (detail?.isEmpty ?? true) ? nil : detail
        )
    }
}

/// What the tool loop feeds back to the model for an `ask_user_question` call.
enum AskUserQuestionResult {
    static func picked(_ answer: AskUserQuestionAnswer, in question: AskUserQuestion) -> String {
        """
        The user answered "\(question.question)" with: \(answer.label). Continue the answer using that choice. Do not ask the same question again.
        """
    }

    static let dismissed = """
    The user dismissed the question without choosing. Answer using your best judgement and do not ask again.
    """

    /// A malformed call never dead-ends the thread: the reason goes back and
    /// the model answers normally.
    static func unusable(_ reason: String) -> String {
        """
        The ask_user_question call was unusable (\(reason)). Answer the request normally without asking a question.
        """
    }
}

/// The strings the card hands to VoiceOver. Kept out of the view so the
/// keyboard contract is testable without an accessibility tree.
enum AskUserQuestionAccessibility {
    static let cardHint = "Use the up and down arrow keys to choose an option, then press Return."

    static func cardLabel(question: String, optionCount: Int) -> String {
        "Question. \(question). \(optionCount) options. \(cardHint)"
    }

    static func optionLabel(
        _ option: AskUserQuestionOption,
        index: Int,
        count: Int,
        isSelected: Bool,
        isPicked: Bool
    ) -> String {
        var parts = ["Option \(index + 1) of \(count). \(option.label)"]
        if let detail = option.detail { parts.append(detail) }
        if isPicked {
            parts.append("Picked")
        } else if isSelected {
            parts.append("Selected")
        }
        return parts.joined(separator: ". ")
    }
}
