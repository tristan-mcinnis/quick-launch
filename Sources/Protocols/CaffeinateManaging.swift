import Foundation

@MainActor
protocol CaffeinateManaging: AnyObject {
    /// A sleep assertion is held right now.
    var isEnabled: Bool { get }
    /// A session is in force: a manual or timed intent, or live agent work.
    /// Stays true while the battery has paused an otherwise-live session, so a
    /// paused session is still cancellable. Distinct from `isEnabled`, which
    /// is only whether the assertion is held at this instant.
    var hasLiveSession: Bool { get }
    /// Why the assertion is released while a session is live (a battery pause),
    /// or nil. One short sentence for the row and the Settings card.
    var pauseDetail: String? { get }
    /// End of the manual timed session, if any.
    var endsAt: Date? { get }
    /// The intended end of the manual timed session, whether or not the battery
    /// has paused the assertion. `endsAt` is nil while paused; this is the
    /// deadline the intent keeps, so a relaunch can restore the timer.
    var sessionDeadline: Date? { get }
    /// One-line status in the Tuna Companion wording.
    var statusSummary: String { get }
    /// Why the Mac is awake, when it is.
    var reason: String? { get }
    var isAgentWatchEnabled: Bool { get set }
    var batteryCutoff: Int { get set }
    var keepsDisplayAwake: Bool { get set }
    /// Called on the main actor whenever the held state or its reason changes.
    var onChange: (() -> Void)? { get set }
    /// `true`: caffeinate until told otherwise. `false`: decaffeinate, which
    /// also clears agent sessions so the next agent turn starts fresh.
    /// Returns whether the requested state is in force. A refused assertion
    /// leaves the prior intent and timer exactly as they were.
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
    @discardableResult func enable(for duration: TimeInterval) -> Bool
    @discardableResult func enable(until date: Date) -> Bool
}

extension CaffeinateManaging {
    var endsAt: Date? { nil }
    var sessionDeadline: Date? { endsAt }
    /// The fallback keeps the two states equal for a minimal conformer: with
    /// no policy of its own, a held assertion is the only session there is.
    var hasLiveSession: Bool { isEnabled }
    var pauseDetail: String? { nil }
    var statusSummary: String { isEnabled ? "Caffeinated." : "Decaffeinated. Normal Mac sleep is enabled." }
    var reason: String? { nil }
    var isAgentWatchEnabled: Bool {
        get { false }
        set {}
    }
    var batteryCutoff: Int {
        get { 0 }
        set {}
    }
    var keepsDisplayAwake: Bool {
        get { false }
        set {}
    }
    var onChange: (() -> Void)? {
        get { nil }
        set {}
    }
    @discardableResult
    func enable(for duration: TimeInterval) -> Bool { setEnabled(duration > 0) }
    @discardableResult
    func enable(until date: Date) -> Bool { enable(for: date.timeIntervalSinceNow) }
}
