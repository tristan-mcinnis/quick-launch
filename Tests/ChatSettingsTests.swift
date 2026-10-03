// ChatSettingsTests — Settings for chats (v1.5.0 group G3): the Chat card's
// chat defaults, Keep AI Chat on top on the window's own key, the status
// lines for Continue in pi and the tool backends, the history limit, and the
// copy of the "Quick AI and AI Chat" card and the Welcome card.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Settings: Chat card, history limit, Welcome", .serialized)
@MainActor
struct ChatSettingsTests {

    private func decode(_ json: String) throws -> QuickSettings {
        try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
    }

    private func make(configure: (inout QuickSettings) -> Void = { _ in }) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        configure(&settings)
        return QuickViewModel(settings: settings, service: MockQuickService())
    }

    // MARK: - Chat defaults

    @Test func aNewInstallStartsWithAllFiveChatDefaultsOn() {
        let settings = QuickSettings()
        #expect(settings.newChatTools == Set(ChatToolKind.allCases))
        for tool in ChatToolKind.allCases {
            #expect(settings.isNewChatToolOn(tool), "\(tool.displayName)")
        }
    }

    @Test func anOldBlobSplitsTasksFromMemoryAndKeepsItsWebSearchChoice() throws {
        let off = try decode(#"{"configurationVersion":25,"modelWebSearchEnabled":false}"#)
        #expect(off.newChatTools == [.memory, .tasks, .vault, .skills])
        #expect(off.newChatMemoryEnabled)
        #expect(off.newChatTasksEnabled)
        let memoryOff = try decode(#"{"configurationVersion":25,"newChatMemoryEnabled":false}"#)
        #expect(!memoryOff.newChatMemoryEnabled)
        #expect(!memoryOff.newChatTasksEnabled, "the split preserves the old read scope")
        let bare = try decode(#"{"autoCopy":false}"#)
        #expect(bare.newChatTools == Set(ChatToolKind.allCases))
    }

    @Test func webSearchIsTheOneWebSearchSetting() throws {
        var settings = QuickSettings()
        settings.setNewChatTool(.web, on: false)
        #expect(settings.modelWebSearchEnabled == false, "one source of truth")
        settings.modelWebSearchEnabled = true
        #expect(settings.isNewChatToolOn(.web))

        settings.setNewChatTool(.memory, on: false)
        settings.setNewChatTool(.tasks, on: false)
        settings.setNewChatTool(.skills, on: false)
        let back = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.newChatTools == [.vault, .web])
        #expect(back.newChatMemoryEnabled == false)
        #expect(back.newChatTasksEnabled == false)
        #expect(back.newChatSkillsEnabled == false)
    }

    @Test func aNewChatStartsOnTheChatDefaults() {
        let vm = make {
            $0.newChatVaultEnabled = false
            $0.modelWebSearchEnabled = false
        }
        #expect(vm.chatTools == [.memory, .tasks, .skills])
        #expect(vm.chatToolsSummary == "Memory, Tasks, Skills on")
        // The switch changes the next chat; a chat's own choice still wins.
        vm.settings.newChatVaultEnabled = true
        #expect(vm.chatTools == [.memory, .tasks, .vault, .skills])
        vm.toggleChatTool(.memory)
        #expect(vm.chatTools == [.tasks, .vault, .skills])
    }

    @Test func theModelIsOfferedOnlyTheChatDefaults() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = QuickSettings()
        settings.newChatMemoryEnabled = false
        settings.newChatTasksEnabled = false
        settings.modelWebSearchEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            webSearchService: GatedWebSearchService(result: ""),
            vaultSearchService: FakeVault(outcome: .failure(VaultSearchError.empty))
        )
        vm.memoryService = FakeMemory()
        vm.skillLibrary = skills
        let provider = try #require(settings.providers.first { $0.kind == .openAICompatible })
        let service = try #require(vm.makeService(provider: provider, model: "deepseek-flash") as? OpenAICompatibleService)
        #expect(service.offeredToolNames == ["search_vault", "read_skill", "search_web"])
    }

    @Test func theAssistantEditorAndTheChatCardUseOneName() {
        #expect(QuickViewModel.toolSummary(nil) == "Chat defaults")
        #expect(ChatSettingsView.defaultsNote.hasPrefix("Chat defaults"))
        #expect(SavedPromptsEditor.toolsDetail.contains("Chat defaults"))
        #expect(SavedPromptsEditor.toolsDetail.contains("General \u{203A} Chat"))
        #expect(ChatSettingsView.detail(for: .web).contains("Translator"))
    }

    // MARK: - Keep AI Chat on top

    private func windowModel() -> (AIChatWindowModel, FakeAIChatWindow, UserDefaults) {
        let suite = "ChatSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AIChatWindowModel(chat: QuickViewModel(service: MockQuickService()), defaults: defaults)
        let fake = FakeAIChatWindow()
        model.window = fake
        return (model, fake, defaults)
    }

    /// Waits for `condition`, loudly. A silent give-up left the assertion
    /// after the call reporting the symptom instead of the wait.
    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return }
        Issue.record("the settings wait timed out after \(timeout)")
    }

    @Test func keepAIChatOnTopFromSettingsReachesTheOpenWindow() async {
        let (model, fake, defaults) = windowModel()
        #expect(!model.isAlwaysOnTop)
        // What the Settings switch does: write the window's own key.
        defaults.set(true, forKey: AIChatWindowModel.alwaysOnTopDefaultsKey)
        await waitUntil { model.isAlwaysOnTop }
        #expect(model.isAlwaysOnTop)
        #expect(fake.onTop == [true])

        defaults.set(false, forKey: AIChatWindowModel.alwaysOnTopDefaultsKey)
        await waitUntil { !model.isAlwaysOnTop }
        #expect(!model.isAlwaysOnTop)
        #expect(fake.onTop == [true, false])
    }

    @Test func theWindowsOwnToggleWritesTheKeySettingsReads() async {
        let (model, fake, defaults) = windowModel()
        model.isAlwaysOnTop = true
        #expect(defaults.bool(forKey: AIChatWindowModel.alwaysOnTopDefaultsKey))
        // The write's own change notification reads back the same value.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.isAlwaysOnTop)
        #expect(fake.onTop == [true], "no second call to the window")
        model.syncAlwaysOnTopFromDefaults()
        #expect(fake.onTop == [true])
    }

    // MARK: - Status lines

    actor CallLog {
        var calls: [(URL, [String])] = []
        func add(_ executable: URL, _ arguments: [String]) { calls.append((executable, arguments)) }
    }

    private func probe(
        found: Set<String>,
        ghostty: Bool,
        sshConfig: String?,
        log: CallLog = CallLog()
    ) -> ChatBackendProbe {
        ChatBackendProbe(
            resolve: { name in found.contains(name) ? URL(fileURLWithPath: "/opt/homebrew/bin/\(name)") : nil },
            applicationURL: { _ in ghostty ? URL(fileURLWithPath: "/Applications/Ghostty.app") : nil },
            run: { executable, arguments, _ in
                await log.add(executable, arguments)
                guard let sshConfig else { throw ProcessRunnerError.timedOut(executable: "ssh", seconds: 3) }
                return ProcessResult(stdout: Data(sshConfig.utf8), stderr: Data(), status: 0)
            },
            vaultHost: "example-host"
        )
    }

    @Test func everythingFoundIsReady() async {
        let log = CallLog()
        let status = await probe(
            found: ["tmux", "pi", "recall"],
            ghostty: true,
            sshConfig: "user ubuntu\nhostname 203.0.113.7\nport 22\n",
            log: log
        ).probe()
        #expect(status == ChatBackendStatus(
            tmuxFound: true, piFound: true, ghosttyFound: true, recallFound: true, vaultHostConfigured: true,
            vaultHost: "example-host"
        ))
        #expect(status.piLevel == .ready)
        #expect(status.piLine == "tmux, pi and Ghostty found.")
        #expect(status.toolsLevel == .ready)
        #expect(status.toolsLine == "recall found. example-host is in your SSH config.")
        // `ssh -G` reads the config and never connects; argv, no shell.
        let calls = await log.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == SSHRunner.executable)
        #expect(calls.first?.1 == ["-G", "example-host"])
    }

    @Test func missingProgramsAreNamed() async {
        let status = await probe(found: ["tmux"], ghostty: false, sshConfig: "hostname example-host\n").probe()
        #expect(status.piLevel == .missing)
        #expect(status.piLine == "pi and Ghostty not found. Continue in pi needs tmux and pi.")
        #expect(status.toolsLevel == .missing)
        #expect(status.toolsLine == "recall not found, so Memory cannot run. example-host is not in your SSH config.")
    }

    @Test func onlyGhosttyMissingIsPartlyReady() async {
        let status = await probe(found: ["tmux", "pi"], ghostty: false, sshConfig: nil).probe()
        #expect(status.piLevel == .partial)
        #expect(status.piLine == "Ghostty not found. pi still starts in tmux.")
        #expect(status.vaultHostConfigured == false, "ssh failing reads as not configured")
        #expect(status.toolsLevel == .missing)
    }

    @Test func aHostWithAHostNameOfItsOwnIsConfigured() {
        #expect(ChatBackendProbe.isConfigured(sshConfig: "user ubuntu\nhostname 10.0.0.2", host: "example-host"))
        #expect(!ChatBackendProbe.isConfigured(sshConfig: "hostname example-host\nport 22", host: "example-host"))
        #expect(!ChatBackendProbe.isConfigured(sshConfig: "hostname EXAMPLE-HOST", host: "example-host"))
        #expect(!ChatBackendProbe.isConfigured(sshConfig: "", host: "example-host"))
        #expect(ChatBackendProbe.sshConfigArguments(host: "example-host") == ["-G", "example-host"])
    }

    actor FixedProbe: ChatBackendProbing {
        let status: ChatBackendStatus
        var count = 0
        init(_ status: ChatBackendStatus) { self.status = status }
        func probe() async -> ChatBackendStatus { count += 1; return status }
    }

    @Test func settingsKeepsTheProbesAnswer() async {
        let vm = make()
        await vm.refreshChatBackendStatus()
        #expect(vm.chatBackendStatus == nil, "no probe, no lookups")

        let status = ChatBackendStatus(
            tmuxFound: true, piFound: false, ghosttyFound: true, recallFound: true, vaultHostConfigured: false
        )
        let fixed = FixedProbe(status)
        vm.chatBackendProbe = fixed
        await vm.refreshChatBackendStatus()
        #expect(vm.chatBackendStatus == status)
        #expect(await fixed.count == 1)
    }

    @Test func aMacWithoutTheHouseBackendsIsNotOfferedTheirTools() {
        func status(recall: Bool, vault: Bool) -> ChatBackendStatus {
            ChatBackendStatus(
                tmuxFound: false, piFound: false, ghosttyFound: false,
                recallFound: recall, vaultHostConfigured: vault
            )
        }
        let vm = make()
        vm.memoryService = FakeMemory()
        vm.vaultSearchService = FakeVault(outcome: .failure(VaultSearchError.empty))
        vm.dropMissingChatBackends(status(recall: true, vault: true))
        #expect(vm.isChatToolAvailable(.memory) && vm.isChatToolAvailable(.vault), "both found: both stay")

        vm.dropMissingChatBackends(status(recall: false, vault: false))
        #expect(!vm.isChatToolAvailable(.memory))
        #expect(!vm.isChatToolAvailable(.tasks))
        #expect(!vm.isChatToolAvailable(.vault))
    }

    // MARK: - History limit

    @Test func aNewInstallKeeps100ChatsAndAStoredLimitIsKept() throws {
        #expect(QuickSettings().historyLimit == 100)
        #expect(QuickHistoryStore.defaultLimit == 100)
        #expect(QuickHistoryStore.limitOptions == [20, 50, 100, 200])
        #expect(try decode(#"{"autoCopy":false}"#).historyLimit == 100, "a missing key is the new default")
        #expect(try decode(#"{"historyLimit":20}"#).historyLimit == 20, "the old default, stored, is kept")
        #expect(try decode(#"{"historyLimit":200}"#).historyLimit == 200)
    }

    @Test func thePickerShowsAStoredValueOutsideTheList() {
        #expect(make().historyLimitChoices == [20, 50, 100, 200])
        #expect(make { $0.historyLimit = 30 }.historyLimitChoices == [20, 30, 50, 100, 200])
    }

    private func chat(_ title: String, age: TimeInterval, pinned: Bool = false) -> QuickConversation {
        var conversation = QuickConversation(
            providerID: QuickSettings().providers[0].id,
            model: "model",
            messages: [QuickMessage(role: .user, content: title), QuickMessage(role: .assistant, content: "ok")]
        )
        conversation.isPinned = pinned
        conversation.updatedAt = Date(timeIntervalSinceNow: -age)
        return conversation
    }

    @Test func aLowerLimitPrunesTheOldestUnpinnedChatsAndNeverAPinnedOne() throws {
        let original = QuickSettings.load(from: .standard).historyLimit
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("g3-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = QuickSettings()
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), historyFileURL: file)
        defer { vm.updateSettings { $0.historyLimit = original } }
        vm.history = [
            chat("Pinned old", age: 9_000, pinned: true),
            chat("One", age: 10),
            chat("Two", age: 20),
            chat("Three", age: 30),
            chat("Pinned older", age: 10_000, pinned: true),
            chat("Four", age: 40),
        ]

        vm.setHistoryLimit(2)
        #expect(vm.settings.historyLimit == 2)
        #expect(QuickSettings.load(from: .standard).historyLimit == 2, "saved")
        let titles = Set(vm.history.map(\.title))
        #expect(titles == ["Pinned old", "Pinned older", "One", "Two"])

        QuickHistoryStore.waitForPendingWrites()
        let onDisk = QuickHistoryStore.load(from: file, migratingFrom: nil)
        #expect(Set(onDisk.map(\.title)) == titles, "the file is pruned too")

        // A higher limit keeps what is left; it brings nothing back.
        vm.setHistoryLimit(100)
        #expect(vm.history.count == 4)
    }

    // MARK: - Copy

    @Test func theQuickAICardNamesBothWindowsAndTellsTheTruthAboutTab() {
        #expect(QuickAISettingsView.title == "Quick AI and AI Chat")
        #expect(QuickAIPrimaryAction.pasteToActiveApp.detail
            == "In Quick AI, Return pastes the answer into the app behind. AI Chat always copies.")
        #expect(QuickAIPrimaryAction.copyToClipboard.detail.contains("AI Chat"))
        #expect(QuickAISettingsView.tabShortcutDetail.contains("math and conversions answer in place"))
        let copy = [
            QuickAISettingsView.title,
            QuickAISettingsView.tabShortcutDetail,
            QuickAIPrimaryAction.pasteToActiveApp.detail,
            QuickAIPrimaryAction.copyToClipboard.detail,
            ChatSettingsView.defaultsNote,
            SavedPromptsEditor.toolsDetail,
        ]
        for line in copy { #expect(!line.contains("\u{2014}"), "no em dash: \(line)") }
    }

    @Test func theWelcomeCardDescribesTodaysApp() {
        let lines = WelcomeOverlayView.lines(hotkey: QuickSettings().hotkeyDisplayName).map(\.text)
        #expect(lines == [
            "\u{2325}Space opens search",
            "Tab asks Quick AI",
            "\u{2318}J opens AI Chat",
            "@ adds context",
            "Tools can read your memory and the vault",
        ])
        #expect(WelcomeOverlayView.lines(hotkey: "\u{2303}Space").first?.text == "\u{2303}Space opens search")
        for line in lines + [WelcomeOverlayView.summary] {
            #expect(!line.contains("\u{2014}"))
            #expect(!line.localizedCaseInsensitiveContains("clipboard"), "auto-copy is not the product any more")
        }
    }
}
