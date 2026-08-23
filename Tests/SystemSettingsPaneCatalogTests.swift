import Foundation
import Testing
@testable import QuickLaunch

@Suite("SystemSettingsPaneCatalog")
struct SystemSettingsPaneCatalogTests {

    @Test func hasAtLeastThirtyPanes() {
        #expect(SystemSettingsPaneCatalog.panes.count >= 30)
    }

    @Test func idsAreUnique() {
        let ids = SystemSettingsPaneCatalog.panes.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func idsAreStableSlugs() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for pane in SystemSettingsPaneCatalog.panes {
            #expect(!pane.id.isEmpty)
            #expect(pane.id.allSatisfy { allowed.contains($0) }, "id \(pane.id) is not a slug")
        }
    }

    @Test func titlesAreNonEmpty() {
        for pane in SystemSettingsPaneCatalog.panes {
            #expect(!pane.title.trimmingCharacters(in: .whitespaces).isEmpty, "empty title for \(pane.id)")
        }
    }

    @Test func systemImagesAreNonEmpty() {
        for pane in SystemSettingsPaneCatalog.panes {
            #expect(!pane.systemImage.isEmpty, "empty systemImage for \(pane.id)")
        }
    }

    @Test func everyURLUsesSystemPreferencesScheme() {
        for pane in SystemSettingsPaneCatalog.panes {
            #expect(pane.url.scheme == "x-apple.systempreferences", "bad scheme for \(pane.id): \(pane.url)")
            #expect(pane.url.absoluteString.hasPrefix("x-apple.systempreferences:com.apple."), "bad identifier for \(pane.id): \(pane.url)")
        }
    }

    @Test func urlsAreUnique() {
        let urls = SystemSettingsPaneCatalog.panes.map(\.url)
        #expect(Set(urls).count == urls.count)
    }

    @Test func keywordsAreLowerCaseAndNonEmpty() {
        for pane in SystemSettingsPaneCatalog.panes {
            #expect(!pane.keywords.isEmpty, "empty keywords for \(pane.id)")
            #expect(pane.keywords == pane.keywords.lowercased(), "keywords not lower-case for \(pane.id)")
            #expect(pane.keywords == pane.keywords.trimmingCharacters(in: .whitespaces), "keywords padded for \(pane.id)")
        }
    }

    @Test func coversCorePanes() {
        let ids = Set(SystemSettingsPaneCatalog.panes.map(\.id))
        for required in ["wifi", "bluetooth", "network", "battery", "displays", "sound",
                         "keyboard", "notifications", "privacy-security", "privacy-accessibility",
                         "privacy-screen-recording", "software-update", "storage", "icloud"] {
            #expect(ids.contains(required), "missing pane \(required)")
        }
    }

    @Test func privacySubPanesUseQueryForm() {
        let privacy = SystemSettingsPaneCatalog.panes.filter {
            $0.id.hasPrefix("privacy-") && $0.id != "privacy-security"
        }
        #expect(privacy.count >= 5)
        for pane in privacy {
            #expect(pane.url.absoluteString.contains("?Privacy_"), "\(pane.id) should use the ?Privacy_X query form")
        }
    }

    @Test func urlBuilderPrefixesScheme() {
        let url = SystemSettingsPaneCatalog.url(for: "com.apple.wifi-settings-extension")
        #expect(url.absoluteString == "x-apple.systempreferences:com.apple.wifi-settings-extension")
        #expect(url.scheme == "x-apple.systempreferences")
    }
}
