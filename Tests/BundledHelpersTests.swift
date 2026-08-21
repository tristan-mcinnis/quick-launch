// BundledHelpersTests — package the optional Apple helper when it is present.
//
// The multi-provider build must also remain runnable when Apple Foundation
// Models and the apfel helper are unavailable.

import Foundation
import Testing

@Suite("BundledHelpers")
struct BundledHelpersTests {
    private static let buildScript: String = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Tests/
        url.deleteLastPathComponent() // repo root
        url.appendPathComponent("scripts/build-app.sh")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test("build-app.sh embeds the apfel helper")
    func apfelEmbedded() {
        #expect(
            Self.buildScript.contains("Contents/Helpers/apfel"),
            "build-app.sh must copy apfel into Contents/Helpers so users don't need a separate brew install"
        )
    }

    @Test("build-app.sh permits a bundle without the optional Apple helper")
    func missingHelperKeepsOtherProvidersAvailable() {
        #expect(
            Self.buildScript.contains("Building without the optional Apple provider helper"),
            "A missing Apple helper must not block LM Studio, API, Claude Code, or Pi providers"
        )
    }

    @Test("build-app.sh signs the embedded helper before signing the bundle")
    func helperSigned() {
        #expect(
            Self.buildScript.contains("codesign_path \"$APP_BUNDLE/Contents/Helpers/apfel\""),
            "sign_bundle must sign Contents/Helpers/apfel before the outer bundle"
        )
    }

    @Test("ad-hoc builds keep a stable designated requirement")
    func stableLocalSigningRequirement() {
        #expect(
            Self.buildScript.contains(
                "designated => identifier \"com.tristanmcinnis.quick-launch\""
            ),
            "Local rebuilds need a stable identity so macOS Accessibility approval can persist"
        )
    }
}
