import Foundation
import Testing
@testable import QuickLaunch

/// The vault's sources for a thread: which rows of each mode's JSON become
/// sources, and how a vault path becomes a path on this Mac. The remote
/// script is not touched; the payloads here are shaped like its output.
@Suite("Vault sources")
struct VaultSourcesTests {
    private static let root = URL(fileURLWithPath: "/Users/test/vault", isDirectory: true)

    @Test func mapsTheVPSVaultRootOntoTheLocalClone() {
        #expect(SSHVaultSearchService.localPath(
            forVaultPath: "/home/ubuntu/vault-private/kb/databases/projects/acme-launch/00-status.md",
            localVaultRoot: Self.root
        ) == "/Users/test/vault/kb/databases/projects/acme-launch/00-status.md")
        // Paths the search returns are usually vault-relative.
        #expect(SSHVaultSearchService.localPath(
            forVaultPath: "kb/databases/emails/2026-08-20-brief.md",
            localVaultRoot: Self.root
        ) == "/Users/test/vault/kb/databases/emails/2026-08-20-brief.md")
    }

    @Test func aPathOutsideTheVaultHasNoLocalFile() {
        for path in ["/etc/hosts", "/home/ubuntu/other/x.md", "../secrets.md", "kb/../../x.md", "/home/ubuntu/vault-private/../x", ""] {
            #expect(
                SSHVaultSearchService.localPath(forVaultPath: path, localVaultRoot: Self.root) == nil,
                "\(path) must not map"
            )
        }
    }

    @Test func currentModeCitesItsEvidence() throws {
        let data = Data("""
        {
          "ok": true, "mode": "current", "as_of": "2026-08-24T01:39:38Z",
          "state": {"project": {"slug": "acme-launch", "title": "Acme Launch", "phase": "reporting", "status": "active"}},
          "evidence": [
            {"source_root": "project_status", "title": "Acme Launch status", "summary": "Current.",
             "source_path": "kb/databases/projects/acme-launch/00-status.md", "updated_at": "2026-08-24T01:39:09Z"},
            {"source_root": "email", "title": "Brief from the client",
             "source_path": "/home/ubuntu/vault-private/kb/databases/emails/brief.md", "authored_at": "2026-08-20T09:00:00Z"},
            {"source_root": "slack", "title": "Thread with no file"}
          ]
        }
        """.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.text.contains("## Acme Launch"), "the rendered answer is the same text Vault Search shows")
        #expect(outcome.resultCount == 3)
        #expect(outcome.sources == [
            ChatSource(title: "Acme Launch status", day: "2026-08-24", path: "/Users/test/vault/kb/databases/projects/acme-launch/00-status.md"),
            ChatSource(title: "Brief from the client", day: "2026-08-20", path: "/Users/test/vault/kb/databases/emails/brief.md"),
            ChatSource(title: "Thread with no file", day: nil, path: nil),
        ])
    }

    @Test func historyCitesItsResults() throws {
        let data = Data("""
        {"ok": true, "mode": "history", "project": "acme-launch", "as_of": "2026-08-01", "results": [
          {"title": "Long deck v3", "source_path": "kb/databases/projects/acme-launch/v3/deck.md", "authored_at": "2026-07-02T10:00:00Z"},
          {"source_path": "kb/databases/projects/acme-launch/v2/notes.md"}
        ]}
        """.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.resultCount == 2)
        #expect(outcome.sources.map(\.title) == ["Long deck v3", "notes.md"], "a row with no title is named for its file")
        #expect(outcome.sources.first?.day == "2026-07-02")
    }

    @Test func portfolioRowsWithoutAPathAreListedWithoutOne() throws {
        let data = Data("""
        {"ok": true, "mode": "portfolio", "query": "waiting", "results": [
          {"slug": "acme-launch", "title": "Acme Launch", "phase": "reporting", "status": "active"},
          {"slug": "china-snapshot", "phase": "setup", "status": "active", "source_path": "kb/databases/projects/china-snapshot/00-status.md"}
        ]}
        """.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.sources == [
            ChatSource(title: "Acme Launch", day: nil, path: nil),
            ChatSource(title: "00-status.md", day: nil, path: "/Users/test/vault/kb/databases/projects/china-snapshot/00-status.md"),
        ])
    }

    @Test func aScopeQuestionHasNoSources() throws {
        let data = Data("""
        {"ok":true,"needs_scope":true,"candidates":[{"slug":"a","title":"A"},{"slug":"b","title":"B"}]}
        """.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.needsScope)
        #expect(outcome.resultCount == 2)
        #expect(outcome.sources.isEmpty)
        #expect(outcome.text.contains("## Choose a project"))
    }

    @Test func emptyHistoryStillThrowsEmptyForTheToolToReport() {
        let data = Data(#"{"ok":true,"mode":"history","results":[]}"#.utf8)
        #expect(throws: VaultSearchError.self) {
            _ = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        }
    }

    @Test func onlyAPlainLocalFileIsOpenable() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "openable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "00-status.md")
        try "# Status".write(to: note, atomically: true, encoding: .utf8)
        let script = folder.appending(path: "run.command")
        try "echo hi".write(to: script, atomically: true, encoding: .utf8)
        let executable = folder.appending(path: "tool.md")
        try "#!/bin/sh".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let bundle = folder.appending(path: "Thing.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let roots = [folder]
        func openable(_ path: String?) -> URL? { ChatSource.openableURL(for: path, roots: roots) }
        #expect(openable(note.path)?.path == note.resolvingSymlinksInPath().path)
        #expect(openable(nil) == nil)
        #expect(openable("kb/relative.md") == nil)
        #expect(openable(folder.path) == nil, "a folder")
        #expect(openable(bundle.path) == nil, "an app bundle")
        #expect(openable(script.path) == nil, "a script open would run")
        #expect(openable(executable.path) == nil, "an executable file")
        #expect(openable(folder.path + "/../x.md") == nil)
        #expect(openable(folder.appending(path: "missing.md").path) == nil)
        // The same note outside the roots is refused.
        #expect(ChatSource.openableURL(for: note.path, roots: [folder.appending(path: "elsewhere")]) == nil)
    }

    @Test func typesOpenWouldRunInstallOrFollowAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "openable-types-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String) throws -> String {
            let url = folder.appending(path: name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        for name in ["run.jar", "Target.fileloc", "Link.webloc", "Profile.mobileconfig", "Do.shortcut",
                     "tool.pl", "tool.py", "install.sh", "Book.xlsm", "icon.svg", "archive.zip", "page.html", "noextension"] {
            #expect(ChatSource.openableURL(for: try file(name), roots: [folder]) == nil, "\(name)")
        }
        for name in ["00-status.md", "notes.txt", "data.csv", "brief.pdf", "shot.png", "Plan.docx",
                     "Budget.xlsx", "Deck.pptx", "thread.eml", "config.json", "Draft.rtf"] {
            #expect(ChatSource.openableURL(for: try file(name), roots: [folder]) != nil, "\(name)")
        }
    }

    @Test func aLinkIsJudgedByWhereItLeads() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "openable-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "vault", directoryHint: .isDirectory)
        let outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = outside.appending(path: "secret.md")
        try "x".write(to: secret, atomically: true, encoding: .utf8)
        let tool = outside.appending(path: "Tool.jar")
        try "x".write(to: tool, atomically: true, encoding: .utf8)
        let inside = root.appending(path: "note.md")
        try "x".write(to: inside, atomically: true, encoding: .utf8)

        let leavesTheRoot = root.appending(path: "link.md")
        try FileManager.default.createSymbolicLink(at: leavesTheRoot, withDestinationURL: secret)
        let hidesAJar = root.appending(path: "tool.md")
        try FileManager.default.createSymbolicLink(at: hidesAJar, withDestinationURL: tool)
        let staysInside = root.appending(path: "alias.md")
        try FileManager.default.createSymbolicLink(at: staysInside, withDestinationURL: inside)

        #expect(ChatSource.openableURL(for: leavesTheRoot.path, roots: [root]) == nil, "a link out of the vault")
        #expect(ChatSource.openableURL(for: hidesAJar.path, roots: [root]) == nil, "a .md link to a jar")
        #expect(ChatSource.openableURL(for: staysInside.path, roots: [root])?.lastPathComponent == "note.md")
        // A sibling folder that only shares the root's name as a prefix.
        let sibling = base.appending(path: "vault-other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let near = sibling.appending(path: "n.md")
        try "x".write(to: near, atomically: true, encoding: .utf8)
        #expect(ChatSource.openableURL(for: near.path, roots: [root]) == nil)
    }
}
