import Foundation
import Testing
@testable import QuickLaunch

/// The in-house ZIP reader under the Office extractors: it reads real
/// entries, and every hostile archive stops at a cap, never at a crash.
@Suite("OOXML archive")
struct OOXMLArchiveTests {
    @Test("Reads stored and deflated entries, by any case of the name")
    func readsStoredAndDeflated() throws {
        var zip = TestZipWriter()
        zip.add("stored.txt", "plain bytes", method: .stored)
        zip.add("word/document.xml", String(repeating: "deflate me ", count: 500), method: .deflated)
        let archive = try OOXMLArchive(data: zip.data())

        #expect(archive.names == ["stored.txt", "word/document.xml"])
        #expect(try archive.data(for: "stored.txt") == Data("plain bytes".utf8))
        let inflated = try #require(try archive.data(for: "WORD/Document.xml"))
        #expect(String(decoding: inflated, as: UTF8.self) == String(repeating: "deflate me ", count: 500))
        #expect(try archive.data(for: "missing.xml") == nil)
    }

    @Test("A slice of a larger buffer reads the same")
    func readsFromSlice() throws {
        var zip = TestZipWriter()
        zip.add("a.xml", "<a/>")
        let padded = Data(repeating: 0, count: 17) + zip.data()
        let archive = try OOXMLArchive(data: padded.dropFirst(17))
        #expect(try archive.data(for: "a.xml") == Data("<a/>".utf8))
    }

    @Test("More entries than the cap are refused before any inflation")
    func entryCountCap() throws {
        var zip = TestZipWriter()
        for index in 0...AttachmentLimits.zipEntries {
            zip.add("e\(index)", Data([1]), method: .stored)
        }
        #expect(throws: OOXMLArchiveError.tooManyEntries(AttachmentLimits.zipEntries + 1)) {
            try OOXMLArchive(data: zip.data())
        }
    }

    @Test("An honest bomb is refused from its header")
    func honestBombRefused() throws {
        let archive = try OOXMLArchive(data: AttachmentFixtures.bombPPTX)
        #expect(throws: OOXMLArchiveError.tooBig(entry: "ppt/slides/slide1.xml")) {
            try archive.data(for: "ppt/slides/slide1.xml")
        }
        #expect(archive.inflatedBytes == 0)
    }

    @Test("A bomb with a lying header stops at the per-entry cap in under 50 ms")
    func lyingBombStopsAtCap() throws {
        // Best of three, so a busy test run does not decide the timing.
        var best = Duration.seconds(10)
        for _ in 0..<3 {
            let archive = try OOXMLArchive(data: AttachmentFixtures.lyingBombPPTX)
            let clock = ContinuousClock()
            let start = clock.now
            #expect(throws: OOXMLArchiveError.tooBig(entry: "ppt/slides/slide1.xml")) {
                try archive.data(for: "ppt/slides/slide1.xml")
            }
            best = min(best, start.duration(to: clock.now))
        }
        #expect(best < .milliseconds(50), "bomb took \(best)")
    }

    @Test("The archive cap binds across entries")
    func archiveCap() throws {
        var zip = TestZipWriter()
        zip.add("one", Data(repeating: 7, count: 600), method: .stored)
        zip.add("two", Data(repeating: 7, count: 600), method: .deflated)
        let archive = try OOXMLArchive(data: zip.data(), entryOutputCap: 1_000, archiveOutputCap: 1_000)
        _ = try archive.data(for: "one")
        #expect(throws: OOXMLArchiveError.tooBig(entry: "two")) {
            try archive.data(for: "two")
        }
    }

    @Test("A head read keeps the bytes up to the cap")
    func headRead() throws {
        var zip = TestZipWriter()
        zip.add("sheet.xml", Data(repeating: 65, count: 5_000), method: .deflated)
        let archive = try OOXMLArchive(data: zip.data(), entryOutputCap: 1_000)
        let entry = try #require(archive.entry(named: "sheet.xml"))
        let head = try archive.readHead(entry)
        #expect(head.data == Data(repeating: 65, count: 1_000))
        #expect(head.isCut)
        let small = try OOXMLArchive(data: zip.data())
        let whole = try small.readHead(try #require(small.entry(named: "sheet.xml")))
        #expect(whole.data.count == 5_000)
        #expect(!whole.isCut)
    }

    @Test("A truncated archive is damaged, and bytes that are not a ZIP say so")
    func truncatedArchive() throws {
        var zip = TestZipWriter()
        zip.add("word/document.xml", String(repeating: "text ", count: 2_000))
        let whole = zip.data()
        #expect(throws: OOXMLArchiveError.damaged) {
            try OOXMLArchive(data: whole.prefix(whole.count / 2))
        }
        #expect(throws: OOXMLArchiveError.notZip) {
            try OOXMLArchive(data: Data("this is plain text, not a zip".utf8))
        }
        #expect(throws: OOXMLArchiveError.notZip) {
            try OOXMLArchive(data: Data())
        }
    }

    @Test("A broken deflate stream is damaged, not a crash")
    func corruptDeflate() throws {
        var zip = TestZipWriter()
        zip.add("a.xml", String(repeating: "abcdefgh", count: 4_000))
        var bytes = zip.data()
        // The body starts after the 30-byte local header and the 5-byte
        // name. 0xFF there opens a block of the reserved type 3.
        bytes[35] = 0xFF
        let archive = try OOXMLArchive(data: bytes)
        #expect(throws: OOXMLArchiveError.damaged) {
            try archive.data(for: "a.xml")
        }
    }

    @Test("An entry with the encryption flag is refused")
    func encryptedEntry() throws {
        var zip = TestZipWriter()
        zip.add("word/document.xml", Data("<w:document/>".utf8), encrypted: true)
        let archive = try OOXMLArchive(data: zip.data())
        #expect(throws: OOXMLArchiveError.encrypted) {
            try archive.data(for: "word/document.xml")
        }
    }

    @Test("A name with ../ is only a name: read by it, never joined to a path")
    func zipSlipNames() throws {
        var zip = TestZipWriter()
        zip.add("../../evil.xml", "<x/>")
        zip.add("/abs/path.xml", "<y/>", method: .stored)
        let archive = try OOXMLArchive(data: zip.data())
        #expect(archive.names == ["../../evil.xml", "/abs/path.xml"])
        #expect(try archive.data(for: "../../evil.xml") == Data("<x/>".utf8))
        #expect(try archive.data(for: "evil.xml") == nil)
        #expect(try archive.data(for: "/abs/path.xml") == Data("<y/>".utf8))
    }

    @Test("An unknown compression method is refused")
    func unknownMethod() throws {
        var zip = TestZipWriter()
        zip.add("a.xml", "<a/>", method: .stored)
        var bytes = zip.data()
        // Local header method at offset 8, central record method at its +10.
        bytes[8] = 14
        let central = try #require(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        bytes[central + 10] = 14
        let archive = try OOXMLArchive(data: bytes)
        #expect(throws: OOXMLArchiveError.unsupportedMethod(14)) {
            try archive.data(for: "a.xml")
        }
    }
}
