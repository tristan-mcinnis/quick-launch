import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// `IOPMAssertionCreateWithName` with no child process. Assertions die with
/// the process, so intent is persisted in settings and re-asserted at launch.
@MainActor
final class PowerAssertion: PowerAssertionHolding {
    private var ids: [IOPMAssertionID] = []
    var isHeld: Bool { !ids.isEmpty }

    func hold(reason: String, keepDisplayAwake: Bool) {
        release()
        var types = [kIOPMAssertionTypePreventUserIdleSystemSleep as String]
        if keepDisplayAwake { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep as String) }
        for type in types {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Quick Launch: \(reason)" as CFString,
                &id
            )
            if status == kIOReturnSuccess { ids.append(id) }
        }
    }

    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids.removeAll()
    }

    deinit {
        for id in ids { IOPMAssertionRelease(id) }
    }
}

/// Battery state from IOKit, pushed on change rather than polled.
@MainActor
final class PowerSourceMonitor: PowerSourceReading {
    private(set) var onBattery = false
    private(set) var batteryPercent = 100
    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
                monitor.onChange?()
            }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            onBattery = false
            batteryPercent = 100
            return
        }
        var sawBattery = false
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else { continue }
            sawBattery = true
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            onBattery = state == (kIOPSBatteryPowerValue as String)
            let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let max = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
            batteryPercent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 100
        }
        if !sawBattery {
            onBattery = false
            batteryPercent = 100
        }
    }
}

/// Every trigger (command, agent file, power change, expiry) funnels into
/// one `evaluate()`, so there is a single place that holds or releases.
@MainActor
final class CaffeinateManager: CaffeinateManaging {
    private let assertion: any PowerAssertionHolding
    private let watcher: AgentSessionWatcher?
    private let power: (any PowerSourceReading)?
    private var reviewTask: Task<Void, Never>?
    var now: () -> Date = Date.init

    private(set) var manualIndefinite = false
    private(set) var manualUntil: Date?
    private(set) var decision: CaffeinatePolicy.Decision = .inactive

    var isAgentWatchEnabled = true { didSet { evaluate() } }
    var batteryCutoff = 20 { didSet { evaluate() } }
    var keepsDisplayAwake = false { didSet { if assertion.isHeld { reassert() } } }
    var onChange: (() -> Void)?

    init(assertion: any PowerAssertionHolding, watcher: AgentSessionWatcher? = nil, power: (any PowerSourceReading)? = nil) {
        self.assertion = assertion
        self.watcher = watcher
        self.power = power
        watcher?.onChange = { [weak self] in self?.evaluate() }
        power?.onChange = { [weak self] in self?.evaluate() }
    }

    func start() {
        watcher?.start()
        power?.start()
        evaluate()
    }

    var isEnabled: Bool { assertion.isHeld }

    /// A session is in force (manual, timed, or agents). True while the battery
    /// has paused an otherwise-live session, so cancel stays possible.
    var hasLiveSession: Bool {
        switch decision {
        case .active, .batteryPaused: true
        case .inactive: false
        }
    }

    /// The battery pause, when it is why the assertion is not held.
    var pauseDetail: String? {
        if case .batteryPaused(let percent) = decision {
            return "Paused at \(percent)% battery. Decaffeinate to cancel."
        }
        return nil
    }

    var endsAt: Date? {
        if case .active = decision, !manualIndefinite { return manualUntil }
        return nil
    }

    /// The intended deadline, held or paused: what a relaunch restores.
    var sessionDeadline: Date? { manualIndefinite ? nil : manualUntil }

    var reason: String? {
        if case .active(let reason, _) = decision { return reason }
        return nil
    }

    var liveAgentNames: [String] {
        let sessions = isAgentWatchEnabled ? CaffeinatePolicy.liveSessions(watcher?.sessions ?? [], now: now()) : []
        return Array(Set(sessions.map(\.providerTitle))).sorted()
    }

    var statusSummary: String {
        CaffeinatePolicy.summary(
            decision,
            agentWatchEnabled: isAgentWatchEnabled,
            agentNames: liveAgentNames,
            onBattery: power?.onBattery ?? false,
            batteryPercent: power?.batteryPercent ?? 100,
            cutoff: batteryCutoff
        )
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            return applyManualIntent(indefinite: true, until: nil)
        }
        manualIndefinite = false
        manualUntil = nil
        watcher?.clearAll()
        evaluate()
        return true
    }

    @discardableResult
    func enable(for duration: TimeInterval) -> Bool {
        guard duration > 0 else { return setEnabled(false) }
        return enable(until: now().addingTimeInterval(duration))
    }

    @discardableResult
    func enable(until date: Date) -> Bool {
        guard date > now() else { return false }
        return applyManualIntent(indefinite: false, until: date)
    }

    /// One mutation path for the whole manual-intent family, so every entry
    /// point reports the same way. A battery pause is a success: the session is
    /// in force and resumes on AC. Only a policy that asks for an active
    /// session whose assertion did not take (an IOKit refusal) is a failure,
    /// and it puts the prior intent and timer back exactly as they were.
    private func applyManualIntent(indefinite: Bool, until date: Date?) -> Bool {
        let previousIndefinite = manualIndefinite
        let previousUntil = manualUntil
        manualIndefinite = indefinite
        manualUntil = date
        evaluate()
        switch decision {
        case .active where assertion.isHeld:
            return true
        case .batteryPaused:
            return true
        case .active, .inactive:
            manualIndefinite = previousIndefinite
            manualUntil = previousUntil
            evaluate()
            return false
        }
    }

    /// Release without touching intent or agent files, for app termination.
    func releaseForQuit() {
        reviewTask?.cancel()
        assertion.release()
    }

    func evaluate() {
        let stamp = now()
        let input = CaffeinatePolicy.Input(
            manualIndefinite: manualIndefinite,
            manualUntil: manualUntil,
            agentWatchEnabled: isAgentWatchEnabled,
            agentSessions: watcher?.sessions ?? [],
            onBattery: power?.onBattery ?? false,
            batteryPercent: power?.batteryPercent ?? 100,
            batteryCutoff: batteryCutoff,
            now: stamp
        )
        let previous = decision
        let wasHeld = assertion.isHeld
        decision = CaffeinatePolicy.decision(input)
        if let until = manualUntil, until <= stamp { manualUntil = nil }
        reviewTask?.cancel()
        switch decision {
        case .active(let reason, let reviewAt):
            if !assertion.isHeld { assertion.hold(reason: reason, keepDisplayAwake: keepsDisplayAwake) }
            if let reviewAt {
                let delay = max(0.5, reviewAt.timeIntervalSince(stamp))
                reviewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.evaluate()
                }
            }
        case .inactive, .batteryPaused:
            assertion.release()
        }
        if previous != decision || wasHeld != assertion.isHeld { onChange?() }
    }

    private func reassert() {
        if case .active(let reason, _) = decision {
            assertion.hold(reason: reason, keepDisplayAwake: keepsDisplayAwake)
        }
    }
}
