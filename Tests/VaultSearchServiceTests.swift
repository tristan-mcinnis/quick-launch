import Foundation
import Testing
@testable import QuickLaunch

@Suite("Vault Search service")
struct VaultSearchServiceTests {
    @Test func formatsCurrentPacketAsACompactCitedAnswer() throws {
        let data = Data("""
        {
          "ok": true,
          "mode": "current",
          "as_of": "2026-08-24T01:39:38Z",
          "state": {
            "project": {
              "slug": "acme-launch",
              "title": "Acme Launch",
              "phase": "reporting",
              "status": "active",
              "verified_at": "2026-08-24T01:39:09Z"
            },
            "tasks": [{"title": "Rebuild the consumer section"}],
            "decisions": [{"title": "Use the new Play to Brand engaged framework"}]
          },
          "evidence": [{
            "source_root": "project_status",
            "title": "Acme Launch status",
            "summary": "The long deck is the current cross-functional reference.",
            "source_path": "kb/databases/projects/acme-launch/00-status.md"
          }]
        }
        """.utf8)

        let answer = try SSHVaultSearchService.formatResponse(data)

        #expect(answer.contains("## Acme Launch"))
        #expect(answer.contains("As of 2026-08-24T01:39:09Z: reporting · active"))
        #expect(answer.contains("### Open actions"))
        #expect(answer.contains("### Recent decisions"))
        #expect(answer.contains("kb/databases/projects/acme-launch/00-status.md"))
    }

    @Test func formatsScopeAndFutureRefusalsWithNextSteps() throws {
        let scope = Data("""
        {"ok":true,"needs_scope":true,"candidates":[
          {"slug":"acme-launch","title":"Acme Launch","phase":"reporting","status":"active"},
          {"slug":"acme-retail-csr","title":"Acme Running CSR","phase":"proposal-sent","status":"active"}
        ]}
        """.utf8)
        let future = Data("""
        {"ok":false,"refusal":"future_not_available","requested_boundary":"after 2026-08-24","as_of":"2026-08-24T01:55:23Z"}
        """.utf8)

        let scoped = try SSHVaultSearchService.formatResponse(scope)
        let refused = try SSHVaultSearchService.formatResponse(future)

        #expect(scoped.contains("## Choose a project"))
        #expect(scoped.contains("acme-launch"))
        #expect(refused.contains("## No future evidence"))
        #expect(refused.contains("Current data is available"))
    }

    @Test func everyModeHasShortDistinctInterfaceCopy() {
        #expect(VaultSearchMode.allCases.map(\.title) == [
            "Current Project", "Reconcile Changes", "Project History", "Across Projects",
        ])
        for mode in VaultSearchMode.allCases {
            #expect(!mode.detail.isEmpty)
            #expect(!mode.placeholder.isEmpty)
            #expect(mode.commandID.hasPrefix("vault."))
        }
    }

    // MARK: - Transport argv

    private static let remoteScript = "/remote/vault-search.py"
    private static let root = URL(fileURLWithPath: "/Users/test/vault", isDirectory: true)

    @Test func eachModeSendsTheRemoteScriptTheArgumentsItDeclares() {
        let script = Self.remoteScript
        #expect(SSHVaultSearchService.remoteArguments(remoteScript: script, mode: .current)
            == ["python3", script, "current", "--stdin", "--limit", "10", "--json"])
        #expect(SSHVaultSearchService.remoteArguments(remoteScript: script, mode: .reconcile)
            == ["python3", script, "reconcile", "--stdin", "--limit", "10", "--json"])
        #expect(SSHVaultSearchService.remoteArguments(remoteScript: script, mode: .portfolio)
            == ["python3", script, "portfolio", "--stdin", "--limit", "10", "--json"])
        // History declares `--project` required; the slug the resolver returned
        // is what keeps that call from being an argparse error.
        #expect(SSHVaultSearchService.remoteArguments(remoteScript: script, mode: .history, project: "acme-launch")
            == ["python3", script, "history", "--stdin", "--limit", "10", "--json", "--project", "acme-launch"])
        #expect(SSHVaultSearchService.scopeResolutionArguments(remoteScript: script)
            == ["python3", script, "scope", "--stdin", "--limit", "10", "--json"])
    }

    @Test func theScopeResolverOnlyNamesAProjectWhenItPinsOne() {
        let resolved = Data(#"{"ok":true,"mode":"scope","needs_scope":false,"resolved_project":"acme-launch"}"#.utf8)
        #expect(SSHVaultSearchService.resolvedProject(from: resolved) == "acme-launch")

        let ambiguous = Data(#"{"ok":true,"mode":"scope","needs_scope":true,"resolved_project":null,"candidates":[{"slug":"a"}]}"#.utf8)
        #expect(SSHVaultSearchService.resolvedProject(from: ambiguous) == nil)

        let blank = Data(#"{"ok":true,"needs_scope":false,"resolved_project":"  "}"#.utf8)
        #expect(SSHVaultSearchService.resolvedProject(from: blank) == nil)

        #expect(SSHVaultSearchService.resolvedProject(from: Data("not json".utf8)) == nil)
    }

    // MARK: - Failure diagnostics

    @Test func aMissingRemoteScriptIsNamedNotSwallowed() {
        let message = SSHVaultSearchService.diagnostic(
            status: 2,
            stdout: Data(),
            stderr: Data("python3: can't open file '/remote/vault-search.py': [Errno 2] No such file or directory\n".utf8),
            remoteScript: Self.remoteScript
        )
        #expect(message.contains("vault-search.py exited 2"))
        #expect(message.contains("can't open file"))
    }

    @Test func theLastTracebackLineIsTheDiagnostic() {
        // The live failure on vault-vps: the script raises before it can
        // answer. The exception line, not the stack above it, is useful.
        let stderr = """
        Traceback (most recent call last):
          File "/home/ubuntu/vault-private/.claude/tools/state/vault-search.py", line 79, in state_lib
            load_reader_url()
        RuntimeError: no read-only Neon URL found in /home/ubuntu/.vault/.env

        """
        let message = SSHVaultSearchService.diagnostic(
            status: 1,
            stdout: Data(),
            stderr: Data(stderr.utf8),
            remoteScript: "/home/ubuntu/vault-private/.claude/tools/state/vault-search.py"
        )
        #expect(message.contains("vault-search.py exited 1"))
        #expect(message.contains("RuntimeError: no read-only Neon URL found"))
        #expect(!message.contains("Traceback"))
    }

    @Test func aToolThatExitedWithItsOwnErrorPayloadIsQuoted() {
        let message = SSHVaultSearchService.diagnostic(
            status: 2,
            stdout: Data(#"{"ok":false,"needs_scope":true,"project":"nope","error":"project not found in state.projects"}"#.utf8),
            stderr: Data(),
            remoteScript: Self.remoteScript
        )
        #expect(message == "vault-search.py reported: project not found in state.projects")
    }

    @Test func aSilentNonZeroExitStillNamesTheTool() {
        let message = SSHVaultSearchService.diagnostic(
            status: 127, stdout: Data(), stderr: Data(), remoteScript: Self.remoteScript
        )
        #expect(message == "vault-search.py exited 127 with no message")
    }

    @Test func aTimeoutNamesTheToolAndTheDuration() {
        let message = SSHVaultSearchService.unavailableReason(
            .timedOut(executable: "ssh", seconds: 8),
            remoteScript: Self.remoteScript
        )
        #expect(message == "vault-search.py did not respond within 8 seconds")
    }

    // MARK: - Normalized status

    @Test func anAnswerWithRowsIsAvailable() throws {
        let data = Data(#"{"ok":true,"mode":"portfolio","query":"waiting","results":[{"slug":"a","title":"A"}]}"#.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.status == .available)
        #expect(outcome.resultCount == 1)
    }

    @Test func anAmbiguousQuestionIsDegradedAndNeedsScope() throws {
        let data = Data(#"{"ok":true,"needs_scope":true,"candidates":[{"slug":"a","title":"A"},{"slug":"b","title":"B"}]}"#.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.needsScope)
        #expect(outcome.status == .degraded(reason: "more than one project matches"))
        #expect(outcome.status.reason == "more than one project matches")
    }

    @Test func anEmptyHistoryAnswerIsALegitimateNoMatch() {
        let data = Data(#"{"ok":true,"mode":"history","project":"a","results":[]}"#.utf8)
        do {
            _ = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
            Issue.record("an empty history answer still reports as no evidence")
        } catch let error as VaultSearchError {
            #expect(error.status == .noMatch)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func aPayloadWithNoStateIsMalformedNotNoEvidence() {
        let data = Data(#"{"ok":true,"mode":"current","evidence":[]}"#.utf8)
        do {
            _ = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
            Issue.record("an answer with no state.project must not read as no evidence")
        } catch let error as VaultSearchError {
            #expect(error.status.isUnavailable)
            #expect((error.errorDescription ?? "").contains("unexpected shape"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func aScopeQuestionWithNoCandidatesDoesNotClaimAmbiguity() throws {
        let data = Data(#"{"ok":true,"needs_scope":true,"candidates":[]}"#.utf8)
        let outcome = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
        #expect(outcome.needsScope)
        #expect(outcome.resultCount == 0)
        #expect(outcome.text.contains("No project matched that name"))
        #expect(!outcome.text.contains("More than one project matches"))
        #expect(outcome.status == .degraded(reason: "the backend needs a project named"))
    }

    @Test func aNestedCanonicalProjectIdIsPassedThroughNotFlattened() {
        // `state.projects.slug` is the project directory path relative to
        // `kb/databases/projects/` (`project-projector.py`: "slug = the project
        // dir path … e.g. acme-af1" or "personal/china-book"), so the resolver
        // returns nested ids for 29 of that table's 40 rows. The adapter sends
        // the canonical id verbatim: the flat basename is not the same id —
        // today `history --project stack` matches by the over-broad
        // `%/stack/%` arm and returns rows whose `project` field is scattered
        // across four different `public.projects` rows.
        let scope = Data(#"{"ok":true,"mode":"scope","needs_scope":false,"resolved_project":"personal/stack","candidates":[{"slug":"personal/stack"}]}"#.utf8)
        let project = SSHVaultSearchService.resolvedProject(from: scope)
        #expect(project == "personal/stack")
        #expect(SSHVaultSearchService.remoteArguments(
            remoteScript: Self.remoteScript, mode: .history, project: project
        ) == ["python3", Self.remoteScript, "history", "--stdin", "--limit", "10", "--json", "--project", "personal/stack"])
        // A three-level project path resolves the same way.
        let deeper = Data(#"{"ok":true,"needs_scope":false,"resolved_project":"personal/ai-services/methodology"}"#.utf8)
        #expect(SSHVaultSearchService.resolvedProject(from: deeper) == "personal/ai-services/methodology")
    }

    @Test func aBackendProjectValidationFailureStaysVisible() {
        // Historical nested-ID failure fixture. The deployed validator now
        // accepts canonical nested IDs; any future backend validation failure
        // must still retain the terminal exception, not become a no-match.
        let message = SSHVaultSearchService.diagnostic(
            status: 1,
            stdout: Data(),
            stderr: Data("""
              File "/home/ubuntu/vault-private/.claude/tools/state/vault-search.py", line 98, in validate_slug
                raise ValueError("project must be a lowercase vault slug")
            ValueError: project must be a lowercase vault slug
            """.utf8),
            remoteScript: "/home/ubuntu/vault-private/.claude/tools/state/vault-search.py"
        )
        #expect(message.contains("vault-search.py exited 1"))
        #expect(message.contains("ValueError: project must be a lowercase vault slug"))
    }

    @Test func aHistoryAnswerWithNoResultsKeyIsMalformed() {
        let data = Data(#"{"ok":true,"mode":"history","project":"a"}"#.utf8)
        do {
            _ = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
            Issue.record("a missing results array is a schema break")
        } catch let error as VaultSearchError {
            #expect(error.status.isUnavailable)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func aReportedBackendFailureKeepsItsOwnMessage() {
        let data = Data(#"{"ok":false,"mode":"current","error":"connection terminated unexpectedly"}"#.utf8)
        do {
            _ = try SSHVaultSearchService.outcome(from: data, localVaultRoot: Self.root)
            Issue.record("ok:false must throw")
        } catch let error as VaultSearchError {
            #expect(error.status == .unavailable(reason: "connection terminated unexpectedly"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func aNonObjectAnswerIsMalformedNotNoEvidence() {
        do {
            _ = try SSHVaultSearchService.outcome(from: Data("not json".utf8), localVaultRoot: Self.root)
            Issue.record("non-JSON must throw")
        } catch let error as VaultSearchError {
            #expect(error.status.isUnavailable)
            #expect(error.status != .noMatch)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func aTimeoutIsUnavailableInTheNormalizedShape() {
        #expect(VaultSearchError.timedOut.status == .unavailable(reason: "no response within the request deadline"))
    }
}
