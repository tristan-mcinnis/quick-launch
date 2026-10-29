import Testing
@testable import QuickLaunch

@MainActor
@Suite("Paste guard")
struct PasteGuardTests {
    @Test("Command-V is sent when the clipboard is still ours")
    func sendsWhenUnchanged() {
        var sent = 0
        let guardian = PasteGuard(changeCount: { 7 }, sendCommandV: { sent += 1; return true })
        #expect(guardian.sendCommandV(expectingChangeCount: 7))
        #expect(sent == 1)
    }

    @Test("Command-V is not sent after the user copies something else")
    func refusesWhenClipboardChanged() {
        var sent = 0
        let guardian = PasteGuard(changeCount: { 8 }, sendCommandV: { sent += 1; return true })
        #expect(!guardian.sendCommandV(expectingChangeCount: 7))
        #expect(sent == 0)
    }

    @Test("A failed keystroke reports failure")
    func reportsKeystrokeFailure() {
        let guardian = PasteGuard(changeCount: { 7 }, sendCommandV: { false })
        #expect(!guardian.sendCommandV(expectingChangeCount: 7))
    }
}
