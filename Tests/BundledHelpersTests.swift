// BundledHelpersTests — packaging contract for build-app.sh and the Makefile.

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
    private static let makefile: String = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("Makefile")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()




    @Test("ad-hoc builds keep a stable designated requirement")
    func stableLocalSigningRequirement() {
        #expect(
            Self.buildScript.contains(
                "designated => identifier \"com.tristanmcinnis.quick-launch\""
            ),
            "Local rebuilds need a stable identity so macOS Accessibility approval can persist"
        )
    }

    @Test("generated app bundles are hidden from Spotlight")
    func buildDirectoryIsNotIndexed() {
        #expect(Self.buildScript.contains("build/.metadata_never_index"))
    }

    @Test("install replaces the canonical bundle and removes its build copy")
    func installLeavesOneApp() {
        #expect(Self.makefile.contains("rm -rf \"/Applications/Quick Launch.app\""))
        #expect(Self.makefile.contains("rm -rf \"build/Quick Launch.app\""))
        #expect(Self.makefile.contains("codesign --verify --deep --strict"))
    }
}
