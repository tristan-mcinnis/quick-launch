import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Clipboard-manager etiquette: concealed and transient pasteboard content
/// never enters the history, and the history file stays owner-only.
@Suite("Clipboard history privacy", .serialized)
@MainActor
struct ClipboardHistoryPrivacyTests {

    private func makeStore() -> (ClipboardHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-clip-\(UUID().uuidString)")
            .appendingPathComponent("clipboard-history.json")
        return (ClipboardHistoryStore(fileURL: url), url)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-clip-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test func concealedContentIsNeverRecorded() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()

        // A password manager copy: string + concealed marker.
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")],
            owner: nil
        )
        pasteboard.setString("hunter2-super-secret", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "concealed clipboard content must never be stored")

        // A plain copy afterwards records normally.
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.map(\.value) == ["plain text"])
    }

    @Test func transientPastePlumbingIsNeverRecorded() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()

        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")],
            owner: nil
        )
        pasteboard.setString("pasted-through", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "our own paste writes must not reshuffle the history")
    }

    @Test func historyFileIsOwnerOnly() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.record("private note", limit: 10)
        store.waitForPendingWrites()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        #expect(permissions == 0o600, "clipboard history is private data")
    }

    @Test func unchangedPasteboardIsNotReRecorded() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        pasteboard.setString("once", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        let stamp = store.entries.first?.detail
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.detail == stamp)
    }
}
