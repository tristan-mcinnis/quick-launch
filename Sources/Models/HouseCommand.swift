import Foundation

/// How an app is reached. One of the three the house contract names
/// (`design-system/docs/app-commands.md`); anything else is not a manifest
/// this build understands.
enum HouseCommandTransport: String, Sendable, Equatable, CaseIterable {
    /// A line-oriented Unix socket owned by a running app.
    case socket
    /// A local daemon that already serves HTTP.
    case http
    /// A CLI that already does the job, run directly through `ProcessRunner`.
    case exec
}

/// The one argument a command may take.
enum HouseCommandNeeds: String, Sendable, Equatable {
    case text
    case choice
}

/// `unavailableWhen`: the name of a boolean in the app's status document,
/// optionally negated with a leading `!`. Quick Launch never guesses: a
/// status it cannot read, or a field the status does not carry, counts as
/// unavailable.
struct HouseCommandCondition: Sendable, Equatable {
    let field: String
    let isNegated: Bool

    init?(rawValue: String) {
        var text = rawValue.trimmingCharacters(in: .whitespaces)
        let negated = text.hasPrefix("!")
        if negated { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        self.field = text
        self.isNegated = negated
    }

    /// True when the command may run. `nil` status means nothing is known,
    /// which is not a licence to offer the row.
    func isSatisfied(by status: HouseCommandStatus?) -> Bool {
        guard let value = status?.flags[field] else { return false }
        // "recording" hides the row while recording; "!recording" hides it
        // while not recording.
        return isNegated ? value : !value
    }
}

/// One command an app publishes.
struct HouseCommand: Sendable, Equatable, Identifiable {
    /// The manifest's own id, e.g. `record.start`.
    let id: String
    /// The user-visible effect, e.g. "Start Recording". Shown verbatim.
    let title: String
    /// The word sent on the wire: a socket verb, an HTTP route, or the
    /// first argument to a CLI.
    let verb: String
    let needs: HouseCommandNeeds?
    /// The options a `choice` command offers, in the order given.
    let choices: [String]
    let unavailableWhen: HouseCommandCondition?

    /// A command with no condition is always offered; the run reports any
    /// failure plainly rather than the row lying about it beforehand.
    func isAvailable(given status: HouseCommandStatus?) -> Bool {
        guard let unavailableWhen else { return true }
        return unavailableWhen.isSatisfied(by: status)
    }
}

/// One app's manifest, from
/// `~/Library/Application Support/House/commands/<app-id>.json`.
///
/// Parsing is total: every failure returns `nil` or drops the offending
/// command. A missing, stale, malformed, or unknown-schema file means that
/// app offers nothing, never a thrown error and never a crash.
struct HouseCommandManifest: Sendable, Equatable, Identifiable {
    /// The only schema this build reads. A newer one is ignored whole:
    /// guessing at a shape we do not know would be the same as inventing it.
    static let supportedSchema = 1

    /// The app id, e.g. `rti`.
    let app: String
    /// The display name, e.g. "RTI". Shown as a row's detail.
    let name: String
    let transport: HouseCommandTransport
    /// A socket path, a base URL, or an executable path, by transport.
    /// A leading `~` is expanded when the manifest is read.
    let endpoint: String
    /// The verb, route, or argument that answers with the status document.
    /// Absent means this app reports no status, so nothing it publishes may
    /// be gated on one.
    let status: String?
    let commands: [HouseCommand]

    var id: String { app }

    /// Parses one manifest's bytes. Returns `nil` for anything this build
    /// cannot read: not an object, not schema 1, a missing or unknown
    /// transport, an empty app id, name, or endpoint.
    static func parse(_ data: Data) -> HouseCommandManifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }
        return parse(object: root)
    }

    static func parse(object: [String: Any]) -> HouseCommandManifest? {
        // A schema that is absent, not a number, or from a later version of
        // the contract: this build does not know the shape, so it reads none
        // of it.
        guard let schema = object["schema"] as? Int, schema == supportedSchema else { return nil }
        guard let app = string(object["app"]), !app.isEmpty,
              let transportName = string(object["transport"]),
              let transport = HouseCommandTransport(rawValue: transportName),
              let endpoint = string(object["endpoint"]), !endpoint.isEmpty
        else { return nil }
        let name = string(object["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? app
        let status = string(object["status"]).flatMap { $0.isEmpty ? nil : $0 }
        let rawCommands = object["commands"] as? [[String: Any]] ?? []
        let commands = rawCommands.compactMap(command(from:))
        return HouseCommandManifest(
            app: app,
            name: name,
            transport: transport,
            endpoint: expandTilde(endpoint),
            status: status,
            commands: commands
        )
    }

    /// One command entry. A command missing an id, a title, or a verb is
    /// dropped rather than taking the whole manifest down with it, as is one
    /// whose `needs` this build does not know and one that asks for a choice
    /// without offering any.
    private static func command(from object: [String: Any]) -> HouseCommand? {
        guard let id = string(object["id"]), !id.isEmpty,
              let title = string(object["title"]), !title.isEmpty,
              let verb = string(object["verb"]), !verb.isEmpty
        else { return nil }
        var needs: HouseCommandNeeds?
        if let rawNeeds = string(object["needs"]) {
            guard let parsed = HouseCommandNeeds(rawValue: rawNeeds) else { return nil }
            needs = parsed
        }
        let choices = (object["choices"] as? [Any])?.compactMap(string) ?? []
        if needs == .choice, choices.isEmpty { return nil }
        let condition = string(object["unavailableWhen"]).flatMap(HouseCommandCondition.init(rawValue:))
        return HouseCommand(
            id: id,
            title: title,
            verb: verb,
            needs: needs,
            choices: choices,
            unavailableWhen: condition
        )
    }

    /// True when anything this app publishes is gated on a status document.
    var needsStatus: Bool {
        status != nil && commands.contains { $0.unavailableWhen != nil }
    }

    /// The endpoint as a file URL, for the socket and exec transports.
    var endpointURL: URL { URL(fileURLWithPath: endpoint) }

    /// The endpoint as a base URL, for the http transport.
    var baseURL: URL? { URL(string: endpoint) }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// `~` and `~/…` against this user's home. The manifests name paths the
    /// way a config file does; nothing else in the string is interpreted.
    static func expandTilde(
        _ path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let rest = path == "~" ? "" : String(path.dropFirst(2))
        return home.appendingPathComponent(rest).path
    }
}

/// The status document an app answers with: `ok`, `busy`, `detail`, plus
/// whatever booleans its `unavailableWhen` clauses name.
struct HouseCommandStatus: Sendable, Equatable {
    /// Every boolean in the document, by name, including `ok` and `busy`.
    let flags: [String: Bool]
    /// One short human phrase, shown verbatim when it is there.
    let detail: String?

    var ok: Bool { flags["ok"] ?? false }
    var busy: Bool { flags["busy"] ?? false }

    /// Total, like the manifest parse: a status line that is not a JSON
    /// object is no status at all.
    static func parse(_ line: String) -> HouseCommandStatus? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> HouseCommandStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }
        var flags: [String: Bool] = [:]
        for (key, value) in root {
            // `as? Bool` alone also matches the numbers 0 and 1 through
            // NSNumber bridging; the document's booleans are what matter and
            // a 0/1 flag reads the same way to a user.
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                flags[key] = number.boolValue
            } else if let bool = value as? Bool {
                flags[key] = bool
            }
        }
        let detail = (root["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HouseCommandStatus(flags: flags, detail: (detail?.isEmpty ?? true) ? nil : detail)
    }
}

/// What went wrong running a house command. Every case is a sentence the
/// launcher can show the user as it stands.
enum HouseCommandError: LocalizedError, Equatable {
    case unreachable(app: String)
    case timedOut(app: String)
    case refused(app: String, message: String)
    case notInstalled(app: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let app): "\(app) is not running."
        case .timedOut(let app): "\(app) did not answer in time."
        case .refused(let app, let message): "\(app): \(message)"
        case .notInstalled(let app): "\(app) is not installed."
        }
    }
}
