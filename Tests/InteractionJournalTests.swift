import Foundation
import CryptoKit
import Testing
@testable import QuickLaunch

@Suite("Interaction journal", .serialized)
@MainActor
struct InteractionJournalTests {

    private static let claude = LaunchableApplication(
        name: "Claude",
        bundleIdentifier: "com.anthropic.claudefordesktop",
        url: URL(fileURLWithPath: "/Applications/Claude.app")
    )
    private static let calendar = LaunchableApplication(
        name: "Calendar",
        bundleIdentifier: "com.apple.iCal",
        url: URL(fileURLWithPath: "/System/Applications/Calendar.app")
    )
    private static let clashX = LaunchableApplication(
        name: "ClashX",
        bundleIdentifier: "com.west2online.ClashX",
        url: URL(fileURLWithPath: "/Applications/ClashX.app")
    )

    /// A temporary journal file plus the explicit key path every test hands to
    /// the store. Nothing here resolves to the live app's Application Support
    /// folder, so no test can read, create, or tighten the real key.
    private func temporaryFile(
        _ name: String = "interaction-journal.json"
    ) -> (folder: URL, file: URL, key: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-journal-tests-\(UUID().uuidString)")
        return (
            folder,
            folder.appendingPathComponent(name),
            folder.appendingPathComponent(InteractionJournalStore.keyFileName)
        )
    }

    private func makeViewModel(
        settings: QuickSettings = QuickSettings(),
        journal: InteractionJournalStore? = nil,
        service: (any QuickService)? = nil,
        applications: [LaunchableApplication] = [claude, calendar, clashX]
    ) -> (QuickViewModel, InteractionJournalStore) {
        let store = journal ?? InteractionJournalStore(fileURL: nil)
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            applicationCatalog: JournalFakeApplicationCatalog(applications: applications),
            launcherUsage: LauncherUsageStore(fileURL: nil),
            interactionJournal: store
        )
        return (vm, store)
    }

    // MARK: - Store: shape, bounds, retention

    @Test func recordsOutcomesAndStaysBounded() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InteractionJournalStore(
            fileURL: nil,
            now: { clock },
            retentionDays: 7,
            eventCap: InteractionJournalStore.minimumEventCap
        )
        store.record(kind: .selectionAccepted, itemID: "application:claude", query: "cla")
        #expect(store.count == 1)
        #expect(store.lastEventDate == clock)

        // Retention: an event older than the window is dropped on the next record.
        clock = clock.addingTimeInterval(8 * 24 * 60 * 60)
        store.record(kind: .aiSucceeded, detail: "prompt")
        #expect(store.count == 1)
        #expect(store.recentEvents().first?.kind == .aiSucceeded)

        // Cap: only the newest `eventCap` events survive.
        for index in 0..<(InteractionJournalStore.minimumEventCap + 25) {
            clock = clock.addingTimeInterval(1)
            store.record(kind: .selectionAccepted, itemID: "application:item-\(index)")
        }
        #expect(store.count == InteractionJournalStore.minimumEventCap)
        #expect(store.recentEvents().last?.itemID == "application:item-25")
    }

    @Test func persistsOwnerOnlyAndReloads() throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        store.record(kind: .selectionAccepted, scope: "root", itemID: "application:claude", query: "cla")
        store.record(kind: .searchAbandoned, query: "zzz")
        store.waitForPendingWrites()

        #expect(FileManager.default.fileExists(atPath: file.path))
        let permissions = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let reloaded = InteractionJournalStore(fileURL: file, keyURL: key)
        #expect(reloaded.count == 2)
        #expect(reloaded.recentEvents().first?.kind == .searchAbandoned)
        #expect(reloaded.byteSize > 0)

        reloaded.clear()
        reloaded.waitForPendingWrites()
        #expect(reloaded.isEmpty)
        #expect(InteractionJournalStore(fileURL: file, keyURL: key).isEmpty)
    }

    @Test func storedEventCarriesNoContentFields() throws {
        let store = InteractionJournalStore(fileURL: nil)
        store.record(
            kind: .selectionAccepted,
            scope: "snippets",
            itemID: "snippet:greeting",
            query: "secret-password-please-never-store-me",
            detail: "action"
        )
        let event = try #require(store.recentEvents().first)
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(
            Set(object.keys) == [
                "id", "date", "kind", "scope", "itemID",
                "queryFingerprint", "queryLengthBucket", "detail",
                "markedAccidental", "fingerprintVersion",
            ],
            "the journal must not grow a field that can carry content"
        )
        #expect(event.queryFingerprint?.hasPrefix("v2:") == true)
        #expect(
            event.queryFingerprint?.count
                == InteractionJournalStore.digestLength + "v2:".count
        )
        // A coarse band, never the exact character count.
        #expect(event.queryLengthBucket == "32+")
        #expect(object["queryLength"] == nil)
        #expect(event.detail == "action")
        #expect(event.itemID == "snippet:greeting")
    }

    @Test func writtenFileNeverContainsTheTypedQuery() throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }

        let query = "mybank-login-8f3a1c-please-never-store"
        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        store.record(kind: .searchAbandoned, query: query)
        store.record(
            kind: .selectionAccepted,
            itemID: "application:claude",
            query: query
        )
        store.waitForPendingWrites()

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(!contents.contains(query))
        #expect(!contents.contains("mybank"))
        #expect(contents.contains("queryFingerprint"))
        #expect(contents.contains(try #require(store.fingerprint(ofQuery: query))))
        // The exact character count is not in the file either.
        #expect(!contents.contains("queryLength\""))
        #expect(contents.contains("queryLengthBucket"))
        // The folded query is what is digested, so repeats of the same typing
        // correlate with what ranking learns for it.
        #expect(
            store.fingerprint(ofQuery: "  MyBank LOGIN ")
                == store.fingerprint(ofQuery: "mybank login")
        )
    }

    // MARK: - Keyed digest and key file

    @Test func queryDigestsAreKeyedPerInstallAndOwnerOnly() throws {
        let (folderA, fileA, keyA) = temporaryFile("a.json")
        let (folderB, fileB, keyB) = temporaryFile("b.json")
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }
        let a = InteractionJournalStore(fileURL: fileA, keyURL: keyA)
        let b = InteractionJournalStore(fileURL: fileB, keyURL: keyB)

        let query = "flurble"
        #expect(a.fingerprint(ofQuery: query) != b.fingerprint(ofQuery: query))
        #expect(a.fingerprint(ofQuery: query) == a.fingerprint(ofQuery: query))

        let key = try #require(try? Data(contentsOf: keyA))
        #expect(key.count == InteractionJournalStore.keyByteCount)
        #expect(
            try FileManager.default.attributesOfItem(atPath: keyA.path)[.posixPermissions] as? Int
                == 0o600
        )
        // The digests cannot be recomputed from the journal alone: the file
        // never contains the key, and a keyless SHA-256 of the query is not it.
        a.record(kind: .searchAbandoned, query: query)
        a.waitForPendingWrites()
        let journalText = try String(contentsOf: fileA, encoding: .utf8)
        #expect(!journalText.contains(key.base64EncodedString()))
        #expect(!journalText.contains(
            SHA256.hash(data: Data("flurble".utf8)).map { String(format: "%02x", $0) }.joined()
        ))

        // Reopening with the same key file keeps repeat correlation working.
        let reopenedA = InteractionJournalStore(fileURL: fileA, keyURL: keyA)
        #expect(reopenedA.fingerprint(ofQuery: query) == a.fingerprint(ofQuery: query))
        #expect(reopenedA.record(kind: .searchAbandoned, query: query)?.kind == .searchRetried)
        // Flush before the temp folder is removed, so no queued write outlives
        // the test.
        reopenedA.waitForPendingWrites()
        a.waitForPendingWrites()
    }

    @Test func theKeySitsBesideItsJournalAndIsTightenedOnEveryLoad() throws {
        // The production path is unchanged: the default journal's key is the
        // documented default key file, in the same folder.
        #expect(
            InteractionJournalStore.keyURL(forJournalAt: InteractionJournalStore.defaultFileURL())
                == InteractionJournalStore.defaultKeyURL()
        )
        // Any other journal file gets a key of its own, in its own folder, so a
        // store pointed elsewhere never touches the live key.
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(InteractionJournalStore.keyURL(forJournalAt: file) == key)
        #expect(
            InteractionJournalStore.keyURL(forJournalAt: file)
                != InteractionJournalStore.defaultKeyURL()
        )

        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        _ = store
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: key.path
        )
        #expect(
            try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int
                == 0o644
        )
        // Loading the key again re-asserts owner-only.
        let reopened = InteractionJournalStore(fileURL: file, keyURL: key)
        #expect(
            try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int
                == 0o600
        )
        // Flush before the temp folder goes: a queued write would recreate it.
        reopened.waitForPendingWrites()
    }

    @Test func legacyJournalFileIsMigratedWithoutLosingRows() throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Exactly what the first build of this feature wrote: an unkeyed
        // SHA-256 digest, an exact character count, and no digest version.
        // The timestamps are recent, so retention does not drop the rows before
        // the migration under test can be observed.
        let legacyFingerprint = SHA256.hash(data: Data("flurble".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let first = Date().timeIntervalSinceReferenceDate - 120
        let second = first + 60
        let legacy = """
        {"version":1,"events":[
          {"id":"11111111-1111-1111-1111-111111111111",
           "date":\(first),
           "kind":"searchAbandoned",
           "scope":"snippets",
           "itemID":"quickLink:typed:https://example.com/?token=legacytoken",
           "queryFingerprint":"\(legacyFingerprint)",
           "queryLength":7,
           "detail":"action",
           "markedAccidental":true},
          {"id":"22222222-2222-2222-2222-222222222222",
           "date":\(second),
           "kind":"kindFromTheFuture",
           "scope":"root"}
        ]}
        """
        try Data(legacy.utf8).write(to: file)

        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        #expect(store.count == 2)
        let abandoned = try #require(store.recentEvents().last)
        // The row survives with its identity and detail...
        #expect(abandoned.kind == .searchAbandoned)
        #expect(abandoned.scope == "snippets")
        #expect(abandoned.detail == "action")
        #expect(abandoned.markedAccidental)
        // ...the exact length becomes a band...
        #expect(abandoned.queryLengthBucket == "4-7")
        // ...the keyless digest is dropped, and the URL identifier is digested.
        #expect(abandoned.queryFingerprint == nil)
        #expect(abandoned.itemID?.contains("legacytoken") == false)
        #expect(abandoned.itemID?.hasPrefix("redacted:v2:") == true)
        // An unknown kind is kept, not lost.
        #expect(store.recentEvents().first?.kind == .unknown)

        store.waitForPendingWrites()
        let rewritten = try String(contentsOf: file, encoding: .utf8)
        #expect(!rewritten.contains(legacyFingerprint))
        #expect(!rewritten.contains("legacytoken"))
        #expect(!rewritten.contains("\"queryLength\":"))
        #expect(rewritten.contains("queryLengthBucket"))
        #expect(rewritten.contains("fingerprintVersion"))

        // And a reload of the migrated file is stable.
        let reloaded = InteractionJournalStore(fileURL: file, keyURL: key)
        #expect(reloaded.count == 2)
        #expect(reloaded.recentEvents().last?.queryLengthBucket == "4-7")
        #expect(reloaded.recentEvents().first?.kind == .unknown)
        // Flush before the temp folder goes: a queued write would recreate it.
        reloaded.waitForPendingWrites()
    }

    @Test func dynamicItemIdentifiersAreDigestedAndContentFree() throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        let token = "token=super-secret-9f3a1c"
        let event = try #require(store.record(
            kind: .selectionAccepted,
            itemID: "quickLink:typed:https://example.com/reset?" + token
        ))
        #expect(event.itemID?.contains("super-secret") == false)
        #expect(event.itemID?.hasPrefix("redacted:v2:") == true)
        // A window title or any other free text is digested too.
        let title = try #require(store.record(
            kind: .selectionAccepted,
            itemID: "screenHistory:app:Inbox — Q3 layoffs at Acme Corp"
        ))
        #expect(title.itemID?.contains("Acme") == false)
        // A real launcher identity is kept verbatim so review stays useful.
        let known = try #require(store.record(
            kind: .selectionAccepted,
            itemID: "application:com.anthropic.claudefordesktop"
        ))
        #expect(known.itemID == "application:com.anthropic.claudefordesktop")
        #expect(store.sanitizedItemID("clipboard:9f3a1c2b") == "clipboard:9f3a1c2b")
        #expect(store.sanitizedItemID(nil) == nil)
        #expect(store.sanitizedItemID("") == nil)

        // Every identifier shape the launcher actually produces stays readable,
        // so the allowlist cannot quietly redact the whole review.
        let realIdentifiers = [
            "application:com.apple.Safari", "catalog:snippets", "command:window.leftHalf",
            "folder:downloads", "snippet:9F3A1C", "quickLink:1b2c3d",
            "clipboard:9f3a1c2b", "emoji:emoji-1f600", "screenshot:file-9f3a1c",
            "conversation:11111111-1111-1111-1111-111111111111", "answer:answer",
            "askAI:ask", "color:ff8800ff",
            "action:translate",
        ]
        for identifier in realIdentifiers {
            #expect(store.sanitizedItemID(identifier) == identifier, "\(identifier) should survive")
        }
        // Screen History rows were retired; an id left from them is no longer
        // a known identity, so it is digested like any other free text.
        #expect(store.sanitizedItemID("screenHistory:app:com.apple.Safari")?.hasPrefix("redacted:v2:") == true)
        // The typed-URL row is the one real shape that is always re-keyed: the
        // launcher's own identity for it is a keyless FNV-1a content hash, and
        // the journal does not inherit that non-cryptographic property.
        #expect(store.sanitizedItemID("quickLink:typed:9f3a1c2b")?.hasPrefix("redacted:v2:") == true)
        // And the sanitizer is idempotent, so a reloaded digest is stable.
        let digested = try #require(store.sanitizedItemID("typed:https://example.com/x"))
        #expect(store.sanitizedItemID(digested) == digested)

        store.waitForPendingWrites()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("super-secret"))
        #expect(!text.contains("Acme"))
        let export = InteractionJournalExporter.markdown(store.recentEvents())
        #expect(!export.contains("super-secret"))
        #expect(!export.contains("Acme"))
    }

    @Test func duplicateOutcomesInsideTheWindowAreOneRow() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InteractionJournalStore(fileURL: nil, now: { clock })
        store.record(kind: .selectionAccepted, itemID: "screenshot:one", query: "shot")

        // The screenshot path learns twice for one Return; that is one row.
        clock = clock.addingTimeInterval(0.2)
        store.record(kind: .selectionAccepted, itemID: "screenshot:one", query: "shot")
        #expect(store.count == 1)

        // A genuinely later repeat is a new row.
        clock = clock.addingTimeInterval(InteractionJournalStore.dedupeWindow + 1)
        store.record(kind: .selectionAccepted, itemID: "screenshot:one", query: "shot")
        #expect(store.count == 2)

        // A different event kind in the same window is not a duplicate.
        store.record(kind: .actionFailed, itemID: "screenshot:one", detail: "action")
        #expect(store.count == 3)
    }

    @Test func secondAbandonmentOfTheSameQueryIsARetry() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InteractionJournalStore(fileURL: nil, now: { clock })
        store.record(kind: .searchAbandoned, query: "flurble")
        #expect(store.recentEvents().first?.kind == .searchAbandoned)

        clock = clock.addingTimeInterval(60)
        store.record(kind: .searchAbandoned, query: "flurble")
        #expect(store.recentEvents().first?.kind == .searchRetried)

        // Another query is a fresh abandonment, not a retry.
        clock = clock.addingTimeInterval(60)
        store.record(kind: .searchAbandoned, query: "wibble")
        #expect(store.recentEvents().first?.kind == .searchAbandoned)

        // Outside the retry window the same query is abandoned again.
        clock = clock.addingTimeInterval(InteractionJournalStore.retryWindow + 1)
        store.record(kind: .searchAbandoned, query: "flurble")
        #expect(store.recentEvents().first?.kind == .searchAbandoned)
    }

    @Test func accidentalMarkerIsExplicitReversibleAndPersisted() {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = InteractionJournalStore(fileURL: file, keyURL: key)
        let event = store.record(kind: .selectionAccepted, itemID: "application:claude")
        let id = try! #require(event?.id)
        #expect(store.markedAccidentalCount == 0)

        #expect(store.setMarkedAccidental(true, id: id))
        #expect(store.markedAccidentalCount == 1)
        // Repeating the same value is a no-op, so nothing is rewritten.
        #expect(!store.setMarkedAccidental(true, id: id))
        store.waitForPendingWrites()
        #expect(InteractionJournalStore(fileURL: file, keyURL: key).markedAccidentalCount == 1)

        let reloaded = InteractionJournalStore(fileURL: file, keyURL: key)
        #expect(reloaded.setMarkedAccidental(false, id: id))
        reloaded.waitForPendingWrites()
        #expect(InteractionJournalStore(fileURL: file, keyURL: key).markedAccidentalCount == 0)
        // An unknown id is ignored rather than inventing a row.
        #expect(!reloaded.setMarkedAccidental(true, id: UUID()))
    }

    @Test func boundsAreClamped() {
        let store = InteractionJournalStore(
            fileURL: nil,
            retentionDays: -5,
            eventCap: 1
        )
        #expect(store.retentionDays == InteractionJournalStore.minimumRetentionDays)
        #expect(store.eventCap == InteractionJournalStore.minimumEventCap)
        store.retentionDays = 5_000
        store.eventCap = 999_999
        #expect(store.retentionDays == InteractionJournalStore.maximumRetentionDays)
        #expect(store.eventCap == InteractionJournalStore.maximumEventCap)
    }

    // MARK: - Store: no query, no fingerprint

    @Test func anEmptyOrWhitespaceQueryHasNoFingerprint() {
        let store = InteractionJournalStore(fileURL: nil)
        store.record(kind: .searchAbandoned, query: "   ")
        let event = store.recentEvents().first
        #expect(event?.queryFingerprint == nil)
        #expect(event?.queryLengthBucket == nil)
    }

    @Test func lengthBucketsAreCoarse() {
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 0) == nil)
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 1) == "1-3")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 3) == "1-3")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 4) == "4-7")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 8) == "8-15")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 16) == "16-31")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 32) == "32+")
        #expect(InteractionJournalStore.lengthBucket(forFoldedLength: 900) == "32+")
    }

    // MARK: - Picker robustness (every clamped value must be selectable)

    @Test func everyClampedSettingsValueHasAPickerChoice() {
        for days in InteractionJournalStore.minimumRetentionDays...InteractionJournalStore.maximumRetentionDays {
            let choices = InteractionJournalStore.retentionChoices(
                including: InteractionJournalStore.clampRetention(days)
            )
            #expect(choices.contains(InteractionJournalStore.clampRetention(days)))
        }
        for cap in stride(
            from: InteractionJournalStore.minimumEventCap,
            through: InteractionJournalStore.maximumEventCap,
            by: 37
        ) {
            let choices = InteractionJournalStore.eventCapChoices(
                including: InteractionJournalStore.clampEventCap(cap)
            )
            #expect(choices.contains(InteractionJournalStore.clampEventCap(cap)))
        }
        // Out-of-range values clamp first, so they are still selectable.
        #expect(InteractionJournalStore.retentionChoices(including: 9_000)
            .contains(InteractionJournalStore.maximumRetentionDays))
        #expect(InteractionJournalStore.eventCapChoices(including: -1)
            .contains(InteractionJournalStore.minimumEventCap))
        // The shipped defaults are presets, so the picker is never empty or odd.
        #expect(InteractionJournalStore.retentionPresets
            .contains(InteractionJournalStore.defaultRetentionDays))
        #expect(InteractionJournalStore.eventCapPresets
            .contains(InteractionJournalStore.defaultEventCap))
        #expect(InteractionJournalStore.retentionChoices(including: 30)
            == InteractionJournalStore.retentionPresets)
        #expect(InteractionJournalStore.eventCapChoices(including: 2_000)
            == InteractionJournalStore.eventCapPresets)
    }

    // MARK: - Disabling retains existing data

    @Test func disablingStopsNewRecordingAndKeepsExistingEventsManageable() throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = InteractionJournalStore(fileURL: file, keyURL: key)
        let (vm, _) = makeViewModel(journal: journal)
        vm.updateSettings { $0.interactionJournalEnabled = false }
        vm.applyInteractionJournalSettings()

        // Nothing new is recorded while it is off.
        vm.input = "flurble"
        vm.endInteractionSession()
        vm.noteDirectHotkeyUse(itemID: "action:translate")
        #expect(journal.isEmpty)

        // Existing events stay put, and stay reviewable, exportable, clearable.
        journal.record(kind: .selectionAccepted, itemID: "application:claude", query: "cla")
        journal.waitForPendingWrites()
        vm.updateSettings { $0.interactionJournalEnabled = true }
        vm.applyInteractionJournalSettings()
        #expect(vm.interactionJournalEvents.count == 1)
        #expect(!vm.renderInteractionJournal(as: .markdown).isEmpty)

        vm.updateSettings { $0.interactionJournalEnabled = false }
        vm.applyInteractionJournalSettings()
        #expect(vm.interactionJournalEvents.count == 1, "disabling must not delete data")
        #expect(!vm.renderInteractionJournal(as: .jsonLines).isEmpty)
        vm.clearInteractionJournal()
        #expect(vm.interactionJournalEvents.isEmpty)
        journal.waitForPendingWrites()
        #expect(InteractionJournalStore(fileURL: file, keyURL: key).isEmpty)
    }

    @Test func retentionStillAgesEventsOutWhileRecordingIsOff() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = InteractionJournalStore(fileURL: nil, now: { clock })
        let (vm, _) = makeViewModel(journal: journal)
        vm.updateSettings {
            $0.interactionJournalEnabled = true
            $0.interactionJournalRetentionDays = 7
        }
        vm.applyInteractionJournalSettings()
        journal.record(kind: .selectionAccepted, itemID: "application:claude")
        #expect(journal.count == 1)

        // Off: no new rows, and the old one still expires on the retention that
        // was in force, because a dismissal prunes regardless of the toggle.
        vm.updateSettings { $0.interactionJournalEnabled = false }
        vm.applyInteractionJournalSettings()
        clock = clock.addingTimeInterval(8 * 24 * 60 * 60)
        vm.input = "flurble"
        vm.endInteractionSession()
        #expect(journal.isEmpty)
    }

    // MARK: - View model: wiring

    @Test func anAcceptedSelectionIsJournalledOnce() async {
        let (vm, journal) = makeViewModel()
        vm.input = "cla"
        let index = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.performLauncherResult(vm.launcherMatches[index])

        let events = journal.recentEvents().filter { $0.kind == .selectionAccepted }
        #expect(events.count == 1)
        #expect(events.first?.itemID == "application:com.anthropic.claudefordesktop")
        #expect(events.first?.scope == LauncherUsageStore.rootScope)

        // The screenshot path calls `learn` a second time for one Return while
        // the typed query is still in the field: the store's dedupe window
        // keeps that to one review row.
        vm.input = "cla"
        vm.learn(.application(Self.claude))
        #expect(journal.recentEvents().filter { $0.kind == .selectionAccepted }.count == 1)
    }

    @Test func launcherItemHotkeysAreJournalledWithoutTouchingRanking() {
        let (vm, journal) = makeViewModel()
        vm.learnDirectUse(of: Self.clashX)
        #expect(journal.count(of: .directHotkeyUse) == 1)
        #expect(vm.launcherUsage.frecency(itemID: "application:com.west2online.ClashX") > 0.99)

        // A saved-action hotkey keeps a journal row and leaves ranking alone.
        vm.noteDirectHotkeyUse(itemID: "action:translate")
        #expect(journal.count(of: .directHotkeyUse) == 2)
        #expect(journal.recentEvents().first?.itemID == "action:translate")
        #expect(vm.launcherUsage.frecency(itemID: "action:translate") == 0)
    }

    @Test func anAbandonedSearchAndItsRetryAreJournalledAtSessionEnd() async {
        let (vm, journal) = makeViewModel()
        vm.input = "flurble"
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 1)

        vm.input = "flurble"
        vm.endInteractionSession()
        #expect(journal.count(of: .searchRetried) == 1)

        // A session that chose something is not an abandoned search.
        vm.input = "cla"
        let index = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.performLauncherResult(vm.launcherMatches[index])
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 1)
        // Only search events carry a query fingerprint; the abandoned row does.
        #expect(journal.recentEvents().first?.kind == .selectionAccepted)
        #expect(
            journal.recentEvents().first(where: { $0.kind == .searchAbandoned })?.queryFingerprint != nil
        )
    }

    @Test func closingWithNothingTypedOrWithAnAnswerIsNotAbandoned() async {
        let mock = MockQuickService()
        let (vm, journal) = makeViewModel(service: mock)
        vm.settings.autoCopy = false

        // Nothing typed.
        vm.input = ""
        vm.endInteractionSession()
        #expect(journal.isEmpty)

        // An answer on screen is not an abandoned search.
        await mock.setResponses([StreamDelta(text: "Bonjour", finishReason: "stop")])
        vm.input = "hello"
        await vm.submit()
        #expect(journal.count(of: .aiSucceeded) == 1)
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 0)
    }

    @Test func aiFailuresAndCancellationsAreJournalled() async throws {
        let failing = MockQuickService()
        await failing.setShouldThrow(true)
        let (vm, journal) = makeViewModel(service: failing)
        vm.input = "hello"
        await vm.submit()
        #expect(journal.count(of: .aiFailed) == 1)
        #expect(journal.recentEvents().first?.detail == "provider-error")
        // The failure text itself is never stored, and a prompt is never
        // fingerprinted: only launcher-search events carry a query fingerprint.
        #expect(journal.recentEvents().first?.detail?.contains("intentional") == false)
        #expect(journal.recentEvents().first?.queryFingerprint == nil)

        let slow = MockQuickService()
        await slow.setResponses([StreamDelta(text: "chunk one", finishReason: nil)])
        await slow.setDelay(.milliseconds(200))
        let (cancelling, cancelJournal) = makeViewModel(service: slow)
        cancelling.input = "long prompt"
        let submitTask = Task { await cancelling.submit() }
        #expect(await waitForStreaming(cancelling))
        cancelling.cancel()
        await submitTask.value
        #expect(cancelJournal.count(of: .aiCancelled) == 1)
        #expect(cancelJournal.recentEvents().first?.queryFingerprint == nil)
    }

    /// A request that failed or was cancelled was still a submission. Closing
    /// the overlay afterwards must not also file it as an abandoned search,
    /// whether the question stayed in the thread (a provider error) or came
    /// back into `input` (a search that failed).
    @Test func aFailedRequestIsNotAlsoAnAbandonedSearch() async {
        let failing = MockQuickService()
        await failing.setShouldThrow(true)
        let (vm, journal) = makeViewModel(service: failing)
        vm.input = "summarize this text"
        await vm.submit()
        #expect(vm.threadError != nil)
        #expect(vm.conversationMessages.last?.content == "summarize this text", "the question stays a turn")

        vm.endInteractionSession()
        #expect(journal.count(of: .aiFailed) == 1)
        #expect(journal.count(of: .searchAbandoned) == 0)
        #expect(journal.count(of: .searchRetried) == 0)

        // A genuinely different query after the failure is still an abandonment.
        vm.input = "flurble"
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 1)
        #expect(journal.count(of: .aiFailed) == 1)
    }

    @Test func aCancelledRequestIsNotAlsoAnAbandonedSearch() async throws {
        let slow = MockQuickService()
        await slow.setResponses([StreamDelta(text: "chunk one", finishReason: nil)])
        await slow.setDelay(.milliseconds(200))
        let (vm, journal) = makeViewModel(service: slow)
        vm.input = "long prompt"
        let submitTask = Task { await vm.submit() }
        #expect(await waitForStreaming(vm))
        vm.cancel()
        await submitTask.value

        #expect(journal.count(of: .aiCancelled) == 1)
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 0)
        #expect(journal.count(of: .searchRetried) == 0)
    }

    @Test func aMissingProviderIsNotAlsoAnAbandonedSearch() async {
        // No injected service and no API key, so the request fails on the key
        // check before streaming ever starts.
        let (vm, journal) = makeViewModel(service: nil)
        vm.apiKeyProvider = { _ in "" }
        vm.input = "hello there"
        await vm.submit()
        #expect(journal.count(of: .aiFailed) == 1)
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 0)
        #expect(journal.count(of: .searchRetried) == 0)
    }

    // MARK: - Command actions

    @Test func aSuccessfulCommandActionIsJournalled() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.savedPrompts = [SavedPrompt(
            alias: "run-echo",
            prompt: "{input}",
            commandExecutable: "/bin/echo",
            commandArguments: ["fixed", "{input}"]
        )]
        let (vm, journal) = makeViewModel(settings: settings)
        vm.input = "/run-echo hello"
        await vm.submit()
        #expect(vm.output.contains("hello"))
        #expect(journal.count(of: .actionSucceeded) == 1)
        #expect(journal.recentEvents().first?.detail == "command")
        // The command's output and the substituted input are never stored.
        #expect(journal.recentEvents().first?.queryFingerprint == nil)
        #expect(journal.recentEvents().first?.itemID == nil)
    }

    @Test func cancellingACommandActionTerminatesItAndDiscardsLateOutput() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.savedPrompts = [SavedPrompt(
            alias: "run-slow",
            prompt: "{input}",
            commandExecutable: "/bin/sleep",
            commandArguments: ["5"]
        )]
        let (vm, journal) = makeViewModel(settings: settings)
        vm.input = "/run-slow"
        let submitTask = Task { await vm.submit() }
        #expect(await waitForStreaming(vm), "the command is running")

        vm.cancel()
        await submitTask.value

        #expect(journal.count(of: .actionCancelled) == 1)
        #expect(journal.count(of: .actionSucceeded) == 0)
        #expect(vm.output == "")
        #expect(!vm.isStreaming)
        // Waiting well past the sleep must not resurrect the command's output
        // (sleep writes none, so this checks the result is never re-assigned).
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.output == "")
        #expect(journal.count(of: .actionSucceeded) == 0)
        #expect(journal.count(of: .actionCancelled) == 1)
        // The typed alias comes back so the user can retry or edit it.
        #expect(vm.input == "/run-slow")
    }

    @Test func aFailedCommandActionIsJournalledAsAFailure() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.savedPrompts = [SavedPrompt(
            alias: "run-missing",
            prompt: "{input}",
            commandExecutable: "/definitely/not/installed",
            commandArguments: []
        )]
        let (vm, journal) = makeViewModel(settings: settings)
        vm.input = "/run-missing"
        await vm.submit()
        #expect(journal.count(of: .actionFailed) == 1)
        #expect(journal.count(of: .actionSucceeded) == 0)
        #expect(journal.recentEvents().first?.detail == "command-error")
        vm.endInteractionSession()
        #expect(journal.count(of: .searchAbandoned) == 0)
    }

    // MARK: - Typed URLs never reach the journal

    @Test func anAcceptedAskAIRowStoresOnlyAQueryDigest() async throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = InteractionJournalStore(fileURL: file, keyURL: key)
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Paris.", finishReason: "stop")])
        let (vm, _) = makeViewModel(journal: journal, service: mock)
        vm.settings.autoCopy = false

        let question = "what is the capital of France"
        vm.input = question
        let row = try #require(vm.launcherMatches.first { result in
            guard case .item(let item) = result else { return false }
            return item.kind == .askAI
        })
        guard case .item(let askItem) = row else {
            Issue.record("expected the Ask AI row")
            return
        }
        // The row's id is fixed; the typed question is carried in its title,
        // detail, and value, none of which the journal stores.
        #expect(askItem.itemID == QuickViewModel.askAIItemID)
        #expect(askItem.value == question)

        await vm.performLauncherResult(row)
        journal.waitForPendingWrites()
        let accepted = try #require(
            journal.recentEvents().first { $0.kind == .selectionAccepted }
        )
        #expect(accepted.itemID == "askAI:ask")
        #expect(accepted.itemID?.contains("France") == false)
        // The corrected claim: the typed question *does* reach the digest path,
        // because accepting the Ask AI row is a launcher selection.
        #expect(accepted.queryFingerprint?.hasPrefix("v2:") == true)
        #expect(accepted.queryFingerprint?.contains("France") == false)
        #expect(accepted.queryLengthBucket != nil)
        // And the text itself never lands on disk.
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(!onDisk.contains("France"))
        #expect(!onDisk.contains("capital"))
        #expect(!onDisk.contains(question))
    }

    @Test func aTypedURLWithATokenIsNeverJournalledVerbatim() async throws {
        let (folder, file, key) = temporaryFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = InteractionJournalStore(fileURL: file, keyURL: key)
        let (vm, _) = makeViewModel(journal: journal)
        let token = "supersecrettoken9f3a1c"
        vm.input = "https://example.com/reset?token=\(token)"

        let row = try #require(vm.launcherMatches.first { result in
            guard case .item(let item) = result else { return false }
            return item.itemID.hasPrefix("typed:")
        })
        guard case .item(let typedItem) = row else {
            Issue.record("expected a typed URL row")
            return
        }
        // The row still works and still identifies itself as typed...
        #expect(typedItem.value.contains(token))
        #expect(typedItem.title.contains("example.com"))
        // ...but its identity is a digest, not the address.
        #expect(!typedItem.itemID.contains(token))
        #expect(!typedItem.itemID.contains("https://"))

        await vm.performLauncherResult(row)
        journal.waitForPendingWrites()
        let events = journal.recentEvents()
        #expect(events.filter { $0.kind == .selectionAccepted }.count == 1)
        // The row keeps its identity for ranking, but the journal re-keys it.
        #expect(events.first?.itemID?.hasPrefix("redacted:v2:") == true)
        #expect(events.first?.itemID?.contains("typed") == false)
        #expect(events.first?.itemID?.contains(token) == false)
        #expect(events.first?.itemID?.contains("https://") == false)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(!onDisk.contains(token))
        #expect(!onDisk.contains("example.com"))
        let export = InteractionJournalExporter.markdown(events)
        #expect(!export.contains(token))
        #expect(!export.contains("example.com"))
        // Ranking also only sees the digest identifier.
        #expect(vm.launcherUsage.topItemIDs(limit: 5)
            .allSatisfy { !$0.contains(token) })
    }

    @Test func aRepeatedTypedURLStillCorrelatesInRanking() async {
        let (vm, _) = makeViewModel()
        let address = "https://example.com/very/specific/page?token=abc"
        vm.input = address
        let first = vm.launcherMatches.first { result in
            guard case .item(let item) = result else { return false }
            return item.itemID.hasPrefix("typed:")
        }
        let firstID = first.flatMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.id
        }
        #expect(firstID?.hasPrefix("quickLink:typed:") == true)
        await vm.performLauncherResult(first!)

        vm.input = address
        let second = vm.launcherMatches.first { result in
            guard case .item(let item) = result else { return false }
            return item.itemID.hasPrefix("typed:")
        }
        guard case .item(let again) = second else {
            Issue.record("expected the typed URL row again")
            return
        }
        #expect(again.id == firstID, "the same address keeps the same digest id")
        #expect(vm.launcherUsage.frecency(itemID: again.id) > 0.99)
    }

    @Test func disabledJournalRecordsNothingButRankingStillLearns() async {
        var settings = QuickSettings()
        settings.interactionJournalEnabled = false
        let journal = InteractionJournalStore(fileURL: nil)
        let (vm, _) = makeViewModel(settings: settings, journal: journal)

        vm.input = "cla"
        await vm.performLauncherResult(vm.launcherMatches[0])
        vm.learnDirectUse(of: Self.clashX)
        vm.input = "flurble"
        vm.endInteractionSession()

        #expect(journal.isEmpty)
        // The journal toggle is independent of the ranking toggle.
        #expect(!vm.launcherUsage.isEmpty)
    }

    @Test func journalledAbandonmentsNeverChangeRanking() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = InteractionJournalStore(fileURL: nil, now: { clock })
        let (vm, _) = makeViewModel(journal: journal)
        vm.input = "cla"
        let index = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.performLauncherResult(vm.launcherMatches[index])

        vm.input = "cla"
        let before = vm.launcherMatches
        #expect(before.first == .application(Self.claude))

        // Twenty abandoned searches for the same abbreviation, all marked as
        // wrong choices, must not move a ranking that only positive signals feed.
        for _ in 0..<20 {
            clock = clock.addingTimeInterval(60)
            vm.input = "cla"
            vm.endInteractionSession()
        }
        for event in journal.recentEvents() {
            vm.setInteractionMarkedAccidental(id: event.id, accidental: true)
        }

        vm.input = "cla"
        #expect(vm.launcherMatches == before)
        let abandoned = journal.count(of: .searchAbandoned) + journal.count(of: .searchRetried)
        #expect(abandoned >= 18)
        #expect(journal.markedAccidentalCount == journal.count)
    }

    @Test func clearingAndApplyingSettingsWorkThroughTheViewModel() {
        let (vm, journal) = makeViewModel()
        _ = journal.record(kind: .selectionAccepted, itemID: "application:claude")
        #expect(vm.interactionJournalEvents.count == 1)

        vm.updateSettings {
            $0.interactionJournalRetentionDays = 7
            $0.interactionJournalEventCap = 500
        }
        vm.applyInteractionJournalSettings()
        #expect(journal.retentionDays == 7)
        #expect(journal.eventCap == 500)

        let revision = vm.interactionJournalRevision
        vm.clearInteractionJournal()
        #expect(vm.interactionJournalEvents.isEmpty)
        #expect(vm.interactionJournalRevision > revision)
    }

    // MARK: - Export

    @Test func exportRendersEveryGroupAndWritesOwnerOnly() throws {
        let store = InteractionJournalStore(fileURL: nil)
        store.record(kind: .selectionAccepted, itemID: "application:claude", query: "cla")
        store.record(kind: .searchAbandoned, query: "flurble")
        store.record(kind: .aiFailed, detail: "provider-error")
        store.setMarkedAccidental(true, id: store.recentEvents().first!.id)
        let events = store.recentEvents()

        let jsonLines = InteractionJournalExporter.jsonLines(events)
        #expect(jsonLines.split(separator: "\n").count == 3)
        for line in jsonLines.split(separator: "\n") {
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            #expect(object["kind"] != nil)
        }
        #expect(!jsonLines.contains("flurble"))

        let markdown = InteractionJournalExporter.markdown(events)
        #expect(markdown.contains("# Quick Launch interaction journal"))
        #expect(markdown.contains("Choices (1)"))
        #expect(markdown.contains("Abandoned searches (1)"))
        #expect(markdown.contains("AI failures (1)"))
        #expect(markdown.contains("Marked accidental (1)"))
        #expect(!markdown.contains("flurble"))
        #expect(markdown.contains(try #require(store.fingerprint(ofQuery: "flurble"))))

        let (folder, file, key) = temporaryFile("export.md")
        defer { try? FileManager.default.removeItem(at: folder) }
        try InteractionJournalExporter.write(markdown, to: file)
        let permissions = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == markdown)

        #expect(
            InteractionJournalExporter.suggestedFileName(for: .jsonLines, now: Date())
                .hasSuffix(".jsonl")
        )
        #expect(InteractionJournalExporter.markdown([]).contains("No events recorded"))
    }

    // MARK: - Settings migration and binding

    @Test func settingsDefaultTheJournalOnAndDecodeLegacyBlobs() throws {
        let defaults = QuickSettings()
        #expect(defaults.interactionJournalEnabled)
        #expect(defaults.interactionJournalRetentionDays == 30)
        #expect(defaults.interactionJournalEventCap == 2000)

        // A blob written before the journal existed loads with the defaults.
        let legacy = Data(#"{"configurationVersion":21,"launcherLearningEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(QuickSettings.self, from: legacy)
        #expect(decoded.interactionJournalEnabled)
        #expect(decoded.interactionJournalRetentionDays == 30)
        #expect(decoded.interactionJournalEventCap == 2000)

        // Out-of-range values are clamped rather than trusted.
        let wild = Data(#"{"configurationVersion":21,"interactionJournalRetentionDays":9000,"interactionJournalEventCap":-3}"#.utf8)
        let clamped = try JSONDecoder().decode(QuickSettings.self, from: wild)
        #expect(clamped.interactionJournalRetentionDays == InteractionJournalStore.maximumRetentionDays)
        #expect(clamped.interactionJournalEventCap == InteractionJournalStore.minimumEventCap)

        // Explicit choices round-trip.
        var settings = QuickSettings()
        settings.interactionJournalEnabled = false
        settings.interactionJournalRetentionDays = 7
        settings.interactionJournalEventCap = 500
        let roundTripped = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(!roundTripped.interactionJournalEnabled)
        #expect(roundTripped.interactionJournalRetentionDays == 7)
        #expect(roundTripped.interactionJournalEventCap == 500)
    }

    @Test func settingsBindingPersistsAndAppliesTheJournalControls() {
        let (vm, journal) = makeViewModel()
        let binding = vm.settingsBinding(\.interactionJournalRetentionDays) { _ in
            vm.applyInteractionJournalSettings()
        }
        #expect(binding.wrappedValue == 30)
        binding.wrappedValue = 90
        #expect(vm.settings.interactionJournalRetentionDays == 90)
        #expect(journal.retentionDays == 90)

        let enabled = vm.settingsBinding(\.interactionJournalEnabled) { _ in
            vm.applyInteractionJournalSettings()
        }
        enabled.wrappedValue = false
        #expect(vm.settings.interactionJournalEnabled == false)
        vm.input = "flurble"
        vm.endInteractionSession()
        #expect(journal.isEmpty)
    }

    // MARK: - Ranking regression (unchanged Quicksilver behaviour)

    @Test func positiveRankingStillWorksExactlyAsBefore() async {
        let store = LauncherUsageStore(fileURL: nil)
        let vm = QuickViewModel(
            applicationCatalog: JournalFakeApplicationCatalog(
                applications: [Self.claude, Self.calendar, Self.clashX]
            ),
            launcherUsage: store,
            interactionJournal: InteractionJournalStore(fileURL: nil)
        )
        vm.input = "cla"
        let index = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.performLauncherResult(vm.launcherMatches[index])

        vm.input = "cla"
        #expect(vm.launcherMatches.first == .application(Self.claude))
        vm.input = "c"
        #expect(vm.launcherMatches.first == .application(Self.claude))
        // An exact name still wins over a learned abbreviation.
        vm.input = "calendar"
        #expect(vm.launcherMatches.first == .application(Self.calendar))
        #expect(vm.launcherUsage.mnemonicWeight(
            query: "cla",
            scope: "root",
            itemID: "application:com.anthropic.claudefordesktop"
        ) > 0.99)
    }

    @Test func forgettingRankingLeavesTheJournalIntact() async {
        let (vm, journal) = makeViewModel()
        vm.input = "cla"
        await vm.performLauncherResult(vm.launcherMatches[0])
        vm.forgetLearnedRanking()
        #expect(vm.launcherUsage.isEmpty)
        #expect(journal.count(of: .selectionAccepted) == 1)

        vm.clearInteractionJournal()
        #expect(journal.isEmpty)
    }
}

private final class JournalFakeApplicationCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]
    var launched: LaunchableApplication?

    init(applications: [LaunchableApplication]) {
        self.applications = applications
    }

    func launch(_ application: LaunchableApplication) -> Bool {
        launched = application
        return true
    }
}

/// Waits for the stream to start instead of sleeping a fixed time, and says
/// so when it never does.
@MainActor
private func waitForStreaming(_ vm: QuickViewModel, timeout: Duration = .seconds(15)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if vm.isStreaming { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if vm.isStreaming { return true }
    Issue.record("the stream never started")
    return false
}
