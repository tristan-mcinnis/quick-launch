// PiHandoffTests: Continue in pi (plan Phase E, docs/ai-chat-plan-20260911.md
// section 7): the thread written as Markdown, the exact argv of each step
// (tmux's PATH lookup, the detached session running pi on the file, Ghostty
// attached through `open`), the owner-only bounded folder, and the `⌥⌘P`
// action on the Quick AI surface with its closing line.
//
// Every process call goes to a fake runner: no test starts tmux, pi, or
// Ghostty. The one live round trip is in the Phase E report, not here.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Records every argv and answers from a script, in place of
/// `ProcessRunner.run`.
actor FakePiHandoffRunner {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    private(set) var calls: [Call] = []
    private let respond: @Sendable (Call) throws -> ProcessResult

    init(respond: @escaping @Sendable (Call) throws -> ProcessResult) {
        self.respond = respond
    }

    func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult {
        let call = Call(executable: executable.path, arguments: arguments, timeout: timeout)
        calls.append(call)
        return try respond(call)
    }

    /// A tmux server that is running with `serverPath`, a session that
    /// starts, and an `open` that exits with `openStatus`.
    static func standard(serverPath: String? = "/usr/bin:/opt/homebrew/bin", openStatus: Int32 = 0) -> FakePiHandoffRunner {
        FakePiHandoffRunner { call in
            if call.arguments.first == "show-environment" {
                guard let serverPath else {
                    return result(status: 1, stderr: "no server running on /private/tmp/tmux-501/default")
                }
                return result(status: 0, stdout: "PATH=\(serverPath)\n")
            }
            if call.executable == PiHandoffService.openExecutable.path {
                return result(status: openStatus, stderr: openStatus == 0 ? "" : "Unable to find application")
            }
            return result(status: 0)
        }
    }

    static func result(status: Int32, stdout: String = "", stderr: String = "") -> ProcessResult {
        ProcessResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), status: status)
    }
}

/// Values the fakes read off the main actor.
private enum Fixture {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-11 08:27:37 UTC.
    static let date = Date(timeIntervalSince1970: 1_789_115_257)
    static let tmux = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
    static let pi = URL(fileURLWithPath: "/opt/homebrew/bin/pi")
    static let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
}

@Suite("Continue in pi", .serialized)
@MainActor
struct PiHandoffTests {

    // MARK: - Fixtures

    private static let utc = Fixture.utc
    private static let date = Fixture.date
    private static let tmux = Fixture.tmux
    private static let pi = Fixture.pi

    private struct Sandbox {
        let root: URL
        var directory: URL { root.appendingPathComponent("Quick Launch/pi-handoff", isDirectory: true) }
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    }

    private func sandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Sandbox(root: root)
    }

    private func service(
        _ box: Sandbox,
        runner: FakePiHandoffRunner,
        resolve: @escaping PiHandoffService.Resolve = { name in
            ["tmux": Fixture.tmux, "pi": Fixture.pi, "node": Fixture.node][name]
        },
        launchPath: String? = "/usr/bin:/bin:/usr/sbin:/sbin",
        shortID: String = "3fa9c1"
    ) -> PiHandoffService {
        PiHandoffService(
            directory: box.directory,
            home: box.home,
            run: { try await runner.run($0, $1, $2) },
            resolve: resolve,
            launchPath: launchPath,
            timeZone: Self.utc,
            now: { Fixture.date },
            makeShortID: { shortID }
        )
    }

    private static let thread = [
        QuickMessage(role: .user, content: "Who founded Raycast?"),
        QuickMessage(role: .assistant, content: "Thomas Paul Mann and Petr Nikolaev, per [Raycast](https://www.raycast.com/about)."),
        QuickMessage(role: .user, content: "  And when?\n"),
        QuickMessage(role: .assistant, content: "In 2020."),
    ]

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    // MARK: - The document

    @Test func theThreadIsMarkdownWithTitleSpeakersToolLinesAndSources() {
        let markdown = PiHandoffDocument.markdown(
            title: "Who founded Raycast",
            modelName: "DeepSeek V4.1 Flash",
            messages: Self.thread,
            toolLines: [Self.thread[1].id: ["Search web: Raycast founder"]],
            date: Self.date,
            timeZone: Self.utc
        )
        #expect(markdown == """
        # Who founded Raycast

        A Quick AI chat from Quick Launch, 2026-09-11 08:27, with DeepSeek V4.1 Flash.

        ---

        You:

        Who founded Raycast?

        ---

        DeepSeek V4.1 Flash:

        Tool: Search web: Raycast founder

        Thomas Paul Mann and Petr Nikolaev, per [Raycast](https://www.raycast.com/about).

        ---

        You:

        And when?

        ---

        DeepSeek V4.1 Flash:

        In 2020.

        """)
    }

    @Test func aQuestionTheModelAskedIsWrittenWithItsOptionsAndThePick() {
        let question = AskUserQuestion(
            question: "Which city?",
            options: [AskUserQuestionOption(label: "Lima"), AskUserQuestionOption(label: "Cusco")],
            selectedIndex: 1
        )
        let markdown = PiHandoffDocument.markdown(
            title: "Trip",
            modelName: "",
            messages: [
                QuickMessage(role: .user, content: "Plan a trip"),
                QuickMessage(role: .assistant, content: "Which city?", askUserQuestion: question),
                QuickMessage(role: .user, content: "Cusco"),
            ],
            date: Self.date,
            timeZone: Self.utc
        )
        #expect(markdown.contains("""
        Assistant:

        Asked: Which city?

        Options: Lima / Cusco

        ---

        You:

        Cusco
        """))
    }

    @Test func attachmentsAreListedUnderTheirQuestionWithTheirTextAndNoPictures() {
        let pdf = ChatAttachmentRef(
            kind: .pdf, name: "Q3 report.pdf", pageCount: 42, contentHash: "h1", extractorVersion: 1,
            path: "/Users/me/Documents/Q3 report.pdf"
        )
        let link = ChatAttachmentRef(
            kind: .link, name: "Pricing | Example", contentHash: "h2", extractorVersion: 1,
            url: URL(string: "https://example.com/pricing")
        )
        let shot = ChatAttachmentRef(kind: .screenshot, name: "Screenshot", pixelWidth: 1_944, pixelHeight: 1_464)
        let gone = ChatAttachmentRef(
            kind: .word, name: "Old notes.docx", contentHash: "h3", extractorVersion: 1,
            path: "/Users/me/Old notes.docx"
        )
        let texts = [pdf.id: "--- Page 1 ---\nRevenue rose 12%.", link.id: "Pricing\n```js\ncode()\n```\nFree, Pro."]
        let markdown = PiHandoffDocument.markdown(
            title: "Quarter",
            modelName: "DeepSeek V4.1 Flash",
            messages: [
                QuickMessage(role: .user, content: "Compare these", attachments: [pdf, link, shot, gone]),
                QuickMessage(role: .assistant, content: "Revenue rose."),
            ],
            attachmentText: { texts[$0.id] },
            date: Self.date,
            timeZone: Self.utc
        )
        #expect(markdown == """
        # Quarter

        A Quick AI chat from Quick Launch, 2026-09-11 08:27, with DeepSeek V4.1 Flash.

        ---

        You:

        Compare these

        Attachments:
        - Q3 report.pdf (PDF, 42 pages): `/Users/me/Documents/Q3 report.pdf`
        - Pricing | Example (Web page): https://example.com/pricing
        - Screenshot (Screenshot, 1944 × 1464): not carried to pi
        - Old notes.docx (Word document): `/Users/me/Old notes.docx`, text not loaded in this session

        Text of Q3 report.pdf:

        ```text
        --- Page 1 ---
        Revenue rose 12%.
        ```

        Text of Pricing | Example:

        ````text
        Pricing
        ```js
        code()
        ```
        Free, Pro.
        ````

        ---

        DeepSeek V4.1 Flash:

        Revenue rose.

        """)
    }

    @Test func continueInPiCarriesTheSessionsAttachmentTextAndWritesNoSidecar() async throws {
        let extractor = FakeAttachmentExtractor()
        await extractor.set(.content(AttachmentFlowTests.document("brief.txt", text: "The brief text.")), for: "brief.txt")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Read.", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings, service: mock, workspace: FakeWorkspace(), attachmentExtractor: extractor)
        vm.openQuickAI()
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("brief.txt")))
        vm.attachmentTray.add(.image(AttachmentFlowTests.image, name: "Pasted image", kind: .image))
        await vm.attachmentTray.waitUntilRead()
        vm.input = "read it"
        await vm.submit()
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard()
        vm.piHandoff = service(box, runner: runner)

        await vm.continueInPi()

        let calls = await runner.calls
        let fileArgument = try #require(calls[1].arguments.first { $0.hasPrefix("@") })
        let path = String(fileArgument.dropFirst())
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("- brief.txt (Text file): `/tmp/quick-launch-attachment-flow/brief.txt`"))
        #expect(text.contains("```text\nThe brief text.\n```"))
        #expect(text.contains("- Pasted image (Image, 40 × 30): not carried to pi"))
        #expect(try permissions(URL(fileURLWithPath: path)) == 0o600)
        let written = try FileManager.default.contentsOfDirectory(atPath: box.directory.path)
        #expect(written == [URL(fileURLWithPath: path).lastPathComponent], "one thread file, no sidecar, no image")
    }

    @Test func fileNamesSortByTimeAndCarryATitleSlug() {
        #expect(PiHandoffDocument.fileName(date: Self.date, title: "Who founded Raycast?", timeZone: Self.utc)
            == "20260911-082737-who-founded-raycast.md")
        #expect(PiHandoffDocument.slug(for: "Café  plans: Q3 / Q4!") == "cafe-plans-q3-q4")
        #expect(PiHandoffDocument.slug(for: "上海 天气") == "chat")
        #expect(PiHandoffDocument.slug(for: String(repeating: "word ", count: 20)).count
            <= PiHandoffDocument.slugCharacterLimit)
        #expect(!PiHandoffDocument.slug(for: String(repeating: "word ", count: 20)).hasSuffix("-"))
    }

    // MARK: - The steps

    @Test func theStepsRunInOrderWithTheExactArgv() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard(serverPath: "/Users/me/.cargo/bin:/usr/bin:/opt/homebrew/bin")
        let markdown = "# Who founded Raycast\n\nThe thread.\n"
        let result = try await service(box, runner: runner).handOff(PiHandoffRequest(
            title: "Who founded Raycast",
            markdown: markdown
        ))

        let file = box.directory.appendingPathComponent("20260911-082737-who-founded-raycast.md")
        #expect(result == PiHandoffResult(sessionName: "ql-3fa9c1", threadFile: file, openedGhostty: true))
        #expect(result.attachCommand == "tmux attach -t ql-3fa9c1")

        // The server's PATH first, in its order; then what it lacks.
        let home = box.home.path
        let path = [
            "/Users/me/.cargo/bin", "/usr/bin", "/opt/homebrew/bin",
            "\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.lmstudio/bin",
            "/usr/local/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        let calls = await runner.calls
        #expect(calls == [
            .init(
                executable: "/opt/homebrew/bin/tmux",
                arguments: ["show-environment", "-g", "PATH"],
                timeout: PiHandoffService.stepTimeout
            ),
            .init(
                executable: "/opt/homebrew/bin/tmux",
                arguments: [
                    "new-session", "-d", "-s", "ql-3fa9c1", "-c", home,
                    "-e", "PATH=\(path)",
                    "/opt/homebrew/bin/pi", "@\(file.path)",
                    "Continue this conversation from Quick Launch. The thread is attached.",
                ],
                timeout: PiHandoffService.stepTimeout
            ),
            .init(
                executable: "/usr/bin/open",
                arguments: [
                    "-n", "-b", "com.mitchellh.ghostty",
                    "--args", "-e", "/opt/homebrew/bin/tmux", "attach-session", "-t", "ql-3fa9c1",
                ],
                timeout: PiHandoffService.stepTimeout
            ),
        ])

        // The file pi reads is the thread, owner-only in an owner-only folder.
        #expect(try String(contentsOf: file, encoding: .utf8) == markdown)
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(box.directory) == 0o700)
    }

    @Test func withNoTmuxServerTheSessionPathIsTheAppsPathPlusTheCLIFolders() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard(serverPath: nil)
        let folder = box.root.appendingPathComponent("project", isDirectory: true)
        _ = try await service(box, runner: runner, launchPath: "/usr/bin:/bin:/usr/sbin:/sbin")
            .handOff(PiHandoffRequest(title: "T", markdown: "x", workingDirectory: folder))

        let newSession = try #require(await runner.calls.dropFirst().first)
        let home = box.home.path
        // launchd's PATH has no node: pi's `#!/usr/bin/env node` needs this.
        #expect(newSession.arguments.contains(
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(home)/.local/bin:\(home)/.opencode/bin:\(home)/.lmstudio/bin:/usr/local/bin"
        ))
        #expect(Array(newSession.arguments.prefix(6)) == ["new-session", "-d", "-s", "ql-3fa9c1", "-c", folder.path])
    }

    @Test func aGhosttyThatDoesNotOpenStillLeavesTheSessionRunning() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard(openStatus: 1)
        let result = try await service(box, runner: runner).handOff(PiHandoffRequest(title: "T", markdown: "x"))
        #expect(!result.openedGhostty)
        #expect(result.sessionName == "ql-3fa9c1")
        #expect(await runner.calls.count == 3)
    }

    @Test func aSessionThatFailsToStartReportsTmuxAndNeverOpensGhostty() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner { call in
            call.arguments.first == "new-session"
                ? FakePiHandoffRunner.result(status: 1, stderr: "duplicate session: ql-3fa9c1")
                : FakePiHandoffRunner.result(status: 1)
        }
        await #expect(throws: PiHandoffError.sessionFailed("duplicate session: ql-3fa9c1")) {
            _ = try await service(box, runner: runner).handOff(PiHandoffRequest(title: "T", markdown: "x"))
        }
        #expect(await runner.calls.map(\.executable) == ["/opt/homebrew/bin/tmux", "/opt/homebrew/bin/tmux"])
    }

    @Test func aMissingCLIIsNamedAndNothingRunsOrIsWritten() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard()
        let noPi = service(box, runner: runner, resolve: { $0 == "tmux" ? Fixture.tmux : nil })
        await #expect(throws: PiHandoffError.missingExecutable("pi")) {
            _ = try await noPi.handOff(PiHandoffRequest(title: "T", markdown: "x"))
        }
        let noTmux = service(box, runner: runner, resolve: { $0 == "pi" ? Fixture.pi : nil })
        await #expect(throws: PiHandoffError.missingExecutable("tmux")) {
            _ = try await noTmux.handOff(PiHandoffRequest(title: "T", markdown: "x"))
        }
        #expect(await runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.directory.path))
        #expect(PiHandoffError.missingExecutable("pi").errorDescription
            == "Continue in pi needs pi on this Mac. Install it, then try again.")
    }

    @Test func theFolderKeepsTheNewestTwentyThreads() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let old = (1...24).map { String(format: "20260901-0000%02d-old.md", $0) }
        for name in old {
            try Data("old".utf8).write(to: box.directory.appendingPathComponent(name))
        }
        let result = try await service(box, runner: .standard()).handOff(PiHandoffRequest(title: "New", markdown: "x"))

        let kept = try FileManager.default.contentsOfDirectory(atPath: box.directory.path).sorted()
        #expect(kept.count == PiHandoffService.retainedFileCount)
        #expect(kept.last == result.threadFile.lastPathComponent)
        #expect(kept.first == old[5], "the five oldest went")
    }

    @Test func twoHandOffsInOneSecondGetTwoFiles() async throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let first = try await service(box, runner: .standard(), shortID: "aaaaaa")
            .handOff(PiHandoffRequest(title: "Same", markdown: "one"))
        let second = try await service(box, runner: .standard(), shortID: "bbbbbb")
            .handOff(PiHandoffRequest(title: "Same", markdown: "two"))
        #expect(first.threadFile.lastPathComponent == "20260911-082737-same.md")
        #expect(second.threadFile.lastPathComponent == "20260911-082737-same-bbbbbb.md")
        #expect(try String(contentsOf: first.threadFile, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second.threadFile, encoding: .utf8) == "two")
    }

    // MARK: - The action

    private func answeredViewModel(
        pasteboard: FakePasteboard = FakePasteboard()
    ) async -> (QuickViewModel, MockQuickService) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: pasteboard)
        await mock.setResponses([StreamDelta(text: "Lima.", finishReason: "stop")])
        vm.input = "what is the capital of peru"
        await vm.submit()
        return (vm, mock)
    }

    @Test func theActionIsOfferedOnlyWithAThreadAndAHandoff() async throws {
        let (vm, _) = await answeredViewModel()
        #expect(!vm.resultActions.contains(.continueInPi), "no hand-off set, as in every other test")
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        vm.piHandoff = service(box, runner: .standard())
        #expect(vm.resultActions.contains(.continueInPi))
        #expect(vm.resultActions.firstIndex(of: .continueInPi) == vm.resultActions.firstIndex(of: .copyChat).map { $0 + 1 })
        #expect(ResultAction.continueInPi.title == "Continue in pi")
        #expect(ResultAction.continueInPi.defaultShortcut.keyCaps == ["⌥", "⌘", "P"])
        #expect(vm.resultActionDetail(.continueInPi) == "New tmux session in Ghostty")
        vm.handleCommandK()
        vm.actionQuery = "continue"
        #expect(vm.paletteResultActions.first == .continueInPi)

        // A local answer with no chat behind it is not a thread.
        vm.startNewConversation()
        vm.input = "2+2"
        await vm.submit()
        #expect(vm.output == "4")
        #expect(!vm.resultActions.contains(.continueInPi))
    }

    @Test func continueInPiWritesTheThreadAndEndsItWithTheSessionLine() async throws {
        let (vm, _) = await answeredViewModel()
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let runner = FakePiHandoffRunner.standard()
        vm.piHandoff = service(box, runner: runner)
        vm.webSearchNote = "Search web: capital of Peru"
        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)

        await vm.performResultAction(.continueInPi)

        #expect(!vm.isActionPalettePresented)
        #expect(vm.threadNotice == "Opened in pi · tmux session ql-3fa9c1")
        #expect(vm.errorMessage == nil)
        #expect(vm.isQuickAIPresented, "the surface stays open")
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/opt/homebrew/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/bin/open"])
        let fileArgument = try #require(calls[1].arguments.first { $0.hasPrefix("@") })
        let text = try String(contentsOfFile: String(fileArgument.dropFirst()), encoding: .utf8)
        let model = ModelProfile.displayName(forModelID: try #require(vm.currentConversation?.model))
        #expect(text.hasPrefix("# What is the capital of peru\n\nA Quick AI chat from Quick Launch, "))
        #expect(text.hasSuffix("""
        ---

        You:

        what is the capital of peru

        ---

        \(model):

        Tool: Search web: capital of Peru

        Lima.

        """))
    }

    @Test func whenGhosttyDoesNotOpenTheAttachCommandIsCopied() async throws {
        let pasteboard = FakePasteboard()
        let (vm, _) = await answeredViewModel(pasteboard: pasteboard)
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        vm.piHandoff = service(box, runner: .standard(openStatus: 1))
        await vm.performResultAction(.continueInPi)
        #expect(pasteboard.string == "tmux attach -t ql-3fa9c1")
        #expect(vm.threadNotice == "Started pi in tmux session ql-3fa9c1 · Ghostty did not open, attach command copied")
    }

    @Test func aFailedHandOffShowsTheErrorAndNoLine() async throws {
        let (vm, _) = await answeredViewModel()
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        vm.piHandoff = service(box, runner: .standard(), resolve: { _ in nil })
        await vm.performResultAction(.continueInPi)
        #expect(vm.threadNotice == nil)
        #expect(vm.errorMessage == "Continue in pi needs tmux on this Mac. Install it, then try again.")
    }

    @Test func theSessionLineLeavesWithTheNextQuestionOrANewChat() async throws {
        let (vm, mock) = await answeredViewModel()
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        vm.piHandoff = service(box, runner: .standard())

        await vm.performResultAction(.continueInPi)
        #expect(vm.threadNotice != nil)
        await mock.setResponses([StreamDelta(text: "About 10 million.", finishReason: "stop")])
        vm.input = "how many people live there"
        await vm.submit()
        #expect(vm.threadNotice == nil, "a follow-up clears it")

        await vm.performResultAction(.continueInPi)
        #expect(vm.threadNotice != nil)
        vm.startNewConversation()
        #expect(vm.threadNotice == nil, "a new chat clears it")
    }

    // MARK: - The key

    /// ⌥⌘P was checked against every key table: the answer actions, the
    /// overlay's own keys, the ⌘K row actions of every kind, and the
    /// default global hotkeys.
    @Test func optionCommandPIsFreeEverywhere() {
        let key = ResultAction.continueInPi.defaultShortcut
        let answerKeys = ResultAction.allCases.filter { $0 != .continueInPi }.map(\.defaultShortcut)
        let overlayKeys: [KeyShortcut] = [
            QuickViewModel.recentChatsShortcut,
            QuickViewModel.transformChooserShortcut,
            QuickViewModel.transcriptCollapseShortcut,
        ]
        let kinds: [LauncherItemKind] = [
            .snippet, .quickLink, .clipboard, .command, .emoji, .screenshot,
            .conversation, .askAI, .folder, .answer, .screenHistory, .color,
        ]
        var results: [LauncherSearchResult] = kinds.map { kind in
            .item(LauncherCatalogItem(
                kind: kind,
                itemID: kind == .color ? "#FF0000" : "item",
                title: "Item",
                detail: "",
                value: "https://example.com/?utm_source=proof",
                keywords: "has-local-file"
            ))
        }
        results.append(.catalog(.chats, count: 1))
        let app = LaunchableApplication(name: "Notes", bundleIdentifier: "com.apple.Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        results.append(.application(app))
        var rowKeys = results.flatMap { ItemActionCatalog.actions(for: $0, pasteTarget: nil).compactMap(\.shortcut) }
        rowKeys += ItemActionCatalog.actions(for: .application(app), pasteTarget: nil, isRunning: true).compactMap(\.shortcut)

        #expect(!answerKeys.contains(key))
        #expect(!overlayKeys.contains(key))
        #expect(!rowKeys.contains(key))

        // Global hotkeys are key codes: P is 35, ⌥⌘ is 1_572_864.
        let optionCommandP = ActionHotkey(keyCode: 35, modifiers: 1_572_864)
        let settings = QuickSettings()
        var globals = [settings.clipboardHistoryHotkey, settings.translatorHotkey, settings.typeToClickHotkey]
        globals += settings.savedPrompts.compactMap(\.hotkey)
        globals += settings.launcherItemConfigurations.compactMap(\.hotkey)
        #expect(!globals.contains(optionCommandP))
        #expect(!(settings.hotkeyKeyCode == 35 && settings.hotkeyModifiers == 1_572_864))
    }

    @Test func optionCommandPThroughThePanelHandsTheThreadOff() async throws {
        let (vm, _) = await answeredViewModel()
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        vm.piHandoff = service(box, runner: .standard())

        _ = NSApplication.shared
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 120),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // As AppDelegate wires it.
        panel.shortcutHandler = { [weak vm] characters, keyCode, modifiers in
            vm?.performShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers) ?? false
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "π",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(panel.performKeyEquivalent(with: event))

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while vm.threadNotice == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        if vm.threadNotice == nil { Issue.record("the handoff notice never arrived") }
        #expect(vm.threadNotice == "Opened in pi · tmux session ql-3fa9c1")
    }
}
