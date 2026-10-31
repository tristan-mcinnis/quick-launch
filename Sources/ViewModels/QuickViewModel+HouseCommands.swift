import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    /// Re-reads every manifest and the statuses that gate rows, off the main
    /// thread, and applies the result. Never throws and never blocks: an app
    /// that is missing, dead, or slow simply offers nothing this time round.
    ///
    /// A request made while a refresh is in flight is not dropped: it marks
    /// one more refresh pending, run after the current one, so the newest
    /// state wins and two refreshes never overlap.
    ///
    /// `force` skips the catalog's status cache. A follow-up always forces,
    /// and so does a refresh that follows a command run: both exist because
    /// the app's state just changed, so a status read moments ago is stale.
    func refreshHouseCommands(force: Bool = false) {
        guard let houseCommandCatalog else { return }
        if houseCommandRefreshTask != nil {
            houseCommandRefreshPending = true
            return
        }
        houseCommandRefreshForce = force
        houseCommandRefreshTask = Task { @MainActor [weak self] in
            repeat {
                let forced = self?.houseCommandRefreshForce ?? false
                self?.houseCommandRefreshPending = false
                self?.houseCommandRefreshForce = true  // any follow-up forces
                let rows = await houseCommandCatalog.refresh(force: forced)
                guard let self else { return }
                self.applyHouseCommands(rows)
            } while self?.houseCommandRefreshPending == true
            self?.houseCommandRefreshTask = nil
        }
    }

    /// Waits out a running refresh and its follow-up, for tests.
    func waitForHouseCommandRefreshForTesting() async {
        await houseCommandRefreshTask?.value
        houseCommandRefreshTask = nil
    }

    func applyHouseCommands(_ rows: [HouseCommandRow]) {
        guard rows.map(\.id) != houseCommandRows.map(\.id) || rows != houseCommandRows else { return }
        houseCommandRows = rows
        // A row that has just gone away must not stay on screen as a prompt.
        if let pendingHouseChoice, !rows.contains(where: { $0.id == pendingHouseChoice.row.id }) {
            self.pendingHouseChoice = nil
        }
        if let pendingHouseCommandText, !rows.contains(where: { $0.id == pendingHouseCommandText.id }) {
            self.pendingHouseCommandText = nil
            if inputMode == .houseCommandArgument { inputMode = nil }
        }
        invalidateLauncherRanking()
    }

    /// The choices of the command being asked about, as launcher rows,
    /// narrowed by what has been typed.
    var houseChoiceItems: [LauncherCatalogItem] {
        guard let pending = pendingHouseChoice else { return [] }
        let row = pending.row
        let items = pending.choices.enumerated().map { index, choice in
            // The option is carried by position, never by its own id: an id
            // is opaque and may hold any character, including the one that
            // separates it from the command.
            let value = HouseCommandCatalog.choiceValue(rowID: row.id, index: index)
            return LauncherCatalogItem(
                kind: .command,
                itemID: value,
                title: choice.title,
                detail: choice.detail ?? (row.manifest.name + " · " + row.command.title),
                value: value,
                keywords: choice.id + " " + row.command.title
            )
        }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let folded = FuzzyMatcher.fold(query)
        return items
            .compactMap { item -> (LauncherCatalogItem, Int)? in
                guard let score = FuzzyMatcher.score(
                    foldedQuery: folded,
                    foldedCandidate: FuzzyMatcher.fold(item.title)
                ) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Return on a house command row: run it, ask for its text, or show its
    /// choices.
    func performHouseCommand(_ item: LauncherCatalogItem) async {
        guard let houseCommandCatalog else { return }
        // A choice row names its option by position in the list the user is
        // looking at.
        if let picked = HouseCommandCatalog.choice(inValue: item.value) {
            guard let pending = pendingHouseChoice,
                  pending.row.id == picked.rowID,
                  pending.choices.indices.contains(picked.index)
            else {
                errorMessage = "That command is no longer available."
                requestInputFocus()
                return
            }
            let row = pending.row
            let choice = pending.choices[picked.index]
            pendingHouseChoice = nil
            await runHouseCommand(row, argument: choice.id)
            return
        }
        guard let row = await houseCommandCatalog.row(forValue: item.value) else {
            errorMessage = "That command is no longer available."
            requestInputFocus()
            return
        }
        switch row.command.needs {
        case .text:
            pendingHouseCommandText = row
            enterInputMode(.houseCommandArgument)
        case .choice:
            // The list is fetched now, not at launch: it changes under a
            // running app. A fetch that fails says so instead of opening a
            // picker with nothing in it.
            do {
                let choices = try await houseCommandCatalog.choices(for: row)
                pendingHouseChoice = PendingHouseChoice(row: row, choices: choices)
                inputMode = nil
                catalogScope = nil
                input = ""
                errorMessage = nil
                applicationSelectionIndex = 0
                invalidateLauncherRanking()
                requestInputFocus()
                noteInteraction()
            } catch {
                errorMessage = error.localizedDescription
                requestInputFocus()
            }
        case nil:
            await runHouseCommand(row, argument: nil)
        }
    }

    /// Runs one house command and reports the outcome where every other
    /// launcher failure is reported. A command that fails says so.
    func runHouseCommand(_ row: HouseCommandRow, argument: String?) async {
        guard let houseCommandCatalog else { return }
        errorMessage = nil
        do {
            let outcome = try await houseCommandCatalog.run(row, argument: argument)
            noteFeatureUse(.houseCommandRun, itemID: "command:\(row.id)")
            input = ""
            switch outcome {
            case .completed(let reply):
                // The app's own words when it sent any, so a command that
                // answers something useful is not swallowed.
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text.lowercased() == "ok" {
                    overlayPresenter.dismissOverlay()
                } else {
                    answerSource = .command(row.command.title)
                    output = text
                    lastQuestion = row.command.title
                    requestInputFocus()
                }
            case .started:
                // The work is running. The launcher says so at once and
                // watches for the end; it never waits for it.
                answerSource = .command(row.command.title)
                lastQuestion = row.command.title
                output = "Started. \(row.manifest.name) is working."
                requestInputFocus()
                watchHouseCommand(row)
            }
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
        // What the app is doing has changed, so the rows must catch up.
        refreshHouseCommands(force: true)
    }

    /// Follows work that started, off the launcher's path, and reports how
    /// it ended. A poll that never settles is a reported failure, not a
    /// hang: the launcher stays usable throughout either way.
    private func watchHouseCommand(_ row: HouseCommandRow) {
        guard let houseCommandCatalog else { return }
        houseCommandWaitTask?.cancel()
        houseCommandWaitTask = Task { @MainActor [weak self] in
            let status = await houseCommandCatalog.waitWhileBusy(row)
            guard let self, !Task.isCancelled else { return }
            // The user has moved on: their screen is not ours to take back.
            guard self.lastQuestion == row.command.title else { return }
            if let status {
                if status.ok {
                    self.output = status.detail ?? "Finished."
                } else {
                    self.errorMessage = status.detail ?? "\(row.manifest.name) could not finish."
                }
            } else {
                self.errorMessage = "\(row.manifest.name) did not finish in time."
            }
            self.houseCommandWaitTask = nil
            self.refreshHouseCommands(force: true)
        }
    }

    /// Waits out a running watch, for tests.
    func waitForHouseCommandWatchForTesting() async {
        await houseCommandWaitTask?.value
        houseCommandWaitTask = nil
    }
}
