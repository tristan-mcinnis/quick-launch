import Foundation

@MainActor
protocol CaffeinateManaging: AnyObject {
    /// A sleep assertion is held right now.
    var isEnabled: Bool { get }
    /// End of the manual timed session, if any.
    var endsAt: Date? { get }
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
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
    @discardableResult func enable(for duration: TimeInterval) -> Bool
    @discardableResult func enable(until date: Date) -> Bool
}

extension CaffeinateManaging {
    var endsAt: Date? { nil }
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
