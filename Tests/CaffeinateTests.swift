import Foundation
import Testing
@testable import QuickLaunch

@Suite("Caffeinate: schedule, policy, watcher, manager", .serialized)
@MainActor
struct CaffeinateTests {
    private static let noon: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22; components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    @Test func scheduleParsesDurationsAndClockTimes() throws {
        let now = Self.noon
        #expect(try CaffeinateSchedule.parse("90m", now: now) == now.addingTimeInterval(90 * 60))
        #expect(try CaffeinateSchedule.parse("2h", now: now) == now.addingTimeInterval(2 * 3_600))
        #expect(try CaffeinateSchedule.parse("1.5h", now: now) == now.addingTimeInterval(1.5 * 3_600))
        #expect(try CaffeinateSchedule.parse("45 s", now: now) == now.addingTimeInterval(45))
        let later = try CaffeinateSchedule.parse("17:30", now: now)
        #expect(Calendar.current.component(.hour, from: later) == 17)
        #expect(Calendar.current.isDate(later, inSameDayAs: now))
        let pm = try CaffeinateSchedule.parse("5:30pm", now: now)
        #expect(pm == later)
        let tomorrow = try CaffeinateSchedule.parse("9am", now: now)
        #expect(!Calendar.current.isDate(tomorrow, inSameDayAs: now))
        #expect(Calendar.current.component(.hour, from: tomorrow) == 9)
        #expect(throws: CaffeinateSchedule.ParseError.self) { try CaffeinateSchedule.parse("soon", now: now) }
        #expect(throws: CaffeinateSchedule.ParseError.self) { try CaffeinateSchedule.parse("25:00", now: now) }
        #expect(CaffeinateSchedule.ParseError.invalid.localizedDescription == CaffeinateSchedule.usage)
    }

    @Test func policyOrdersBatteryThenManualThenAgents() {
        let now = Self.noon
        let claude = AgentSession(sessionID: "a", provider: "claude", updatedAt: now.addingTimeInterval(-60))
        let codex = AgentSession(sessionID: "b", provider: "codex", updatedAt: now.addingTimeInterval(-120))
        let stale = AgentSession(sessionID: "c", provider: "claude", updatedAt: now.addingTimeInterval(-13 * 3_600))

        #expect(CaffeinatePolicy.decision(.init(now: now)) == .inactive)
        #expect(CaffeinatePolicy.decision(.init(agentSessions: [stale], now: now)) == .inactive)
        #expect(CaffeinatePolicy.decision(.init(manualIndefinite: true, now: now))
            == .active(reason: "Caffeinated until you decaffeinate.", reviewAt: nil))

        let timed = CaffeinatePolicy.decision(.init(manualUntil: now.addingTimeInterval(600), now: now))
        if case .active(let reason, let reviewAt) = timed {
            #expect(reason.hasPrefix("Caffeinated until"))
            #expect(reviewAt == now.addingTimeInterval(600))
        } else { Issue.record("expected active") }

        let agents = CaffeinatePolicy.decision(.init(agentSessions: [claude, codex], now: now))
        #expect(agents == .active(reason: "Caffeinated while Claude Code and Codex is working.", reviewAt: codex.updatedAt.addingTimeInterval(CaffeinatePolicy.staleInterval)))
        #expect(CaffeinatePolicy.decision(.init(agentWatchEnabled: false, agentSessions: [claude], now: now)) == .inactive)
        #expect(CaffeinatePolicy.decision(.init(manualIndefinite: true, onBattery: true, batteryPercent: 18, batteryCutoff: 20, now: now)) == .batteryPaused(percent: 18))
        #expect(CaffeinatePolicy.decision(.init(manualIndefinite: true, onBattery: true, batteryPercent: 18, batteryCutoff: 0, now: now))
            == .active(reason: "Caffeinated until you decaffeinate.", reviewAt: nil))

        let summary = CaffeinatePolicy.summary(agents, agentWatchEnabled: true, agentNames: ["Claude Code"], onBattery: true, batteryPercent: 64, cutoff: 20)
        #expect(summary == "☕ Caffeinated while Claude Code and Codex is working. Agent watch on: Claude Code. Battery 64% on battery, pauses at 20%.")
    }

    @Test func watcherReadsHookFilesAndDropsStaleOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = AgentSessionWatcher(folders: [folder])
        let fresh = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30))
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-13 * 3_600))
        try Data("{\"sessionID\":\"s1\",\"provider\":\"claude\",\"updatedAt\":\"\(fresh)\"}".utf8)
            .write(to: folder.appendingPathComponent(AgentSessionWatcher.fileName(provider: "claude", sessionID: "s1")))
        try Data("{\"sessionID\":\"s2\",\"provider\":\"codex\",\"updatedAt\":\"\(stale)\"}".utf8)
            .write(to: folder.appendingPathComponent(AgentSessionWatcher.fileName(provider: "codex", sessionID: "s2")))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("junk.json"))

        watcher.reload()
        #expect(watcher.sessions.map(\.provider) == ["claude"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("codex-") }.isEmpty)
        #expect(AgentSessionWatcher.fileName(provider: "claude", sessionID: "ab/c+d==") == "claude-YWIvYytkPT0.json")

        watcher.clearAll()
        #expect(watcher.sessions.isEmpty)
    }

    @Test func managerHoldsAndReleasesThroughOneEvaluation() {
        let assertion = RecordingAssertion()
        let manager = CaffeinateManager(assertion: assertion)
        var changes = 0
        manager.onChange = { changes += 1 }
        var clock = Self.noon
        manager.now = { clock }

        #expect(!manager.isEnabled)
        #expect(manager.setEnabled(true))
        #expect(assertion.isHeld)
        #expect(manager.reason == "Caffeinated until you decaffeinate.")
        #expect(manager.endsAt == nil)

        #expect(manager.enable(for: 600))
        #expect(manager.endsAt == clock.addingTimeInterval(600))
        clock = clock.addingTimeInterval(601)
        manager.evaluate()
        #expect(!assertion.isHeld)
        #expect(manager.reason == nil)
        #expect(manager.statusSummary.hasPrefix("Decaffeinated"))
        #expect(changes >= 3)
        #expect(!manager.enable(until: clock.addingTimeInterval(-1)))

        manager.keepsDisplayAwake = true
        #expect(manager.setEnabled(true))
        #expect(assertion.lastKeepDisplayAwake)
        manager.releaseForQuit()
        #expect(!assertion.isHeld)
    }
}

@MainActor
private final class RecordingAssertion: PowerAssertionHolding {
    private(set) var isHeld = false
    private(set) var lastKeepDisplayAwake = false
    func hold(reason: String, keepDisplayAwake: Bool) {
        isHeld = true
        lastKeepDisplayAwake = keepDisplayAwake
    }
    func release() { isHeld = false }
}
