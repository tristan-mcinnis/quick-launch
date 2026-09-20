import Foundation
import Testing
@testable import QuickLaunch

/// The composer's `/` palette.
///
/// The commands it lists already worked; the palette is what finally names
/// them, on the surface whose own placeholder has read "or / for commands"
/// since v1.4 while typing `/` opened nothing. Skills are the one addition:
/// reachable before only when the model chose to call `read_skill`.
@Suite("Slash command palette")
@MainActor
struct SlashCommandPaletteTests {
    private static func makeViewModel(skillRoot: URL? = nil) -> QuickViewModel {
        var settings = QuickSettings()
        settings.savedPromptPrefix = "/"
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        vm.isQuickAIPresented = true
        if let skillRoot { vm.skillLibrary = SkillLibrary(root: skillRoot) }
        return vm
    }

    /// A skills folder on disk: two valid skills, one folder with no
    /// `SKILL.md`, which is not a skill.
    private static func makeSkillRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slash-skills-\(UUID().uuidString)", isDirectory: true)
        for name in ["house-design", "diagnose"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# \(name)\n\nGuidance for \(name)."
                .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    // MARK: - Opening

    @Test func typingSlashOpensThePaletteAndKeepsTheCharacter() {
        let vm = Self.makeViewModel()
        vm.input = "/"
        vm.quickAIComposerDidChange("/")

        #expect(vm.isSlashCommandPalettePresented)
        // Unlike `@`, the `/` is the command being typed, not a trigger to
        // swallow.
        #expect(vm.input == "/")
        #expect(vm.topLayer == .slashCommandPalette)
    }

    @Test func aSpaceClosesIt() {
        let vm = Self.makeViewModel()
        vm.input = "/"
        vm.quickAIComposerDidChange("/")
        #expect(vm.isSlashCommandPalettePresented)

        // The name is settled; what follows is the argument.
        vm.input = "/tldr "
        vm.quickAIComposerDidChange("/tldr ")
        #expect(!vm.isSlashCommandPalettePresented)
    }

    @Test func ordinaryTextNeverOpensIt() {
        let vm = Self.makeViewModel()
        for text in ["hello", "3/4 of the way", "", "what is /etc for"] {
            vm.input = text
            vm.quickAIComposerDidChange(text)
            #expect(!vm.isSlashCommandPalettePresented, "opened on \(text)")
        }
    }

    @Test func escapeClosesThePaletteAndLeavesTheDraft() {
        let vm = Self.makeViewModel()
        vm.input = "/tl"
        vm.quickAIComposerDidChange("/tl")
        #expect(vm.isSlashCommandPalettePresented)

        #expect(vm.popTopLayer())
        #expect(!vm.isSlashCommandPalettePresented)
        #expect(vm.input == "/tl")
    }

    // MARK: - What it lists

    @Test func itListsTheBuiltInsAndEverySavedAlias() {
        let vm = Self.makeViewModel()
        vm.openSlashCommandPalette()
        let names = vm.slashCommandCatalog.map(\.name)

        #expect(names.prefix(2) == ["new", "clear"])
        for alias in vm.settings.savedPrompts.map(\.alias) {
            #expect(names.contains(alias), "missing /\(alias)")
        }
    }

    @Test func itListsTheSkillsOnDisk() throws {
        let root = try Self.makeSkillRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = Self.makeViewModel(skillRoot: root)
        vm.openSlashCommandPalette()
        let skills = vm.slashCommandCatalog.filter { $0.kind == .skill }.map(\.name)

        #expect(skills == ["diagnose", "house-design"])
        // A folder with no SKILL.md is not a skill.
        #expect(!skills.contains("empty"))
    }

    @Test func typingNarrowsTheRows() {
        let vm = Self.makeViewModel()
        vm.input = "/"
        vm.quickAIComposerDidChange("/")
        vm.input = "/tld"
        vm.quickAIComposerDidChange("/tld")

        #expect(vm.slashCommandQuery == "tld")
        #expect(vm.slashCommandMatches.first?.name == "tldr")
    }

    /// A prompt is findable by what it is called, not only by its alias.
    @Test func aPromptIsFoundByItsName() {
        let vm = Self.makeViewModel()
        vm.input = "/summar"
        vm.quickAIComposerDidChange("/summar")

        #expect(vm.slashCommandMatches.contains { $0.name == "tldr" })
    }

    // MARK: - Taking a row

    @Test func returnCompletesTheCommandAndDoesNotSend() {
        let vm = Self.makeViewModel()
        vm.input = "/tld"
        vm.quickAIComposerDidChange("/tld")
        #expect(vm.slashCommandMatches.first?.name == "tldr")

        vm.submitFromComposer()

        #expect(vm.input == "/tldr")
        #expect(!vm.isSlashCommandPalettePresented)
        // Nothing was asked: the draft is a command waiting for its argument.
        #expect(vm.currentConversation?.messages.isEmpty != false)
    }

    @Test func arrowsMoveTheHighlight() {
        let vm = Self.makeViewModel()
        vm.input = "/"
        vm.quickAIComposerDidChange("/")
        let rows = vm.slashCommandMatches
        try? #require(rows.count > 1)

        vm.moveSlashCommandSelection(1)
        #expect(vm.slashCommandIndex == 1)
        vm.moveSlashCommandSelection(-1)
        #expect(vm.slashCommandIndex == 0)
        // It wraps, as every other list in the app does.
        vm.moveSlashCommandSelection(-1)
        #expect(vm.slashCommandIndex == rows.count - 1)
    }

    // MARK: - Skills as commands

    @Test func aSkillCommandIsRecognisedOnlyWhenItIsARealSkill() throws {
        let root = try Self.makeSkillRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = Self.makeViewModel(skillRoot: root)

        #expect(vm.slashSkillName(in: "/house-design make it tighter") == "house-design")
        #expect(vm.slashSkillName(in: "/house-design") == "house-design")
        #expect(vm.slashSkillName(in: "/nope do something") == nil)
        #expect(vm.slashSkillName(in: "ordinary question") == nil)
        // A built-in and a saved prompt both win over a skill of the name.
        #expect(vm.slashSkillName(in: "/new") == nil)
        #expect(vm.slashSkillName(in: "/tldr something") == nil)
    }

    @Test func theComposerSaysWhenASkillWillRun() throws {
        let root = try Self.makeSkillRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = Self.makeViewModel(skillRoot: root)

        vm.input = "/house-design tighten the panel"
        #expect(vm.slashSkillNotice == "Runs the house-design skill")

        vm.input = "what is the panel width"
        #expect(vm.slashSkillNotice == nil)
    }

    /// The skill's own text goes in front of the question, and the command
    /// itself never reaches the model.
    @Test func askingWithASkillSendsTheSkillText() async throws {
        let root = try Self.makeSkillRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = Self.makeViewModel(skillRoot: root)
        vm.input = "/house-design tighten the panel"

        let request = try #require(await vm.prepareRequest())

        #expect(request.submittedInput.contains("Guidance for house-design"))
        #expect(request.submittedInput.hasSuffix("tighten the panel"))
        #expect(!request.submittedInput.hasPrefix("/house-design"))
        #expect(vm.threadNotice == "Using the house-design skill")
    }

    /// An unknown slash name is still refused locally, as it always was: the
    /// palette did not turn every `/word` into something that gets sent.
    @Test func anUnknownCommandIsStillRefused() async throws {
        let root = try Self.makeSkillRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = Self.makeViewModel(skillRoot: root)
        vm.input = "/definitelynotaskill do a thing"

        let request = await vm.prepareRequest()

        #expect(request == nil)
        #expect(vm.refusedCommandText == "/definitelynotaskill do a thing")
    }
}
