// MainActorRenderLane: one heavy main-actor suite at a time.
//
// Render proofs draw whole windows into bitmaps (blur, shadows, layout) in
// long synchronous main-actor jobs. Swift Testing runs suites in parallel, so
// with some thirty of them at once the main queue held a long render job from
// each, and every other main-actor test waited behind all of them on each hop.
// Tests that hop many times (a submit through stream and archive) then took
// 30 to 95 seconds in the full suite and milliseconds alone, and failed their
// hang bounds (SubmitOwnershipTests, QuitRetentionArchiveTests).
//
// A suite marked `.mainActorRenderLane` runs each test case only while it holds
// one process-wide lane. A waiting test is suspended, not queued on the main
// actor, so the main queue holds at most one heavy job at a time. The main
// thread is one core, so the heavy suites lose no throughput by taking turns.
//
// `RenderLaneGuardTests` fails when a test file renders a view to a bitmap
// without the trait.

import Testing

/// FIFO async lock. A waiter is resumed in arrival order.
actor MainActorRenderLaneLock {
    static let shared = MainActorRenderLaneLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // Ownership passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

struct MainActorRenderLaneTrait: SuiteTrait, TestTrait, TestScoping {
    /// Applies to every test inside a marked suite.
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Only a test case holds the lane. A suite-level hold would deadlock
        // with the hold of its own first test.
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainActorRenderLaneLock.shared.acquire()
        do {
            try await function()
        } catch {
            await MainActorRenderLaneLock.shared.release()
            throw error
        }
        await MainActorRenderLaneLock.shared.release()
    }
}

extension Trait where Self == MainActorRenderLaneTrait {
    /// Runs this suite's tests one at a time with every other suite so marked.
    /// Use it on any suite that renders a view to a bitmap or otherwise holds
    /// the main actor for long synchronous stretches.
    static var mainActorRenderLane: Self { Self() }
}
