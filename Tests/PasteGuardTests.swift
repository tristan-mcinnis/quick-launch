import Testing
@testable import QuickLaunch

@MainActor
@Suite("Paste guard")
struct PasteGuardTests {
    private func makeGuard(
        count: @escaping @MainActor () -> Int = { 7 },
        send: @escaping @MainActor () -> Bool = { true },
        settle: @escaping @MainActor () async -> Void = {}
    ) -> PasteGuard {
        PasteGuard(changeCount: count, sendCommandV: send, waitForModifierRelease: settle)
    }

    @Test("Command-V is sent when the clipboard is still ours")
    func sendsWhenUnchanged() {
        var sent = 0
        let guardian = makeGuard(send: { sent += 1; return true })
        #expect(guardian.sendCommandV(expectingChangeCount: 7) == .pasted)
        #expect(sent == 1)
    }

    @Test("Command-V is not sent after the user copies something else")
    func refusesWhenClipboardChanged() {
        var sent = 0
        let guardian = makeGuard(count: { 8 }, send: { sent += 1; return true })
        #expect(guardian.sendCommandV(expectingChangeCount: 7) == .clipboardChanged)
        #expect(sent == 0)
    }

    @Test("A failed keystroke reports failure, not a clipboard change")
    func reportsKeystrokeFailure() {
        let guardian = makeGuard(send: { false })
        #expect(guardian.sendCommandV(expectingChangeCount: 7) == .failed)
    }

    // The shared tail that both `paste(_:to:)` and `pastePasteboard(to:)`
    // end in, driven on the guard so no test builds the real service.
    @Test("A copy made while waiting for modifier keys blocks Command-V")
    func copyDuringTheWaitBlocksCommandV() async {
        var count = 7
        var sent = 0
        let service = makeGuard(
            count: { count },
            send: { sent += 1; return true },
            settle: { count += 1 }
        )
        let outcome = await service.sendCommandVAfterSettling(expectingChangeCount: 7)
        #expect(outcome == .clipboardChanged)
        #expect(sent == 0)
    }

    @Test("An undisturbed clipboard still pastes through the service")
    func undisturbedClipboardPastes() async {
        var sent = 0
        let service = makeGuard(send: { sent += 1; return true })
        #expect(await service.sendCommandVAfterSettling(expectingChangeCount: 7) == .pasted)
        #expect(sent == 1)
    }

    @Test("The service reports the same outcome after the caret-insert window")
    func serviceCommandVOutcome() {
        let service = makeGuard(count: { 9 })
        #expect(service.sendLoggedCommandV(expectingChangeCount: 7) == .clipboardChanged)
    }
}
