import Foundation

/// One house command as the launcher shows it: the row, plus everything
/// needed to run it if the user picks it.
struct HouseCommandRow: Sendable, Equatable, Identifiable {
    let manifest: HouseCommandManifest
    let command: HouseCommand
    /// The app's `detail` phrase when it answered a status, shown verbatim
    /// under the app name. Nil when the app reports none.
    let statusDetail: String?

    /// `house.<app>.<command id>`. Stable, so an alias or a hotkey set on a
    /// row survives a manifest rewrite.
    var id: String { HouseCommandCatalog.itemValue(app: manifest.app, commandID: command.id) }

    /// The row reads as the effect, with the owning app as the detail:
    /// "Start Recording", "RTI".
    var item: LauncherCatalogItem {
        var detail = manifest.name
        if let statusDetail, !statusDetail.isEmpty { detail += " · " + statusDetail }
        return LauncherCatalogItem(
            kind: .command,
            itemID: id,
            title: command.title,
            detail: detail,
            value: id,
            requiresInput: command.needs != nil,
            keywords: "\(manifest.name) \(manifest.app) \(command.verb) house app command"
        )
    }
}

/// Reads every house manifest, keeps each app's status honest, and hands the
/// launcher the rows it may show.
///
/// An actor, because it owns file reads, sockets, HTTP, and child processes.
/// Nothing here ever throws to its caller: a missing folder, a dead socket,
/// an app that is not installed, and a timeout all come back as "that row is
/// not on offer", never as an error the launcher has to handle.
actor HouseCommandCatalog {
    /// A status read is worth doing again after this long. Short enough that
    /// a row cannot lie for long, long enough that opening the launcher
    /// twice in a row costs one read, not two.
    static let statusFreshness: TimeInterval = 2

    private let directory: HouseCommandDirectory
    private let dispatcher: any HouseCommandDispatching
    private let now: @Sendable () -> Date

    private var manifests: [HouseCommandManifest] = []
    private var statuses: [String: (status: HouseCommandStatus?, readAt: Date)] = [:]

    init(
        directory: HouseCommandDirectory = HouseCommandDirectory(),
        dispatcher: any HouseCommandDispatching = HouseCommandDispatcher(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.dispatcher = dispatcher
        self.now = now
    }

    /// Re-reads the manifests and the statuses they gate rows on, then
    /// returns the rows worth showing. Every status is read concurrently and
    /// each carries its own timeout, so the slowest app sets the cost, not
    /// the sum of them.
    func refresh() async -> [HouseCommandRow] {
        manifests = directory.manifests()
        let needing = manifests.filter(\.needsStatus)
        await withTaskGroup(of: (String, HouseCommandStatus?).self) { group in
            for manifest in needing where !isFresh(manifest.app) {
                group.addTask { [dispatcher] in
                    // A dead socket, a missing app, or a timeout is not an
                    // error here: it is simply no status.
                    let status = try? await dispatcher.status(for: manifest)
                    return (manifest.app, status)
                }
            }
            for await (app, status) in group {
                statuses[app] = (status, now())
            }
        }
        return rows()
    }

    /// The rows worth showing, as the last refresh left them, with no I/O of
    /// any kind. `unavailableWhen` decides what is drawn and nothing else.
    func rows() -> [HouseCommandRow] {
        allRows().filter { $0.command.isAvailable(given: statuses[$0.manifest.app]?.status) }
    }

    /// Every command every manifest publishes, shown or not. A row hidden by
    /// `unavailableWhen` is still reachable (an alias, a hotkey, a stale
    /// list), and the app answers it idempotently, so a lookup must never
    /// refuse one on the strength of a display hint.
    func allRows() -> [HouseCommandRow] {
        manifests.flatMap { manifest in
            let status = statuses[manifest.app]?.status
            return manifest.commands.map {
                HouseCommandRow(manifest: manifest, command: $0, statusDetail: status?.detail)
            }
        }
    }

    /// Runs the row's command. The argument is the user's answer for a
    /// command that needs one, and nil for one that does not. Failures are
    /// thrown so the launcher can say plainly what went wrong.
    @discardableResult
    func run(_ row: HouseCommandRow, argument: String? = nil) async throws -> HouseCommandOutcome {
        // The run changes what the app is doing, so its status is stale the
        // moment the command lands.
        statuses[row.manifest.app] = nil
        return try await dispatcher.run(row.command, argument: argument, in: row.manifest)
    }

    /// The row behind a launcher item's value, or nil once the app has
    /// stopped publishing it. Searches every command, not only the ones on
    /// offer: a dimmed row the user reaches anyway still runs.
    func row(forValue value: String) -> HouseCommandRow? {
        allRows().first { $0.id == value }
    }

    /// The options for a `choice` command, fetched now because the user has
    /// just opened it. A list frozen at launch would already be stale.
    /// An empty answer is a failure: a picker with nothing in it is worse
    /// than a sentence saying so.
    func choices(for row: HouseCommandRow) async throws -> [HouseCommandChoice] {
        let choices = try await dispatcher.choices(for: row.command, in: row.manifest)
        guard !choices.isEmpty else {
            throw HouseCommandError.noChoices(app: row.manifest.name, command: row.command.title)
        }
        return choices
    }

    /// Polls an app's status until it stops being busy, for work that
    /// started rather than finished. Reads past the cache, gives up at
    /// `deadline`, and returns the last status it saw, or nil on a timeout.
    /// The caller runs this off the launcher's path.
    func waitWhileBusy(
        _ row: HouseCommandRow,
        pollEvery interval: Duration = .milliseconds(400),
        deadline: TimeInterval = 120
    ) async -> HouseCommandStatus? {
        let app = row.manifest.app
        let until = now().addingTimeInterval(deadline)
        while now() < until {
            statuses[app] = nil
            let status = try? await dispatcher.status(for: row.manifest)
            if let status, !status.busy {
                statuses[app] = (status, now())
                return status
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: interval)
        }
        return nil
    }

    static let valuePrefix = "house."

    static func itemValue(app: String, commandID: String) -> String {
        "\(valuePrefix)\(app).\(commandID)"
    }

    static func isHouseCommand(_ value: String) -> Bool {
        value.hasPrefix(valuePrefix)
    }

    private func isFresh(_ app: String) -> Bool {
        guard let entry = statuses[app] else { return false }
        return now().timeIntervalSince(entry.readAt) < Self.statusFreshness
    }
}

extension HouseCommandCatalog {
    /// A picked option, carried in the row's own value so the existing
    /// launcher row and its Return need nothing new:
    /// `house.<app>.<command>#<position>`. The position, not the option's
    /// own id, because an id is opaque and may hold any character.
    static func choiceValue(rowID: String, index: Int) -> String {
        "\(rowID)#\(index)"
    }

    /// Splits a choice row's value back into the command and the position.
    /// Nil for a plain command value.
    static func choice(inValue value: String) -> (rowID: String, index: Int)? {
        guard isHouseCommand(value), let hash = value.lastIndex(of: "#") else { return nil }
        guard let index = Int(value[value.index(after: hash)...]), index >= 0 else { return nil }
        return (String(value[value.startIndex..<hash]), index)
    }
}
