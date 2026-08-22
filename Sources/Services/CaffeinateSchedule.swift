import Foundation

/// Parses what you type after "Caffeinate Until": a clock time such as
/// `17:30` or `5:30pm`, or a duration such as `90m` or `2h`.
enum CaffeinateSchedule {
    static let usage = "Use a time like 17:30 or 5:30pm, or a duration like 90m or 2h."

    enum ParseError: LocalizedError, Equatable {
        case invalid
        var errorDescription: String? { usage }
    }

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw ParseError.invalid }

        if let match = trimmed.range(of: #"^(\d+(\.\d+)?)\s*([smhd])$"#, options: .regularExpression) {
            let body = String(trimmed[match])
            let unit = body.last!
            let number = Double(body.dropLast().trimmingCharacters(in: .whitespaces)) ?? 0
            let seconds: Double
            switch unit {
            case "s": seconds = number
            case "m": seconds = number * 60
            case "h": seconds = number * 3_600
            default: seconds = number * 86_400
            }
            guard seconds > 0 else { throw ParseError.invalid }
            return now.addingTimeInterval(seconds)
        }

        if let match = trimmed.range(of: #"^(\d{1,2})(:(\d{2}))?\s*(am|pm)?$"#, options: .regularExpression) {
            let body = String(trimmed[match])
            let meridiem = body.hasSuffix("am") ? "am" : (body.hasSuffix("pm") ? "pm" : nil)
            let digits = body.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "").trimmingCharacters(in: .whitespaces)
            let parts = digits.split(separator: ":")
            guard let hourRaw = Int(parts[0]) else { throw ParseError.invalid }
            let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            var hour = hourRaw
            if let meridiem {
                guard (1...12).contains(hourRaw) else { throw ParseError.invalid }
                hour = hourRaw % 12 + (meridiem == "pm" ? 12 : 0)
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { throw ParseError.invalid }
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard var date = calendar.date(from: components) else { throw ParseError.invalid }
            if date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }
        throw ParseError.invalid
    }
}

/// One agent turn that should keep the Mac awake. Written by agent hooks as
/// `<provider>-<base64url(sessionID)>.json` in an AgentSessions folder.
struct AgentSession: Codable, Equatable, Sendable {
    var sessionID: String
    var provider: String
    var updatedAt: Date

    var providerTitle: String {
        switch provider.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: provider.capitalized
        }
    }
}

/// What should be asserted right now, from manual intent, agent sessions,
/// and the battery. Pure, so it is fully tested.
enum CaffeinatePolicy {
    static let staleInterval: TimeInterval = 12 * 60 * 60

    enum Decision: Equatable, Sendable {
        case inactive
        case batteryPaused(percent: Int)
        case active(reason: String, reviewAt: Date?)
    }

    struct Input: Equatable, Sendable {
        var manualIndefinite: Bool = false
        var manualUntil: Date? = nil
        var agentWatchEnabled: Bool = true
        var agentSessions: [AgentSession] = []
        var onBattery: Bool = false
        var batteryPercent: Int = 100
        var batteryCutoff: Int = 20
        var now: Date = Date()
    }

    static func liveSessions(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        sessions.filter { now.timeIntervalSince($0.updatedAt) < staleInterval }
    }

    static func decision(_ input: Input) -> Decision {
        let manualLive = input.manualIndefinite || (input.manualUntil.map { $0 > input.now } ?? false)
        let agents = input.agentWatchEnabled ? liveSessions(input.agentSessions, now: input.now) : []
        guard manualLive || !agents.isEmpty else { return .inactive }
        if input.onBattery, input.batteryCutoff > 0, input.batteryPercent <= input.batteryCutoff {
            return .batteryPaused(percent: input.batteryPercent)
        }
        let agentDeadline = agents.map { $0.updatedAt.addingTimeInterval(staleInterval) }.min()
        if manualLive {
            let reason: String
            if input.manualIndefinite {
                reason = "Caffeinated until you decaffeinate."
            } else if let until = input.manualUntil {
                reason = "Caffeinated until \(until.formatted(date: .omitted, time: .shortened))."
            } else {
                reason = "Caffeinated."
            }
            let review = [input.manualIndefinite ? nil : input.manualUntil, agentDeadline].compactMap { $0 }.min()
            return .active(reason: reason, reviewAt: review)
        }
        let names = Array(Set(agents.map(\.providerTitle))).sorted()
        let joined = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return .active(reason: "Caffeinated while \(joined) is working.", reviewAt: agentDeadline)
    }

    static func summary(_ decision: Decision, agentWatchEnabled: Bool, agentNames: [String], onBattery: Bool, batteryPercent: Int, cutoff: Int) -> String {
        var parts: [String] = []
        switch decision {
        case .inactive:
            parts.append("Decaffeinated. Normal Mac sleep is enabled.")
        case .batteryPaused(let percent):
            parts.append("Paused at \(percent)% battery. Normal Mac sleep is enabled until you plug in.")
        case .active(let reason, _):
            parts.append("☕ " + reason)
        }
        if agentWatchEnabled {
            parts.append(agentNames.isEmpty ? "Agent watch on." : "Agent watch on: \(agentNames.joined(separator: ", ")).")
        } else {
            parts.append("Agent watch off.")
        }
        if onBattery {
            parts.append(cutoff > 0 ? "Battery \(batteryPercent)% on battery, pauses at \(cutoff)%." : "Battery \(batteryPercent)% on battery.")
        }
        return parts.joined(separator: " ")
    }
}
