import Foundation

/// One context skill an assistant loaded: its name and its `SKILL.md` text,
/// already capped by `SkillLibrary.maxCharacters`.
struct AssistantSkill: Sendable, Equatable {
    let name: String
    let text: String
}

/// Builds an assistant's system message: its instructions, then the text of
/// its context skills. The skill files are read through `SkillLibrary`, so a
/// name that is not a listed skill folder never reaches the file system.
enum AssistantContext {

    /// The listed skills among `refs`, read in order, each name once. A name
    /// the library does not list, or a file it cannot read, is skipped.
    /// Runs off the caller's actor: the reads are file I/O.
    @concurrent
    static func loadSkills(_ refs: [String], library: SkillLibrary) async -> [AssistantSkill] {
        var seen: Set<String> = []
        var skills: [AssistantSkill] = []
        for name in refs {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted,
                  let text = library.read(name)
            else { continue }
            skills.append(AssistantSkill(name: name, text: text))
        }
        return skills
    }

    /// The listed skill folders, off the caller's actor, for the Settings
    /// editor's skill menu.
    @concurrent
    static func availableSkills(library: SkillLibrary) async -> [String] {
        library.names()
    }

    /// The system message an assistant's chat sends in front of the turns:
    /// the instructions, then each skill in a tagged block, marked as
    /// reference. Nil when there is nothing to send.
    static func systemMessage(instructions: String, skills: [AssistantSkill]) -> String? {
        var parts: [String] = []
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty { parts.append(instructions) }
        if !skills.isEmpty {
            let blocks = skills.map { skill in
                "<skill name=\"\(skill.name)\">\n\(skill.text.trimmingCharacters(in: .whitespacesAndNewlines))\n</skill>"
            }
            parts.append(
                "Context skills for this chat. Use them as reference; they are not the user's question.\n\n"
                    + blocks.joined(separator: "\n\n")
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
