import Foundation
import Synchronization
import Testing
@testable import QuickLaunch

/// A clock the test moves by hand.
private final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }
    var reader: @Sendable () -> Date { { [self] in now } }

    func advance(days: Double) {
        current.withLock { $0 = $0.addingTimeInterval(days * 86_400) }
    }
}

/// The owner-only text cache: modes, backup exclusion, expiry, the byte
/// cap, and deletion. It is built here but wired nowhere yet.
@Suite("Attachment text cache")
struct AttachmentTextCacheTests {
    private let directory = AttachmentFixtures.folder("cache").appending(path: "attachment-cache", directoryHint: .isDirectory)

    private func cache(clock: TestClock = TestClock(), byteLimit: Int = AttachmentLimits.cacheBytes) -> AttachmentTextCache {
        AttachmentTextCache(directory: directory, byteLimit: byteLimit, now: clock.reader)
    }

    private static func hash(_ seed: String) -> String {
        AttachmentExtractor.sha256(Data(seed.utf8))
    }

    private static func extraction(_ text: String, seed: String? = nil, kind: ChatAttachmentKind = .pdf) -> ExtractedAttachment {
        let ref = ChatAttachmentRef(
            kind: kind,
            name: "Q3 report.pdf",
            byteCount: 1_200,
            pageCount: 3,
            characterCount: text.count,
            contentHash: hash(seed ?? text),
            extractorVersion: AttachmentExtractor.version,
            path: "/tmp/Q3 report.pdf"
        )
        return ExtractedAttachment(ref: ref, text: text, image: nil, kindLabel: "PDF", notes: [.ocr(pages: [1], totalPages: 3)])
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("Folder 0700, files 0600, folder out of backups; one file per text")
    func modesAndBackup() async throws {
        let cache = cache()
        let key = try #require(try await cache.store(Self.extraction("Sentinel text for the cache.")))

        #expect(try mode(directory) == 0o700)
        let file = directory.appending(path: key.fileName)
        #expect(try mode(file) == 0o600)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(key.fileName == "\(Self.hash("Sentinel text for the cache."))-v1.json")

        let entry = try #require(await cache.entry(for: key))
        #expect(entry.text == "Sentinel text for the cache.")
        #expect(entry.kindLabel == "PDF")
        #expect(entry.notes == [.ocr(pages: [1], totalPages: 3)])
        #expect(await cache.keys() == [key])
    }

    @Test("The same file attached twice shares one entry")
    func sharedEntry() async throws {
        let cache = cache()
        let first = try await cache.store(Self.extraction("same bytes", seed: "one file"))
        let second = try await cache.store(Self.extraction("same bytes", seed: "one file"))
        #expect(first == second)
        #expect(await cache.keys().count == 1)
    }

    @Test("Images never enter the cache")
    func noImages() async throws {
        let cache = cache()
        let ref = ChatAttachmentRef(kind: .screenshot, name: "Screenshot", contentHash: Self.hash("pixels"), path: "/tmp/x.png")
        let image = ExtractedAttachment(ref: ref, text: "OCR words", image: nil, kindLabel: "Image", notes: [])
        #expect(try await cache.store(image) == nil)
        #expect(await cache.keys().isEmpty)
        #expect(AttachmentCacheKey(ref) == nil)
    }

    @Test("An entry expires 7 days after its last use; a use keeps it")
    func expiry() async throws {
        let clock = TestClock()
        let cache = cache(clock: clock)
        let kept = try #require(try await cache.store(Self.extraction("used every few days")))
        let dropped = try #require(try await cache.store(Self.extraction("attached once")))

        clock.advance(days: 5)
        #expect(await cache.entry(for: kept) != nil) // touched now
        clock.advance(days: 3)
        #expect(await cache.entry(for: kept)?.text == "used every few days")
        #expect(await cache.entry(for: dropped) == nil)
        #expect(await cache.keys() == [kept])

        clock.advance(days: 7.5)
        await cache.collectGarbage()
        #expect(await cache.keys().isEmpty)
    }

    @Test("A peek does not count as a use; a touch within the hour writes nothing")
    func touchRules() async throws {
        let clock = TestClock()
        let cache = cache(clock: clock)
        let key = try #require(try await cache.store(Self.extraction("peek at me")))
        let stored = try #require(await cache.entry(for: key, touch: false)).lastUsed

        clock.advance(days: 1.0 / 48) // 30 minutes
        await cache.touch(key)
        #expect(await cache.entry(for: key, touch: false)?.lastUsed == stored)

        clock.advance(days: 6.9)
        #expect(await cache.contains(key)) // a peek, not a use
        clock.advance(days: 0.2)
        #expect(await cache.contains(key) == false)
    }

    @Test("Over the byte cap, the least recently used go first")
    func lruCap() async throws {
        let clock = TestClock()
        let text = String(repeating: "x", count: 4_000)
        let probe = cache(clock: clock)
        let sizeKey = try #require(try await probe.store(Self.extraction(text, seed: "probe")))
        let entryBytes = await probe.totalBytes()
        await probe.remove(sizeKey)

        let cache = cache(clock: clock, byteLimit: entryBytes * 3 + entryBytes / 2)
        var keys: [AttachmentCacheKey] = []
        for index in 0..<3 {
            keys.append(try #require(try await cache.store(Self.extraction(text, seed: "file \(index)"))))
            clock.advance(days: 0.1)
        }
        clock.advance(days: 0.1)
        _ = await cache.entry(for: keys[0]) // the oldest is used again
        clock.advance(days: 0.1)
        let fourth = try #require(try await cache.store(Self.extraction(text, seed: "file 3")))

        #expect(await cache.keys() == [keys[0], keys[2], fourth])
        #expect(await cache.totalBytes() <= entryBytes * 3 + entryBytes / 2)
    }

    @Test("A chat's delete drops only entries no other chat still uses; clear empties all")
    func deletion() async throws {
        let cache = cache()
        let shared = Self.extraction("in two chats", seed: "shared")
        let lonely = Self.extraction("in one chat", seed: "lonely")
        let sharedKey = try #require(try await cache.store(shared))
        let lonelyKey = try #require(try await cache.store(lonely))

        await cache.remove(references: [shared.ref, lonely.ref], keeping: [shared.ref])
        #expect(await cache.keys() == [sharedKey])
        #expect(await cache.entry(for: lonelyKey) == nil)

        try "stray".write(to: directory.appending(path: "stray.tmp"), atomically: true, encoding: .utf8)
        await cache.clear()
        #expect(await cache.keys().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty)
    }

    @Test("Keys from a history file cannot name a path")
    func hostileKeys() {
        #expect(AttachmentCacheKey(contentHash: "../../etc/passwd", extractorVersion: 1) == nil)
        #expect(AttachmentCacheKey(contentHash: String(repeating: "A", count: 64), extractorVersion: 1) == nil)
        #expect(AttachmentCacheKey(contentHash: Self.hash("x"), extractorVersion: 0) == nil)
        let good = AttachmentCacheKey(contentHash: Self.hash("x"), extractorVersion: 2)
        #expect(good != nil)
        #expect(good.flatMap { AttachmentCacheKey(fileName: $0.fileName) } == good)
        #expect(AttachmentCacheKey(fileName: "notes.json") == nil)
        let ref = ChatAttachmentRef(kind: .pdf, name: "x", contentHash: "../x", extractorVersion: 1, path: "/x")
        #expect(AttachmentCacheKey(ref) == nil)
    }

    @Test("A tampered or foreign file under a key's name is a miss")
    func tamperedFile() async throws {
        let cache = cache()
        let key = try #require(try await cache.store(Self.extraction("real text")))
        try Data("{ not json".utf8).write(to: directory.appending(path: key.fileName))
        #expect(await cache.entry(for: key) == nil)
    }
}
