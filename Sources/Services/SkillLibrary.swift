import Foundation

/// Read-only access to the canonical skills folder, `~/.claude/skills`.
///
/// A skill name is valid only when it is a folder listed there that holds a
/// `SKILL.md`. Nothing supplied by a model or a setting is joined into a path
/// until it has matched that listing, so `../` and absolute paths can never
/// reach the file system.
struct SkillLibrary: Sendable {
    let root: URL
    /// The most text one skill returns, so a large skill cannot fill a
    /// model's context on its own.
    static let maxCharacters = 12_000

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/skills", directoryHint: .isDirectory)) {
        self.root = root
    }

    /// Folder names that hold a `SKILL.md`, sorted. Hidden entries are skipped.
    func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return entries
            .filter { !$0.hasPrefix(".") }
            .filter { FileManager.default.fileExists(atPath: skillFile($0).path) }
            .sorted()
    }

    /// True only for a plain folder name that is actually listed.
    func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              !name.hasPrefix("."), name != ".."
        else { return false }
        return names().contains(name)
    }

    /// The skill's `SKILL.md`, truncated to `maxCharacters`, or nil when the
    /// name is not a listed skill or the file cannot be read.
    func read(_ name: String) -> String? {
        guard isValid(name),
              let text = try? String(contentsOf: skillFile(name), encoding: .utf8)
        else { return nil }
        guard text.count > Self.maxCharacters else { return text }
        return String(text.prefix(Self.maxCharacters)) + "\n\n[Skill text truncated]"
    }

    private func skillFile(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
            .appending(path: "SKILL.md", directoryHint: .notDirectory)
    }
}
