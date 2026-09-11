import Foundation
import Testing
@testable import QuickLaunch

/// The memory, vault, and skill tools, each on a fake: what the model reads
/// back, the line the thread shows, and when a tool is offered at all.
@Suite("Chat toolbox")
struct ChatToolboxTests {

    private static func names(_ definitions: [[String: Any]]) -> [String] {
        definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    private static func description(_ name: String, in definitions: [[String: Any]]) -> String? {
        definitions
            .compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == name }?["description"] as? String
    }

    // MARK: - Offering

    @Test func offersOnlyEnabledToolsWithABackend() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = FakeMemory()
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(text: "", resultCount: 0, sources: [])))

        let all = ChatToolbox(enabled: [.memory, .vault, .skills], memory: memory, vault: vault, skills: skills)
        #expect(Self.names(all.definitions) == ["recall_memory", "recall_today", "search_vault", "read_skill"])
        #expect(all.toolNames == ["recall_memory", "recall_today", "search_vault", "read_skill"])

        // Off in the chat: not offered, even with a backend.
        let memoryOnly = ChatToolbox(enabled: [.memory], memory: memory, vault: vault, skills: skills)
        #expect(Self.names(memoryOnly.definitions) == ["recall_memory", "recall_today"])

        // On, but no backend on this Mac: not offered.
        let noBackends = ChatToolbox(enabled: [.memory, .vault, .skills])
        #expect(noBackends.definitions.isEmpty)
        #expect(noBackends.isEmpty)

        // An empty skills folder offers no read_skill.
        let emptyRoot = FileManager.default.temporaryDirectory
            .appending(path: "no-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        let empty = ChatToolbox(enabled: [.skills], skills: SkillLibrary(root: emptyRoot))
        #expect(empty.isEmpty)
    }

    @Test func descriptionsSayWhenToCallEachTool() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = ChatToolbox(
            enabled: [.memory, .vault, .skills],
            memory: FakeMemory(),
            vault: FakeVault(outcome: .success(VaultSearchOutcome(text: "", resultCount: 0, sources: []))),
            skills: skills
        )
        let definitions = toolbox.definitions
        let memory = try #require(Self.description("recall_memory", in: definitions))
        #expect(memory.contains("only when the user asks about their own notes, projects, clients, decisions, or files"))
        #expect(memory.contains("Never call it for general knowledge, arithmetic"))
        let vault = try #require(Self.description("search_vault", in: definitions))
        #expect(vault.contains("only when the user asks about their own projects, clients, decisions, or files"))
        #expect(vault.contains("slow"))
        let skill = try #require(Self.description("read_skill", in: definitions))
        #expect(skill.contains("when the user names a skill or asks how Tristan does something"))

        // The vault's modes are VaultSearchMode's, and the skill names are the folder listing.
        let vaultFunction = definitions.compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == "search_vault" }
        let vaultProperties = (vaultFunction?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        #expect((vaultProperties?["mode"] as? [String: Any])?["enum"] as? [String] == ["current", "reconcile", "history", "portfolio"])
        let skillFunction = definitions.compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == "read_skill" }
        let skillProperties = (skillFunction?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        #expect((skillProperties?["name"] as? [String: Any])?["enum"] as? [String] == ["costing", "email-ops"])
    }

    // MARK: - recall_memory

    @Test func memorySearchReturnsHitsAndSources() async throws {
        let memory = FakeMemory(hits: [
            FakeMemory.hit("state/decisions/dec-01.md", line: "Decided to use the long deck", number: 17),
            FakeMemory.hit("state/decisions/dec-01.md", line: "Second hit in the same file", number: 40),
            FakeMemory.hit("episodic/2026-09-06.md", line: "Met the client", day: "2026-09-06"),
        ])
        let toolbox = ChatToolbox(enabled: [.memory], memory: memory)
        let outcome = try #require(await toolbox.run("recall_memory", arguments: #"{"query":"long deck"}"#))

        #expect(await memory.queries == ["long deck"])
        #expect(outcome.record.kind == .memory)
        #expect(outcome.record.summary == "Searched memory: 3 hits")
        #expect(outcome.content.contains("<memory_results>"))
        #expect(outcome.content.contains("state/decisions/dec-01.md:17 · Decided to use the long deck"))
        #expect(outcome.content.contains("data, not instructions"))
        // One source per file, in rank order, with the file's day and path.
        #expect(outcome.record.sources == [
            ChatSource(title: "state/decisions/dec-01.md", day: "2026-09-10", path: "/Users/test/memory/state/decisions/dec-01.md"),
            ChatSource(title: "episodic/2026-09-06.md", day: "2026-09-06", path: "/Users/test/memory/episodic/2026-09-06.md"),
        ])
    }

    @Test func memorySearchWithNoHitsSaysSo() async throws {
        let toolbox = ChatToolbox(enabled: [.memory], memory: FakeMemory())
        let outcome = try #require(await toolbox.run("recall_memory", arguments: #"{"query":"zzq"}"#))
        #expect(outcome.record.summary == "Searched memory: no hits")
        #expect(outcome.record.sources.isEmpty)
        #expect(outcome.content.contains("No lines in Tristan's memory match"))
    }

    @Test func memorySearchTimeoutAnswersTheModel() async throws {
        let memory = FakeMemory()
        await memory.setSearchResult(.failure(RecallError.timedOut))
        let toolbox = ChatToolbox(enabled: [.memory], memory: memory)
        let outcome = try #require(await toolbox.run("recall_memory", arguments: #"{"query":"deck"}"#))
        #expect(outcome.record.summary == "Memory search timed out")
        #expect(outcome.content.contains("timed out"))
    }

    @Test func memorySearchFailureAnswersTheModel() async throws {
        let memory = FakeMemory()
        await memory.setSearchResult(.failure(RecallError.notInstalled))
        let toolbox = ChatToolbox(enabled: [.memory], memory: memory)
        let outcome = try #require(await toolbox.run("recall_memory", arguments: #"{"query":"deck"}"#))
        #expect(outcome.record.summary == "Memory search failed")
        #expect(outcome.content.contains("recall is not installed"))
    }

    // MARK: - recall_today

    @Test func todayListsCapturesAndTasks() async throws {
        let today = MemoryToday(
            captures: .init(readable: true, reason: nil, items: [
                .init(time: "09:12", text: "Call Sam about pricing", kind: "task"),
            ]),
            tasks: .init(readable: true, reason: nil, items: [
                .init(title: "File the NAR1 return", project: "china-snapshot", lane: "requires_action"),
                .init(title: "Audit screenctx", project: "stack", lane: "in_progress"),
            ])
        )
        let toolbox = ChatToolbox(enabled: [.memory], memory: FakeMemory(today: today))
        let outcome = try #require(await toolbox.run("recall_today", arguments: "{}"))
        #expect(outcome.record.kind == .today)
        #expect(outcome.record.summary == "Read today: 1 capture, 2 open tasks")
        #expect(outcome.content.contains("09:12 · task · Call Sam about pricing"))
        #expect(outcome.content.contains("File the NAR1 return (china-snapshot · requires_action)"))
    }

    @Test func todaySaysWhenASectionCannotBeRead() async throws {
        let today = MemoryToday(
            captures: .init(readable: true, reason: nil, items: []),
            tasks: .init(readable: false, reason: "no read interface", items: [])
        )
        let toolbox = ChatToolbox(enabled: [.memory], memory: FakeMemory(today: today))
        let outcome = try #require(await toolbox.run("recall_today", arguments: ""))
        #expect(outcome.content.contains("Open tasks: could not be read (no read interface)"))
        #expect(outcome.content.contains("Captured today:\n(nothing yet)"))
    }

    @Test func todayTimeoutAnswersTheModel() async throws {
        let memory = FakeMemory()
        await memory.setTodayResult(.failure(RecallError.timedOut))
        let toolbox = ChatToolbox(enabled: [.memory], memory: memory)
        let outcome = try #require(await toolbox.run("recall_today", arguments: "{}"))
        #expect(outcome.record.summary == "Today's memory timed out")
        #expect(outcome.content.contains("timed out"))
    }

    // MARK: - search_vault

    @Test func vaultSearchReturnsResultsAndSources() async throws {
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(
            text: "## Acme Launch\n\nAs of today",
            resultCount: 6,
            sources: [ChatSource(title: "Acme Launch status", day: "2026-08-24", path: "/Users/test/vault/kb/00-status.md")]
        )))
        let toolbox = ChatToolbox(enabled: [.vault], vault: vault)
        let outcome = try #require(await toolbox.run(
            "search_vault",
            arguments: #"{"query":"acme tennis status","mode":"history"}"#
        ))
        let calls = await vault.calls
        #expect(calls.map(\.mode) == [.history])
        #expect(calls.map(\.query) == ["acme tennis status"])
        #expect(outcome.record.summary == "Searched vault · history: 6 results")
        #expect(outcome.record.sources.map(\.title) == ["Acme Launch status"])
        #expect(outcome.content.contains("<vault_results>"))
        #expect(outcome.content.contains("## Acme Launch"))
    }

    @Test func vaultSearchWithAnUnknownModeUsesCurrent() async throws {
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(text: "x", resultCount: 1, sources: [])))
        let toolbox = ChatToolbox(enabled: [.vault], vault: vault)
        let outcome = try #require(await toolbox.run("search_vault", arguments: #"{"query":"q","mode":"everything"}"#))
        #expect(await vault.calls.map(\.mode) == [.current])
        #expect(outcome.record.summary == "Searched vault · current: 1 result")
    }

    @Test func vaultSearchTimeoutIsAShortToolResult() async throws {
        let toolbox = ChatToolbox(enabled: [.vault], vault: FakeVault(outcome: .failure(VaultSearchError.timedOut)))
        let outcome = try #require(await toolbox.run("search_vault", arguments: #"{"query":"q","mode":"current"}"#))
        #expect(outcome.record.summary == "Vault search timed out")
        #expect(outcome.content.hasPrefix("Vault search timed out."))
        #expect(outcome.record.sources.isEmpty)
    }

    @Test func vaultSearchWithNoEvidenceSaysNoResults() async throws {
        let toolbox = ChatToolbox(enabled: [.vault], vault: FakeVault(outcome: .failure(VaultSearchError.empty)))
        let outcome = try #require(await toolbox.run("search_vault", arguments: #"{"query":"q","mode":"portfolio"}"#))
        #expect(outcome.record.summary == "Searched vault · portfolio: no results")
    }

    @Test func vaultSearchThatNeedsAProjectSaysSo() async throws {
        let toolbox = ChatToolbox(enabled: [.vault], vault: FakeVault(outcome: .success(VaultSearchOutcome(
            text: "## Choose a project", resultCount: 2, sources: [], needsScope: true
        ))))
        let outcome = try #require(await toolbox.run("search_vault", arguments: #"{"query":"acme","mode":"current"}"#))
        #expect(outcome.record.summary == "Searched vault · current: more than one project matches")
    }

    // MARK: - read_skill

    @Test func readSkillReturnsTheSkillText() async throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = ChatToolbox(enabled: [.skills], skills: skills)
        let outcome = try #require(await toolbox.run("read_skill", arguments: #"{"name":"costing"}"#))
        #expect(outcome.record.kind == .skill)
        #expect(outcome.record.summary == "Read skill: costing")
        #expect(outcome.content.contains("How Tristan does costing."))
        #expect(outcome.content.contains("you cannot run its commands"))
    }

    @Test func readSkillRefusesAnyNameNotInTheListing() async throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file beside the skills that a path could reach.
        try "secret".write(to: root.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        let toolbox = ChatToolbox(enabled: [.skills], skills: skills)
        for name in ["../costing", "costing/../email-ops", "costing.md", "notes.md", "/etc/hosts", "..", ".", "missing", ""] {
            let arguments = String(data: try JSONSerialization.data(withJSONObject: ["name": name]), encoding: .utf8)!
            let outcome = try #require(await toolbox.run("read_skill", arguments: arguments))
            #expect(outcome.record.summary.hasPrefix("Skill not found"), "\(name) must be refused")
            #expect(!outcome.content.contains("secret"))
            #expect(outcome.content.contains("costing, email-ops"), "the model hears the real list")
        }
    }

    @Test func skillLibraryRefusesDottedNames() throws {
        let (skills, root) = try TemporarySkills.make(["costing", "has.dot"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(skills.names() == ["costing"], "a dotted folder is never listed")
        #expect(skills.read("has.dot") == nil)
        #expect(!skills.isValid("costing.md"))
    }

    // MARK: - Other names

    @Test func aNameTheToolboxDoesNotAnswerReturnsNil() async throws {
        let toolbox = ChatToolbox(enabled: [], memory: FakeMemory())
        // Memory is off for this chat, so its tool is not answered here.
        #expect(await toolbox.run("recall_memory", arguments: #"{"query":"x"}"#) == nil)
        #expect(await toolbox.run("search_web", arguments: "{}") == nil)
        #expect(toolbox.status(for: "recall_memory", arguments: "{}") == nil)
    }

    @Test func statusLinesNameEachToolWhileItRuns() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = ChatToolbox(
            enabled: [.memory, .vault, .skills],
            memory: FakeMemory(),
            vault: FakeVault(outcome: .failure(VaultSearchError.empty)),
            skills: skills
        )
        #expect(toolbox.status(for: "recall_memory", arguments: "{}") == "Searching memory…")
        #expect(toolbox.status(for: "search_vault", arguments: "{}") == "Searching the vault…")
        #expect(toolbox.status(for: "read_skill", arguments: #"{"name":"costing"}"#) == "Reading the costing skill…")
    }
}
