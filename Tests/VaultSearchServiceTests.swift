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
}
