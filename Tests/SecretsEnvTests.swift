import Foundation
import Testing
@testable import QuickLaunch

@Suite("secrets.env reader")
struct SecretsEnvTests {
    private let text = """
    # keys
    export TAVILY_API_KEY=tvly-abc
    BRAVE_API_KEY="brave-xyz"
    export EMPTY_KEY=
    OTHER_BRAVE_API_KEY=wrong
    export TAVILY_API_KEY=tvly-newer
    """

    @Test func readsExportedAndPlainLinesAndUnquotes() {
        #expect(SecretsEnv.value("BRAVE_API_KEY", in: text) == "brave-xyz")
    }

    @Test func theLastLineWinsAndNamesMatchWhole() {
        #expect(SecretsEnv.value("TAVILY_API_KEY", in: text) == "tvly-newer")
        #expect(SecretsEnv.value("API_KEY", in: text) == nil)
    }

    @Test func emptyAndMissingAreNil() {
        #expect(SecretsEnv.value("EMPTY_KEY", in: text) == nil)
        #expect(SecretsEnv.value("NOPE", in: text) == nil)
        #expect(SecretsEnv.value("X", at: URL(fileURLWithPath: "/nonexistent/secrets.env")) == nil)
    }

    @Test func bravePrefersTheSearchNameAndAcceptsTheAlias() {
        let both = """
        BRAVE_API_KEY=alias
        BRAVE_SEARCH_API_KEY=primary
        """
        #expect(WebSearchKeys.brave(in: both) == "primary")

        let aliasLater = """
        BRAVE_SEARCH_API_KEY=primary
        BRAVE_API_KEY=alias
        """
        #expect(WebSearchKeys.brave(in: aliasLater) == "primary")

        #expect(WebSearchKeys.brave(in: "export BRAVE_API_KEY=\"alias-only\"\n") == "alias-only")
        #expect(WebSearchKeys.brave(in: "export BRAVE_SEARCH_API_KEY=search-only\n") == "search-only")
        #expect(WebSearchKeys.brave(in: "BRAVE_SEARCH_API_KEY=\nBRAVE_API_KEY=alias\n") == "alias")
        #expect(WebSearchKeys.brave(in: "OTHER_BRAVE_API_KEY=wrong\n") == nil)
    }

    @Test func readsAFileAtCallTime() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: file) }
        try "export BRAVE_API_KEY=one\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SecretsEnv.value("BRAVE_API_KEY", at: file) == "one")
        try "export BRAVE_API_KEY=two\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SecretsEnv.value("BRAVE_API_KEY", at: file) == "two")
    }
}
