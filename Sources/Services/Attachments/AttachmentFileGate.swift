import Foundation
import UniformTypeIdentifiers

/// Which extractor reads a file.
enum AttachmentRoute: Equatable, Sendable {
    case pdf
    case docx
    case doc
    case rtf
    /// A `.rtfd` package, or a flat RTFD file.
    case rtfd
    case odt
    case pptx
    case xlsx
    case html
    /// Text, Markdown, or code; the label names the language or format.
    case plainText(ChatAttachmentKind, label: String)
    case image

    var kind: ChatAttachmentKind {
        switch self {
        case .pdf: .pdf
        case .docx, .doc, .rtf, .rtfd, .odt: .word
        case .pptx: .powerpoint
        case .xlsx: .excel
        case .html: .html
        case .plainText(let kind, _): kind
        case .image: .image
        }
    }

    /// The `kind` the model block names.
    var label: String {
        switch self {
        case .pdf: "PDF"
        case .docx, .doc: "Word document"
        case .rtf, .rtfd: "Rich text document"
        case .odt: "OpenDocument text"
        case .pptx: "PowerPoint presentation"
        case .xlsx: "Excel workbook"
        case .html: "HTML file"
        case .plainText(_, let label): label
        case .image: "Image"
        }
    }

    /// Size cap for the source file.
    var byteLimit: Int {
        switch self {
        case .image: AttachmentLimits.imageBytes
        case .plainText, .html: AttachmentLimits.textFileBytes
        default: AttachmentLimits.documentBytes
        }
    }
}

/// Where an iCloud file stands.
enum ICloudFileState: Equatable, Sendable {
    /// Not in iCloud, or already on this Mac in its current version.
    case local
    case needsDownload
}

/// The file gate: resolves what the user attached to one regular file this
/// Mac can read, and decides its route, before any byte is read.
///
/// - Finder aliases and symbolic links are resolved once; the target must be
///   a regular file. Folders, packages (apart from `.rtfd`), sockets, and
///   devices are refused.
/// - The route comes from the file's type and extension; the bytes confirm
///   it later (`confirm`), so a `.docx` that is not a ZIP says so.
/// - The size cap is checked from the file's metadata.
/// - An iCloud file that is not on this Mac is downloaded first, with a
///   bounded wait.
/// - Read errors from macOS privacy protection map to one line that says
///   how to get past it.
struct AttachmentFileGate: Sendable {
    struct Resolved: Equatable, Sendable {
        /// The file after aliases and links, as read.
        let url: URL
        /// The name as the user knows it: the file they picked.
        let name: String
        let route: AttachmentRoute
        let byteCount: Int
    }

    var iCloudWait: Duration
    var iCloudPoll: Duration
    var iCloudState: @Sendable (URL) -> ICloudFileState
    var startDownload: @Sendable (URL) throws -> Void

    init(
        iCloudWait: Duration = AttachmentLimits.extractionTimeout,
        iCloudPoll: Duration = .milliseconds(250),
        iCloudState: @escaping @Sendable (URL) -> ICloudFileState = AttachmentFileGate.systemICloudState,
        startDownload: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    ) {
        self.iCloudWait = iCloudWait
        self.iCloudPoll = iCloudPoll
        self.iCloudState = iCloudState
        self.startDownload = startDownload
    }

    // MARK: Resolve

    func resolve(_ url: URL, progress: AttachmentProgressHandler? = nil) async throws -> Resolved {
        guard url.isFileURL else { throw AttachmentFailure.missing }
        let name = url.lastPathComponent
        let target = try Self.resolveLinks(url)

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey,
        ]
        let values: URLResourceValues
        do {
            values = try target.resourceValues(forKeys: keys)
        } catch {
            throw Self.failure(for: error)
        }

        if values.isDirectory == true {
            let ext = target.pathExtension.lowercased()
            if ext == "rtfd" {
                let route = AttachmentRoute.rtfd
                let size = Self.packageSize(target)
                guard size <= route.byteLimit else { throw AttachmentFailure.tooLarge(limit: route.byteLimit) }
                return Resolved(url: target, name: name, route: route, byteCount: size)
            }
            if values.isPackage == true {
                // Keynote, Pages, and Numbers files are packages too.
                throw AttachmentFailure.unsupported(
                    Self.unsupportedByExtension[ext] ?? "Apps and packages cannot be attached."
                )
            }
            throw AttachmentFailure.folder
        }
        guard values.isRegularFile == true else { throw AttachmentFailure.notRegularFile }

        var route = try Self.route(for: target, contentType: values.contentType)
        if case .plainText(let kind, let label) = route, label == Self.unknownLabel {
            // An unknown type is read only when it looks like text.
            guard Self.looksLikeText(target) else {
                throw AttachmentFailure.unsupported(Self.unsupportedLine(for: target))
            }
            route = .plainText(kind, label: "Text")
        }

        try await waitForICloud(target, progress: progress)

        let size = values.fileSize ?? (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= route.byteLimit else { throw AttachmentFailure.tooLarge(limit: route.byteLimit) }
        return Resolved(url: target, name: name, route: route, byteCount: size)
    }

    /// The file's bytes. A `.rtfd` package gives its files' bytes in name
    /// order, for the content hash; its text is read from the package.
    func readData(_ resolved: Resolved) throws -> Data {
        do {
            if resolved.route == .rtfd,
               (try? resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return try Self.packageData(resolved.url)
            }
            // Read into memory, never mapped: a mapped file cut short by
            // another app while it is parsed would crash the app.
            let data = try Data(contentsOf: resolved.url)
            // The size on disk can change between the check and the read.
            guard data.count <= resolved.route.byteLimit else {
                throw AttachmentFailure.tooLarge(limit: resolved.route.byteLimit)
            }
            return data
        } catch let failure as AttachmentFailure {
            throw failure
        } catch {
            throw Self.failure(for: error)
        }
    }

    // MARK: Links and aliases

    static func resolveLinks(_ url: URL) throws -> URL {
        var current = url
        if let values = try? current.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]),
           values.isAliasFile == true, values.isSymbolicLink != true {
            do {
                current = try URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting])
            } catch {
                throw AttachmentFailure.missing
            }
        }
        current = current.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: current.path) else { throw AttachmentFailure.missing }
        return current
    }

    // MARK: iCloud

    static let systemICloudState: @Sendable (URL) -> ICloudFileState = { url in
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true else { return .local }
        return values.ubiquitousItemDownloadingStatus == .current ? .local : .needsDownload
    }

    private func waitForICloud(_ url: URL, progress: AttachmentProgressHandler?) async throws {
        guard iCloudState(url) == .needsDownload else { return }
        progress?(.downloadingFromICloud)
        do {
            try startDownload(url)
        } catch {
            throw AttachmentFailure.notDownloaded
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: iCloudWait)
        while clock.now < deadline {
            try await Task.sleep(for: iCloudPoll)
            if iCloudState(url) == .local { return }
        }
        throw AttachmentFailure.notDownloaded
    }

    // MARK: Errors

    /// Maps a read error to its chip line. macOS privacy protection
    /// (Desktop, Documents, Downloads, iCloud Drive) reports "operation not
    /// permitted"; plain permissions report "permission denied".
    static func failure(for error: Error) -> AttachmentFailure {
        if let failure = error as? AttachmentFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .accessDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .missing
            default:
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                    return posixFailure(underlying as NSError) ?? .unreadable
                }
                return .unreadable
            }
        }
        return posixFailure(nsError) ?? .unreadable
    }

    private static func posixFailure(_ error: NSError) -> AttachmentFailure? {
        guard error.domain == NSPOSIXErrorDomain else { return nil }
        switch Int32(error.code) {
        case EPERM, EACCES: return .accessDenied
        case ENOENT: return .missing
        default: return nil
        }
    }

    // MARK: Routing

    /// The route for a file, from its extension first and its type second.
    /// Kinds v1 does not read throw `unsupported` with a way out.
    static func route(for url: URL, contentType: UTType?) throws -> AttachmentRoute {
        let ext = url.pathExtension.lowercased()
        if let line = unsupportedByExtension[ext] { throw AttachmentFailure.unsupported(line) }
        if let route = routesByExtension[ext] { return route }
        if let kind = textKinds[ext] { return .plainText(kind.kind, label: kind.label) }
        let bareName = url.lastPathComponent.lowercased()
        if let kind = textKinds[bareName] { return .plainText(kind.kind, label: kind.label) }

        if let type = contentType ?? UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
            if type.conforms(to: .rtf) { return .rtf }
            if type.conforms(to: .image) {
                throw AttachmentFailure.unsupported(unsupportedLine(for: url))
            }
            if type.conforms(to: .sourceCode) { return .plainText(.code, label: "Source code") }
            if type.conforms(to: .plainText) || type.conforms(to: .text) {
                return .plainText(.text, label: "Text")
            }
            if type.conforms(to: .audio) { throw AttachmentFailure.unsupported("Audio files cannot be read.") }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                throw AttachmentFailure.unsupported("Video files cannot be read.")
            }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
                throw AttachmentFailure.unsupported(unsupportedLine(for: url))
            }
            if type.conforms(to: .application) || type.conforms(to: .executable) {
                throw AttachmentFailure.unsupported("Apps and packages cannot be attached.")
            }
        }
        // Unknown: read as text only when the bytes look like text.
        return .plainText(.text, label: unknownLabel)
    }

    /// Checks the bytes against the route. A `.doc` saved as RTF reads as
    /// RTF; an Office file wrapped by its own password encryption is an OLE
    /// file, not a ZIP, and says it is protected.
    static func confirm(_ route: AttachmentRoute, data: Data) throws -> AttachmentRoute {
        switch route {
        case .pdf:
            guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else {
                throw AttachmentFailure.wrongContent(.pdf)
            }
        case .docx, .pptx, .xlsx, .odt:
            if OOXMLArchive.looksLikeZip(data) { return route }
            if isOLE(data) { throw AttachmentFailure.passwordProtected }
            throw AttachmentFailure.wrongContent(route.kind)
        case .doc:
            if isOLE(data) { return .doc }
            if isRTF(data) { return .rtf }
            if OOXMLArchive.looksLikeZip(data) { return .docx }
            throw AttachmentFailure.wrongContent(.word)
        case .rtf:
            guard isRTF(data) else { throw AttachmentFailure.wrongContent(.word) }
        case .rtfd, .html, .plainText, .image:
            break
        }
        return route
    }

    /// The OLE compound-file signature: legacy Office files, and Office
    /// files encrypted with a password.
    static func isOLE(_ data: Data) -> Bool {
        data.prefix(8).elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    static func isRTF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual(Array("{\\rtf".utf8))
    }

    // MARK: Tables

    static let unknownLabel = "Unknown"

    private static let routesByExtension: [String: AttachmentRoute] = {
        var table: [String: AttachmentRoute] = ["pdf": .pdf, "rtf": .rtf, "rtfd": .rtfd, "odt": .odt, "ott": .odt]
        for ext in ["docx", "docm", "dotx", "dotm"] { table[ext] = .docx }
        for ext in ["doc", "dot"] { table[ext] = .doc }
        for ext in ["pptx", "pptm", "ppsx", "ppsm", "potx", "potm"] { table[ext] = .pptx }
        for ext in ["xlsx", "xlsm", "xltx", "xltm"] { table[ext] = .xlsx }
        for ext in ["html", "htm", "xhtml", "xht"] { table[ext] = .html }
        for ext in ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp"] { table[ext] = .image }
        return table
    }()

    private static let unsupportedByExtension: [String: String] = [
        "key": "Keynote files cannot be read. Export to PowerPoint or PDF.",
        "pages": "Pages files cannot be read. Export to Word or PDF.",
        "numbers": "Numbers files cannot be read. Export to Excel or CSV.",
        "ppt": "Old PowerPoint files (.ppt) cannot be read. Save as .pptx or PDF.",
        "pps": "Old PowerPoint files (.pps) cannot be read. Save as .pptx or PDF.",
        "xls": "Old Excel files (.xls) cannot be read. Save as .xlsx or CSV.",
        "zip": "Zip archives cannot be read. Attach the files inside.",
        "dmg": "Disk images cannot be read.",
        "app": "Apps and packages cannot be attached.",
    ]

    /// Text, Markdown, and code by extension (or whole file name, for the
    /// files that have none), with the label the model block names.
    private static let textKinds: [String: (kind: ChatAttachmentKind, label: String)] = {
        var table: [String: (kind: ChatAttachmentKind, label: String)] = [:]
        for ext in ["txt", "text", "log", "rst", "adoc", "org", "tex", "bib"] { table[ext] = (.text, "Text") }
        table["csv"] = (.text, "CSV")
        table["tsv"] = (.text, "TSV")
        for ext in ["md", "markdown", "mdown", "mkd", "mdx"] { table[ext] = (.markdown, "Markdown") }
        let sources: [String: String] = [
            "swift": "Swift", "py": "Python", "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
            "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript", "rb": "Ruby", "go": "Go",
            "rs": "Rust", "java": "Java", "kt": "Kotlin", "kts": "Kotlin", "c": "C", "h": "C header",
            "cpp": "C++", "cc": "C++", "cxx": "C++", "hpp": "C++ header", "m": "Objective-C",
            "mm": "Objective-C++", "cs": "C#", "php": "PHP", "sql": "SQL", "r": "R", "lua": "Lua",
            "pl": "Perl", "scala": "Scala", "dart": "Dart", "vue": "Vue", "svelte": "Svelte",
            "css": "CSS", "scss": "SCSS", "less": "Less", "ps1": "PowerShell", "gradle": "Gradle",
            "graphql": "GraphQL", "proto": "Protocol Buffers", "tf": "Terraform", "hcl": "HCL",
            "nix": "Nix", "ex": "Elixir", "exs": "Elixir", "erl": "Erlang", "hs": "Haskell",
            "ml": "OCaml", "fs": "F#", "clj": "Clojure", "zig": "Zig", "jl": "Julia",
            "groovy": "Groovy", "el": "Emacs Lisp", "cmake": "CMake",
        ]
        for (ext, language) in sources { table[ext] = (.code, "\(language) source") }
        let named: [String: String] = [
            "sh": "Shell script", "bash": "Shell script", "zsh": "Shell script", "fish": "Shell script",
            "bat": "Batch file", "vim": "Vim script", "json": "JSON", "jsonl": "JSON Lines",
            "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "plist": "Property list",
            "ini": "INI file", "conf": "Configuration file", "cfg": "Configuration file",
            "makefile": "Makefile", "dockerfile": "Dockerfile", "ipynb": "Jupyter notebook",
        ]
        for (ext, label) in named { table[ext] = (.code, label) }
        return table
    }()

    /// "Keynote files cannot be read…" for known kinds, else the extension.
    static func unsupportedLine(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let line = unsupportedByExtension[ext] { return line }
        return ext.isEmpty ? "This kind of file cannot be read." : ".\(ext) files cannot be read."
    }

    /// No NUL byte in the first 8 KB, and those bytes decode as UTF-8 (or
    /// carry a byte-order mark).
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: AttachmentLimits.binaryCheckBytes) else { return true }
        if head.isEmpty { return true }
        return (try? PlainTextReader.decode(head)) != nil
    }

    // MARK: Packages (rtfd)

    private static func packageFiles(_ url: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func packageSize(_ url: URL) -> Int {
        packageFiles(url).reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func packageData(_ url: URL) throws -> Data {
        var data = Data()
        for file in packageFiles(url) {
            data.append(Data(file.lastPathComponent.utf8))
            data.append(try Data(contentsOf: file))
        }
        return data
    }
}
