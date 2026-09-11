// G3SettingsRenderProofTests — offscreen proofs of the v1.5.0 group G3
// surfaces, in both appearances, written to
// /tmp/quick-launch-render-proof/g3-*.png: the Chat card (chat defaults,
// Keep AI Chat on top, the two status lines), the "Quick AI and AI Chat"
// card, the History card with Chats to keep, and the Welcome card.

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("G3 render proofs", .serialized)
@MainActor
struct G3SettingsRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, AppearancePreference, String)] = [
        (.darkAqua, .dark, "dark"),
        (.aqua, .light, "light"),
    ]
    /// The Settings pane beside the rail and its hairline.
    private static let paneWidth = SettingsView.windowSize.width - House.Layout.settingsRail - House.hairline

    private static func makeViewModel(_ appearance: AppearancePreference) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = true
        return QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
    }

    @Test func rendersTheChatCard() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            // One switch off, so the card shows both toggle states.
            vm.settings.newChatSkillsEnabled = false
            // pi ready; the tool backends partly ready (no vault host).
            vm.chatBackendStatus = ChatBackendStatus(
                tmuxFound: true, piFound: true, ghosttyFound: true,
                recallFound: true, vaultHostConfigured: false
            )
            try Self.saveCard(ChatSettingsView(viewModel: vm), preference: preference, appearance: appearance, name: "g3-settings-chat-card-\(suffix).png")

            // pi, Ghostty, recall, and the vault host all missing.
            let missing = Self.makeViewModel(preference)
            missing.chatBackendStatus = ChatBackendStatus(
                tmuxFound: true, piFound: false, ghosttyFound: false,
                recallFound: false, vaultHostConfigured: false
            )
            try Self.saveCard(ChatSettingsView(viewModel: missing), preference: preference, appearance: appearance, name: "g3-settings-chat-card-missing-\(suffix).png")
        }
    }

    @Test func rendersTheQuickAIAndAIChatCard() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            try Self.saveCard(QuickAISettingsView(viewModel: vm), preference: preference, appearance: appearance, name: "g3-settings-quick-ai-card-\(suffix).png")
            try Self.saveCard(FallbackCommandsView(viewModel: vm), preference: preference, appearance: appearance, name: "g3-settings-fallback-card-\(suffix).png")
        }
    }

    @Test func rendersTheHistoryCard() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            try Self.saveCard(HistorySettingsView(viewModel: vm), preference: preference, appearance: appearance, name: "g3-settings-history-card-\(suffix).png")
        }
    }

    @Test func rendersTheWelcomeCard() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            let card = WelcomeOverlayView(viewModel: vm, onContinue: {})
                .padding(House.Spacing.xxl)
                .background(AQDesign.ColorToken.windowSurface)
            try Self.save(try Self.renderFitting(card, appearance: appearance), name: "g3-welcome-\(suffix).png")
        }
    }

    // MARK: - Rendering

    private static func saveCard<V: View>(
        _ card: V,
        preference: AppearancePreference,
        appearance: NSAppearance.Name,
        name: String
    ) throws {
        let pane = card
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.vertical, House.Spacing.md)
            .frame(width: paneWidth, alignment: .top)
            .background(AQDesign.ColorToken.windowSurface)
            .preferredColorScheme(preference == .dark ? .dark : .light)
        try save(try renderFitting(pane, appearance: appearance), name: name)
    }

    private static func renderFitting<V: View>(_ view: V, appearance: NSAppearance.Name) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}
