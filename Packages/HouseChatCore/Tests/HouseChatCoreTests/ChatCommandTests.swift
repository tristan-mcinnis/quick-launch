import Testing
@testable import HouseChatCore

@Suite("Chat commands")
struct ChatCommandTests {
    private let parser = ChatCommandParser()

    @Test("The two builtins parse with their names and arguments")
    func builtins() {
        #expect(parser.parse("/new") == .command(ChatCommand(name: .new, rawName: "/new")))
        #expect(parser.parse("  /clear  ") == .command(ChatCommand(name: .clear, rawName: "/clear")))

        guard case .command(let command) = parser.parse("/new a fresh chat") else {
            Issue.record("Expected a command")
            return
        }
        #expect(command.name == .new)
        #expect(command.arguments == ["a", "fresh", "chat"])
        #expect(command.isBuiltin)
    }

    @Test("Command names are matched case-insensitively")
    func caseInsensitive() {
        guard case .command(let command) = parser.parse("/NEW") else {
            Issue.record("Expected a command")
            return
        }
        #expect(command.name == .new)
        #expect(command.rawName == "/NEW")
    }

    @Test("Plain text is not a command, and blank input is empty")
    func notCommands() {
        #expect(parser.parse("summarize this") == .notACommand)
        #expect(parser.parse("what about /new inside a sentence") == .notACommand)
        #expect(parser.parse("") == .empty)
        #expect(parser.parse("   \n ") == .empty)
    }

    @Test("An unknown slash command is a clear local error, never prompt text")
    func unknownCommand() {
        guard case .unknown(let rawName, let message) = parser.parse("/frobnicate now") else {
            Issue.record("Expected an unknown command")
            return
        }
        #expect(rawName == "/frobnicate")
        #expect(message.contains("/frobnicate"))
        #expect(!message.isEmpty)
    }

    @Test("An app's own commands are preserved as known commands")
    func knownCommandsPreserved() {
        let rti = ChatCommandParser(knownCommands: ["/meeting", "/notes", "/export"])
        guard case .command(let command) = rti.parse("/meeting weekly sync") else {
            Issue.record("Expected a known command")
            return
        }
        #expect(command.name == .known("/meeting"))
        #expect(command.arguments == ["weekly", "sync"])
        #expect(command.isBuiltin == false)

        // A command the parser was not told about is still an error, not a
        // silent prompt.
        guard case .unknown = rti.parse("/recording") else {
            Issue.record("Expected an unknown command")
            return
        }
    }

    @Test("An alias resolves to its canonical command")
    func aliases() {
        let parser = ChatCommandParser(
            knownCommands: ["/meeting"],
            aliases: ["/reset": "/clear", "/mtg": "/meeting"]
        )
        guard case .command(let cleared) = parser.parse("/reset") else {
            Issue.record("Expected a command")
            return
        }
        #expect(cleared.name == .clear)
        #expect(cleared.rawName == "/reset")

        guard case .command(let meeting) = parser.parse("/mtg") else {
            Issue.record("Expected a command")
            return
        }
        #expect(meeting.name == .known("/meeting"))
    }

    @Test("A builtin is never shadowed by an alias")
    func builtinsStayBuiltin() {
        let parser = ChatCommandParser(aliases: ["/new": "/clear"])
        guard case .command(let command) = parser.parse("/new") else {
            Issue.record("Expected a command")
            return
        }
        #expect(command.name == .new)
        #expect(ChatCommandParser.builtinNames == ["/new", "/clear"])
    }

    @Test("A command survives a JSON round trip")
    func codable() throws {
        for name in [ChatCommand.Name.new, .clear, .known("/meeting")] {
            let command = ChatCommand(name: name, rawName: name.rawValue, arguments: ["x"])
            let data = try HouseChatCoding.makeEncoder().encode(command)
            let decoded = try HouseChatCoding.makeDecoder().decode(ChatCommand.self, from: data)
            #expect(decoded == command)
        }
    }
}
