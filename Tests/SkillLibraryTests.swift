import Foundation
import Testing
@testable import QuickLaunch

@Suite("Skill library")
struct SkillLibraryTests {
    private func makeLibrary() throws -> (SkillLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "skill-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["costing", "email-ops"] {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# \(name)\nBody".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        // A folder with no SKILL.md is not a skill.
        try FileManager.default.createDirectory(
            at: root.appending(path: "empty", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        return (SkillLibrary(root: root), root)
    }

    @Test func listsOnlyFoldersThatHoldASkillFile() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.names() == ["costing", "email-ops"])
    }

    @Test func readsAListedSkill() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.read("costing") == "# costing\nBody")
    }

    @Test func refusesAnythingThatIsNotAListedName() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["", "..", "../costing", "costing/../email-ops", "/etc", ".hidden", "empty", "missing"] {
            #expect(library.read(name) == nil, "\(name) must be refused")
        }
    }

    @Test func truncatesALargeSkill() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "a", count: SkillLibrary.maxCharacters + 50)
        try big.write(to: root.appending(path: "costing/SKILL.md"), atomically: true, encoding: .utf8)
        let text = try #require(library.read("costing"))
        #expect(text.hasPrefix(String(repeating: "a", count: SkillLibrary.maxCharacters)))
        #expect(text.hasSuffix("[Skill text truncated]"))
    }
}
