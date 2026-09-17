import Foundation
import Testing
@testable import HouseChatCore

@Suite("Attachment archive")
struct AttachmentArchiveTests {
    @Test("Every artifact kind stores and reads back, with owner-only modes")
    func storesEveryKind() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let payloads: [(ArtifactRef.Kind, Data, String?)] = [
            (.original, Data("%PDF-1.7 original bytes".utf8), "pdf"),
            (.normalizedImage, Data([0x89, 0x50, 0x4E, 0x47]), nil),
            (.extractedText, Data(Fixtures.english.utf8), nil),
            (.requestSnapshot, Data(#"{"messages":[]}"#.utf8), "json"),
        ]

        for (kind, data, ext) in payloads {
            let ref = try await archive.store(data, kind: kind, fileExtension: ext)
            #expect(ref.kind == kind)
            #expect(ref.byteCount == data.count)
            #expect(ref.sha256 == SHA256Digest.hex(data))
            #expect(ref.fileExtension == ext)
            #expect(try await archive.read(ref) == data)
            #expect(await archive.contains(ref))
            #expect(try await archive.verify(ref) == .verified)
        }

        #expect(AtomicFile.permissions(of: root) == 0o700)
        let refs = try await archive.list()
        #expect(refs.count == 4)
        for ref in refs {
            let url = AttachmentArchive.fileURL(root: root, kind: ref.kind, sha256: ref.sha256)
            #expect(AtomicFile.permissions(of: url) == 0o600)
        }
    }

    @Test("Content addressing makes a second store a no-op")
    func idempotentStore() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let data = Data("the same bytes".utf8)
        let first = try await archive.store(data, kind: .original)
        let second = try await archive.store(data, kind: .original)
        #expect(first == second)

        let directory = root.appendingPathComponent("original/\(first.sha256.prefix(2))", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }

    @Test("Verify detects bytes that drifted from the stored hash, and a rewrite repairs them")
    func detectsTampering() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let data = Data("trustworthy".utf8)
        let ref = try await archive.store(data, kind: .original, fileExtension: "txt")
        let url = AttachmentArchive.fileURL(root: root, kind: .original, sha256: ref.sha256)

        try Data("tampered".utf8).write(to: url)
        let verification = try await archive.verify(ref)
        guard case .mismatched(let actual) = verification else {
            Issue.record("Expected a mismatch, got \(verification)")
            return
        }
        #expect(actual == SHA256Digest.hex(Data("tampered".utf8)))

        _ = try await archive.store(data, kind: .original)
        #expect(try await archive.verify(ref) == .verified)
    }

    @Test("A forged digest cannot escape the root")
    func forgedDigest() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let archive = try AttachmentArchive(root: temp.appending("archive"))
        let forged = ArtifactRef(kind: .original, sha256: "../../../../etc/passwd", byteCount: 1)

        await #expect(throws: AttachmentArchiveError.invalidDigest("../../../../etc/passwd")) {
            try await archive.read(forged)
        }
        #expect(await archive.contains(forged) == false)
    }

    @Test("A symlink planted at an artifact path is refused, not followed")
    func refusesSymlink() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let ref = try await archive.store(Data("real".utf8), kind: .extractedText)
        let url = AttachmentArchive.fileURL(root: root, kind: .extractedText, sha256: ref.sha256)

        let outside = temp.appending("outside-secret")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)

        #expect(await archive.contains(ref) == false)
        await #expect(throws: AttachmentArchiveError.missing(kind: .extractedText, sha256: ref.sha256)) {
            try await archive.read(ref)
        }
        #expect(try await archive.verify(ref) == .missing)
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
    }

    @Test("Nothing is evicted: many artifacts stay until removed explicitly")
    func noEviction() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let archive = try AttachmentArchive(root: temp.appending("archive"))

        var refs: [ArtifactRef] = []
        for index in 0..<25 {
            refs.append(try await archive.store(Data("artifact \(index)".utf8), kind: .extractedText))
        }
        #expect(try await archive.list().count == 25)

        let keep = Set(refs.prefix(5).map(\.sha256))
        let removed = try await archive.removeUnreferenced(keepingHashes: keep)
        #expect(removed.count == 20)
        #expect(try await archive.list().count == 5)
        for ref in refs.prefix(5) {
            #expect(await archive.contains(ref))
        }
    }

    @Test("Removing one artifact is explicit, and removing a missing one is an error")
    func explicitRemove() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let archive = try AttachmentArchive(root: temp.appending("archive"))

        let ref = try await archive.store(Data("one".utf8), kind: .requestSnapshot)
        try await archive.remove(ref)
        #expect(await archive.contains(ref) == false)
        await #expect(throws: AttachmentArchiveError.missing(kind: .requestSnapshot, sha256: ref.sha256)) {
            try await archive.remove(ref)
        }
    }

    @Test("Reading distinguishes a missing artifact from a damaged one")
    func readDistinguishesCorruptFromMissing() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let neverStored = ArtifactRef(kind: .original, sha256: SHA256Digest.hex(Data("never".utf8)), byteCount: 5)
        await #expect(throws: AttachmentArchiveError.missing(kind: .original, sha256: neverStored.sha256)) {
            try await archive.read(neverStored)
        }

        let data = Data("the original bytes".utf8)
        let ref = try await archive.store(data, kind: .original)
        let url = AttachmentArchive.fileURL(root: root, kind: .original, sha256: ref.sha256)

        // Tampered bytes are refused, never returned as the artifact.
        try Data("other bytes entirely".utf8).write(to: url)
        do {
            _ = try await archive.read(ref)
            Issue.record("Expected a corrupt-artifact error")
        } catch let error as AttachmentArchiveError {
            guard case .corrupt(let kind, let sha, _) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(kind == .original)
            #expect(sha == ref.sha256)
        }

        // A ref whose recorded size is wrong is refused too.
        _ = try await archive.store(data, kind: .original)
        let wrongSize = ArtifactRef(kind: .original, sha256: ref.sha256, byteCount: data.count + 1)
        await #expect(throws: AttachmentArchiveError.self) {
            try await archive.read(wrongSize)
        }
    }

    @Test("A symlinked prefix directory is refused, not followed")
    func refusesSymlinkedPrefixDirectory() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let root = temp.appending("archive")
        let archive = try AttachmentArchive(root: root)

        let data = Data("protected".utf8)
        let ref = try await archive.store(data, kind: .extractedText)
        let file = AttachmentArchive.fileURL(root: root, kind: .extractedText, sha256: ref.sha256)
        let prefixDirectory = file.deletingLastPathComponent()

        // Replace the prefix directory with a symlink to an outside directory
        // that holds a file with the digest name.
        let outside = temp.appending("outside-prefix")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("planted".utf8).write(to: outside.appendingPathComponent(ref.sha256))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: prefixDirectory)
        try FileManager.default.createSymbolicLink(at: prefixDirectory, withDestinationURL: outside)

        await #expect(throws: AttachmentArchiveError.unsafePath(prefixDirectory.path)) {
            try await archive.read(ref)
        }
        #expect(await archive.contains(ref) == false)
        #expect(try await archive.verify(ref) == .missing)
        // The planted file is untouched.
        #expect(try Data(contentsOf: outside.appendingPathComponent(ref.sha256)) == Data("planted".utf8))
    }

    @Test("A symlinked root is refused for a write")
    func refusesSymlinkedRoot() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let real = temp.appending("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = temp.appending("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let archive = try AttachmentArchive(root: link)
        await #expect(throws: AttachmentArchiveError.unsafePath(link.path)) {
            try await archive.store(Data("x".utf8), kind: .original)
        }
    }

    @Test("An unusable file extension is refused")
    func rejectsUnsafeExtension() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let archive = try AttachmentArchive(root: temp.appending("archive"))

        for ext in ["../pdf", "a/b", "", String(repeating: "x", count: 20)] {
            await #expect(throws: AttachmentArchiveError.invalidExtension(ext)) {
                try await archive.store(Data("x".utf8), kind: .original, fileExtension: ext)
            }
        }
    }

    @Test("Listing can be narrowed to one kind")
    func listByKind() async throws {
        let temp = try TempDirectory(prefix: "attachments")
        let archive = try AttachmentArchive(root: temp.appending("archive"))

        _ = try await archive.store(Data("text".utf8), kind: .extractedText)
        _ = try await archive.store(Data("image".utf8), kind: .normalizedImage)
        #expect(try await archive.list(kind: .extractedText).count == 1)
        #expect(try await archive.list(kind: .original).isEmpty)
    }
}
