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

    /// The rows as the last refresh left them, with no I/O of any kind.
    func rows() -> [HouseCommandRow] {
        manifests.flatMap { manifest in
            let status = statuses[manifest.app]?.status
            return manifest.commands
                .filter { $0.isAvailable(given: status) }
                .map {
                    HouseCommandRow(manifest: manifest, command: $0, statusDetail: status?.detail)
                }
        }
    }

    /// Runs the row's command. The argument is the user's answer for a
    /// command that needs one, and nil for one that does not. Failures are
    /// thrown so the launcher can say plainly what went wrong.
    @discardableResult
    func run(_ row: HouseCommandRow, argument: String? = nil) async throws -> String {
        // The run changes what the app is doing, so its status is stale the
        // moment the command lands.
        statuses[row.manifest.app] = nil
        return try await dispatcher.run(row.command, argument: argument, in: row.manifest)
    }

    /// The row behind a launcher item's value, or nil once the app has
    /// stopped publishing it.
    func row(forValue value: String) -> HouseCommandRow? {
        rows().first { $0.id == value }
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
    /// `house.<app>.<command>#<choice>`.
    static func choiceValue(rowID: String, choice: String) -> String {
        "\(rowID)#\(choice)"
    }

    /// Splits a choice row's value back into the command and the option.
    /// Nil for a plain command value.
    static func choice(inValue value: String) -> (rowID: String, choice: String)? {
        guard isHouseCommand(value), let hash = value.firstIndex(of: "#") else { return nil }
        let choice = String(value[value.index(after: hash)...])
        guard !choice.isEmpty else { return nil }
        return (String(value[value.startIndex..<hash]), choice)
    }
}
