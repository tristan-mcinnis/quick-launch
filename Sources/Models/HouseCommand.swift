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
    /// Where a `choice` command's options come from. A list frozen into a
    /// manifest at launch is stale by lunchtime, so the manifest names a
    /// route and the caller fetches it when the user opens the command.
    let choicesFrom: String?
    let unavailableWhen: HouseCommandCondition?

    /// Whether the row is worth showing. A **display hint only**: the app
    /// still accepts the command at any time and answers idempotently, so a
    /// hidden row is never a refused command. A command with no condition is
    /// always shown.
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
    /// Always resolved and absolute: the reader takes it literally, expands
    /// nothing, and assumes no path layout.
    let endpoint: String
    /// Where the status document comes from: a verb for `socket`, a route
    /// for `http`, and an absolute path to a JSON file for `exec`, which is
    /// stateless and cannot answer for the app. Absent means this app
    /// reports no status.
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
            endpoint: endpoint,
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
        let choicesFrom = string(object["choicesFrom"]).flatMap { $0.isEmpty ? nil : $0 }
        // A command that asks for a choice without saying where the choices
        // come from cannot be offered: there is no picker to draw.
        if needs == .choice, choicesFrom == nil { return nil }
        let condition = string(object["unavailableWhen"]).flatMap(HouseCommandCondition.init(rawValue:))
        return HouseCommand(
            id: id,
            title: title,
            verb: verb,
            needs: needs,
            choicesFrom: choicesFrom,
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
}

/// One option a `choice` command offers. The chosen `id` is what goes back
/// as the command's argument; the title and detail are for the row.
struct HouseCommandChoice: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String?

    /// `{"choices": [{"id", "title", "detail"}]}`. Total, like every other
    /// parse here: anything unreadable is no choices at all, which the
    /// caller reports rather than drawing a broken picker.
    static func parse(_ text: String) -> [HouseCommandChoice] {
        guard let data = text.data(using: .utf8) else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [HouseCommandChoice] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let raw = root["choices"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty
            else { return nil }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (entry["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return HouseCommandChoice(
                id: id,
                title: (title?.isEmpty ?? true) ? id : title!,
                detail: (detail?.isEmpty ?? true) ? nil : detail
            )
        }
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
    case noChoices(app: String, command: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let app): "\(app) is not running."
        case .timedOut(let app): "\(app) did not answer in time."
        case .refused(let app, let message): "\(app): \(message)"
        case .notInstalled(let app): "\(app) is not installed."
        case .noChoices(let app, let command): "\(app) has nothing to offer for \(command)."
        }
    }
}
