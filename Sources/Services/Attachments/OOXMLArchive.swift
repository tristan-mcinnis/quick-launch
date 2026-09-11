import Compression
import Foundation

/// Why a ZIP archive (docx, pptx, xlsx, odt) could not be read.
enum OOXMLArchiveError: Error, Equatable, Sendable {
    /// The bytes do not start like a ZIP archive at all.
    case notZip
    /// A ZIP archive whose structure is cut or broken (no end record, an
    /// entry past the end of the file, a deflate stream that does not end).
    case damaged
    /// More entries than `AttachmentLimits.zipEntries`, checked before any
    /// entry is inflated.
    case tooManyEntries(Int)
    /// An entry, or the archive, would inflate past its cap.
    case tooBig(entry: String)
    /// An entry carries the encryption flag.
    case encrypted
    /// A compression method other than stored (0) or deflate (8).
    case unsupportedMethod(UInt16)
}

/// A small, read-only ZIP reader for the Office formats, on Apple's
/// `Compression` framework (raw DEFLATE).
///
/// Built for hostile input:
/// - the entry count is checked before any entry is inflated;
/// - inflation stops at the per-entry and per-archive caps whatever the
///   header says, and an entry whose declared ratio is absurd is refused
///   before it is touched;
/// - entries are looked up by name in memory and never joined to a path, so
///   a name such as `../../x` is only a name (no zip-slip);
/// - nothing is written to disk.
///
/// Not `Sendable`: one reader belongs to one extraction, which counts the
/// bytes it inflated against the archive cap.
final class OOXMLArchive {
    struct Entry: Equatable, Sendable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isEncrypted: Bool { flags & 0x0001 != 0 }
    }

    /// Entries in archive order.
    let entries: [Entry]
    /// Output inflated so far, counted against `archiveOutputCap`.
    private(set) var inflatedBytes = 0

    private let data: Data
    private let byLowercasedName: [String: Int]
    private let entryOutputCap: Int
    private let archiveOutputCap: Int

    /// Signature of a local file header, "PK\u{3}\u{4}".
    static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endRecordSignature: UInt32 = 0x0605_4B50
    private static let zip64EndRecordSignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let endRecordSize = 22
    private static let maximumCommentLength = 0xFFFF
    private static let inflateChunk = 64 * 1_024

    /// True when `data` starts with a ZIP local header (or is an empty ZIP).
    static func looksLikeZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let reader = ByteReader(data)
        let signature = reader.u32(0) ?? 0
        return signature == localHeaderSignature || signature == endRecordSignature
    }

    /// Reads the central directory. Throws `notZip` for bytes that are not
    /// a ZIP, `damaged` for a cut or broken one, `tooManyEntries` over the
    /// entry cap.
    init(
        data: Data,
        maximumEntries: Int = AttachmentLimits.zipEntries,
        entryOutputCap: Int = AttachmentLimits.zipEntryOutputBytes,
        archiveOutputCap: Int = AttachmentLimits.zipArchiveOutputBytes
    ) throws {
        guard Self.looksLikeZip(data) else { throw OOXMLArchiveError.notZip }
        let reader = ByteReader(data)
        let directory = try Self.centralDirectory(reader)
        guard directory.count <= maximumEntries else { throw OOXMLArchiveError.tooManyEntries(directory.count) }

        var entries: [Entry] = []
        entries.reserveCapacity(directory.count)
        var cursor = directory.offset
        for _ in 0..<directory.count {
            guard reader.u32(cursor) == Self.centralHeaderSignature,
                  let flags = reader.u16(cursor + 8),
                  let method = reader.u16(cursor + 10),
                  let compressed32 = reader.u32(cursor + 20),
                  let uncompressed32 = reader.u32(cursor + 24),
                  let nameLength = reader.u16(cursor + 28),
                  let extraLength = reader.u16(cursor + 30),
                  let commentLength = reader.u16(cursor + 32),
                  let offset32 = reader.u32(cursor + 42),
                  let nameBytes = reader.bytes(cursor + 46, count: Int(nameLength))
            else { throw OOXMLArchiveError.damaged }

            var compressedSize = Int(compressed32)
            var uncompressedSize = Int(uncompressed32)
            var localOffset = Int(offset32)
            let extraStart = cursor + 46 + Int(nameLength)
            if compressed32 == .max || uncompressed32 == .max || offset32 == .max {
                // ZIP64: the real values sit in extra field 0x0001, in this
                // order, each present only when its 32-bit field is all ones.
                guard let extra = Self.zip64Extra(reader, start: extraStart, length: Int(extraLength))
                else { throw OOXMLArchiveError.damaged }
                var at = extra
                if uncompressed32 == .max {
                    guard let value = reader.u64(at) else { throw OOXMLArchiveError.damaged }
                    uncompressedSize = Int(clamping: value)
                    at += 8
                }
                if compressed32 == .max {
                    guard let value = reader.u64(at) else { throw OOXMLArchiveError.damaged }
                    compressedSize = Int(clamping: value)
                    at += 8
                }
                if offset32 == .max {
                    guard let value = reader.u64(at) else { throw OOXMLArchiveError.damaged }
                    localOffset = Int(clamping: value)
                }
            }

            entries.append(Entry(
                name: String(decoding: nameBytes, as: UTF8.self),
                method: method,
                flags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            cursor = extraStart + Int(extraLength) + Int(commentLength)
        }

        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            let key = entry.name.lowercased()
            if index[key] == nil { index[key] = position }
        }
        self.data = data
        self.entries = entries
        self.byLowercasedName = index
        self.entryOutputCap = entryOutputCap
        self.archiveOutputCap = archiveOutputCap
    }

    /// Entry names, in archive order.
    var names: [String] { entries.map(\.name) }

    /// The entry with this name. Office part names are case-insensitive.
    func entry(named name: String) -> Entry? {
        byLowercasedName[name.lowercased()].map { entries[$0] }
    }

    func contains(_ name: String) -> Bool { entry(named: name) != nil }

    /// The inflated bytes of one entry, or nil when there is no such entry.
    /// Stops at the caps while inflating; never trusts the header's size.
    func data(for name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try read(entry)
    }

    func read(_ entry: Entry) throws -> Data {
        try read(entry, keepHead: false).data
    }

    /// Like `read(_:)`, but an entry that passes its cap gives its head up
    /// to the cap instead of failing, and says it was cut. Only for parts
    /// whose head is useful on its own (a worksheet's first rows). The
    /// declared-ratio refusal still holds, and the head never passes the cap.
    func readHead(_ entry: Entry) throws -> (data: Data, isCut: Bool) {
        try read(entry, keepHead: true)
    }

    private func read(_ entry: Entry, keepHead keepHeadAtCap: Bool) throws -> (data: Data, isCut: Bool) {
        if entry.isEncrypted { throw OOXMLArchiveError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw OOXMLArchiveError.unsupportedMethod(entry.method) }

        // Cheap early refusals from the header. They only ever refuse:
        // the caps below still hold when the header lies.
        if !keepHeadAtCap, entry.uncompressedSize > entryOutputCap {
            throw OOXMLArchiveError.tooBig(entry: entry.name)
        }
        if entry.method == 8,
           entry.uncompressedSize > AttachmentLimits.zipRatioFloorBytes,
           entry.uncompressedSize / max(entry.compressedSize, 1) > AttachmentLimits.zipDeclaredRatio {
            throw OOXMLArchiveError.tooBig(entry: entry.name)
        }

        let reader = ByteReader(data)
        let local = entry.localHeaderOffset
        guard reader.u32(local) == Self.localHeaderSignature,
              let nameLength = reader.u16(local + 26),
              let extraLength = reader.u16(local + 28)
        else { throw OOXMLArchiveError.damaged }
        let start = local + 30 + Int(nameLength) + Int(extraLength)
        guard let body = reader.slice(start, count: entry.compressedSize) else { throw OOXMLArchiveError.damaged }

        let remaining = max(0, archiveOutputCap - inflatedBytes)
        let cap = min(entryOutputCap, remaining)
        let output: (data: Data, isCut: Bool)
        if entry.method == 0 {
            if body.count > cap {
                guard keepHeadAtCap else { throw OOXMLArchiveError.tooBig(entry: entry.name) }
                output = (Data(body.prefix(cap)), true)
            } else {
                output = (Data(body), false)
            }
        } else {
            output = try Self.inflate(body, cap: cap, name: entry.name, keepHeadAtCap: keepHeadAtCap)
        }
        inflatedBytes += output.data.count
        return output
    }

    // MARK: - Inflate

    /// Raw DEFLATE (`COMPRESSION_ZLIB` in `Compression` is RFC 1951 with no
    /// zlib header). Output is counted chunk by chunk and the stream stops
    /// the moment it passes `cap`. Checks for cancellation between chunks.
    static func inflate(
        _ body: Data,
        cap: Int,
        name: String,
        keepHeadAtCap: Bool = false
    ) throws -> (data: Data, isCut: Bool) {
        let sink = InflateSink(cap: cap)
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                try sink.append(chunk)
            }
            var index = body.startIndex
            while index < body.endIndex {
                if Task.isCancelled { throw CancellationError() }
                let end = body.index(index, offsetBy: inflateChunk, limitedBy: body.endIndex) ?? body.endIndex
                try filter.write(body[index..<end])
                index = end
            }
            try filter.finalize()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if sink.overflowed {
                guard keepHeadAtCap else { throw OOXMLArchiveError.tooBig(entry: name) }
                return (sink.output, true)
            }
            throw OOXMLArchiveError.damaged
        }
        return (sink.output, false)
    }

    /// Collects inflated chunks; at the cap it keeps the head and stops.
    private final class InflateSink {
        let cap: Int
        var output = Data()
        var overflowed = false

        init(cap: Int) { self.cap = cap }

        func append(_ chunk: Data) throws {
            if output.count + chunk.count > cap {
                output.append(chunk.prefix(cap - output.count))
                overflowed = true
                throw OOXMLArchiveError.tooBig(entry: "")
            }
            output.append(chunk)
        }
    }

    // MARK: - Central directory

    private static func centralDirectory(_ reader: ByteReader) throws -> (count: Int, offset: Int) {
        guard reader.count >= endRecordSize else { throw OOXMLArchiveError.damaged }
        let lowest = max(0, reader.count - endRecordSize - maximumCommentLength)
        var position = reader.count - endRecordSize
        var end: Int?
        while position >= lowest {
            if reader.u32(position) == endRecordSignature {
                end = position
                break
            }
            position -= 1
        }
        guard let end,
              let count16 = reader.u16(end + 10),
              let offset32 = reader.u32(end + 16)
        else { throw OOXMLArchiveError.damaged }

        var count = Int(count16)
        var offset = Int(offset32)
        if count16 == .max || offset32 == .max {
            // ZIP64 end record, found through its locator just before.
            let locator = end - 20
            guard locator >= 0,
                  reader.u32(locator) == zip64LocatorSignature,
                  let recordOffset = reader.u64(locator + 8)
            else { throw OOXMLArchiveError.damaged }
            let record = Int(clamping: recordOffset)
            guard reader.u32(record) == zip64EndRecordSignature,
                  let count64 = reader.u64(record + 32),
                  let offset64 = reader.u64(record + 48)
            else { throw OOXMLArchiveError.damaged }
            count = Int(clamping: count64)
            offset = Int(clamping: offset64)
        }
        guard offset >= 0, offset <= reader.count else { throw OOXMLArchiveError.damaged }
        return (count, offset)
    }

    /// Start of the ZIP64 extra field's values, or nil when absent.
    private static func zip64Extra(_ reader: ByteReader, start: Int, length: Int) -> Int? {
        var at = start
        let end = start + length
        while at + 4 <= end {
            guard let id = reader.u16(at), let size = reader.u16(at + 2) else { return nil }
            if id == 0x0001 { return at + 4 }
            at += 4 + Int(size)
        }
        return nil
    }
}

/// Bounds-checked little-endian reads over `Data`, whatever its start
/// index. Every read past the end returns nil instead of trapping.
struct ByteReader {
    let data: Data
    let base: Int
    let count: Int

    init(_ data: Data) {
        self.data = data
        self.base = data.startIndex
        self.count = data.count
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(data[base + offset]) | UInt16(data[base + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    func bytes(_ offset: Int, count length: Int) -> Data? {
        slice(offset, count: length).map { Data($0) }
    }

    func slice(_ offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return data[(base + offset)..<(base + offset + length)]
    }
}
