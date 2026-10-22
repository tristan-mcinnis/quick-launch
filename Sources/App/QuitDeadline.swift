import Foundation

/// Runs one async save for a quit and reports its truthful outcome. The
/// deadline returns nil; a save that completes returns its own value, which
/// may itself be a refusal. The timer is owned and cancelled when the save
/// wins; when the deadline wins, the save keeps running (it is the
/// persistence) but its late result is ignored, so no second reply is
/// possible.
@MainActor
func withQuitDeadline<T>(
    _ timeout: Duration,
    _ save: @escaping @MainActor () async -> T
) async -> T? {
    let gate = QuitDeadlineGate()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, gate.claim() {
                continuation.resume(returning: nil)
            }
        }
        Task { @MainActor in
            let value = await save()
            if gate.claim() {
                timeoutTask.cancel()
                continuation.resume(returning: value)
            }
        }
    }
}

/// One outcome for one quit attempt.
@MainActor
private final class QuitDeadlineGate {
    private var isClaimed = false

    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
