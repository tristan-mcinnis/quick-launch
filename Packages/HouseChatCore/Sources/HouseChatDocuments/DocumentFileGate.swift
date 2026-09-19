import Foundation
import HouseChatCore
import UniformTypeIdentifiers

/// Which extractor reads a file.
enum DocumentRoute: Equatable, Sendable {
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
    case plainText(AttachmentKind, label: String)
    case image

    var kind: AttachmentKind {
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

    /// The `kind` the schema's `kindLabel` names.
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

    /// Size cap for the source.
    func byteLimit(_ configuration: DocumentExtractionConfiguration) -> Int {
        switch self {
        case .image: configuration.maximumImageBytes
        case .plainText, .html: configuration.maximumTextFileBytes
        default: configuration.maximumDocumentBytes
        }
    }
}

/// Where an iCloud file stands.
enum ICloudFileState: Equatable, Sendable {
    /// Not in iCloud, or already on this Mac in its current version.
    case local
    case needsDownload
}

/// The file gate: resolves what a caller attached to one regular file this
/// Mac can read, and decides its route, before any byte is read.
///
/// - Finder aliases and symbolic links are resolved once; the target must be
///   a regular file. Folders and packages (apart from `.rtfd`) are refused.
/// - The route comes from the file's type and extension; the bytes confirm it
///   later (`confirm`), so a `.docx` that is not a ZIP says so.
/// - The size cap is checked from the file's metadata.
/// - An iCloud file that is not on this Mac is downloaded first, with a
///   bounded wait. That is a coordinated file read, not a web fetch: this
///   module never fetches a link.
struct DocumentFileGate: Sendable {
    struct Resolved: Equatable, Sendable {
        /// The file after aliases and links, as read.
        let url: URL
        /// The name as the caller knows it: the file they picked.
        let name: String
        let route: DocumentRoute
        let byteCount: Int
    }

    let configuration: DocumentExtractionConfiguration
    var iCloudWait: Duration
    var iCloudPoll: Duration
    var iCloudState: @Sendable (URL) -> ICloudFileState
    var startDownload: @Sendable (URL) throws -> Void

    init(
        configuration: DocumentExtractionConfiguration = .standard,
        iCloudWait: Duration? = nil,
        iCloudPoll: Duration = .milliseconds(250),
        iCloudState: @escaping @Sendable (URL) -> ICloudFileState = DocumentFileGate.systemICloudState,
        startDownload: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    ) {
        self.configuration = configuration
        self.iCloudWait = iCloudWait ?? configuration.timeout
        self.iCloudPoll = iCloudPoll
        self.iCloudState = iCloudState
        self.startDownload = startDownload
    }

    // MARK: Resolve

    func resolve(_ url: URL, progress: DocumentProgressHandler? = nil) async throws -> Resolved {
        guard url.isFileURL else { throw DocumentExtractionError.missing }
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
                let route = DocumentRoute.rtfd
                let size = Self.packageSize(target)
                guard size <= route.byteLimit(configuration) else {
                    throw DocumentExtractionError.tooLarge(limit: route.byteLimit(configuration))
                }
                return Resolved(url: target, name: name, route: route, byteCount: size)
            }
            if values.isPackage == true {
                throw DocumentExtractionError.unsupported(
                    Self.unsupportedByExtension[ext] ?? "Apps and packages cannot be attached."
                )
            }
            throw DocumentExtractionError.folder
        }
        guard values.isRegularFile == true else { throw DocumentExtractionError.notRegularFile }

        var route = try Self.route(for: target, contentType: values.contentType)
        if case .plainText(_, let label) = route, label == Self.unknownLabel {
            // An unknown type is read only when it looks like text.
            guard Self.looksLikeText(target, configuration: configuration) else {
                throw DocumentExtractionError.unsupported(Self.unsupportedLine(for: target))
            }
            route = .plainText(.text, label: "Text")
        }

        try await waitForICloud(target, progress: progress)

        let size = values.fileSize ?? (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= route.byteLimit(configuration) else {
            throw DocumentExtractionError.tooLarge(limit: route.byteLimit(configuration))
        }
        return Resolved(url: target, name: name, route: route, byteCount: size)
    }

    /// The file's bytes. A `.rtfd` package gives its files' bytes in name
    /// order, for the content hash; its text is read from the package.
    func readData(_ resolved: Resolved) throws -> Data {
        do {
            let limit = resolved.route.byteLimit(configuration)
            if resolved.route == .rtfd,
               (try? resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return try Self.packageData(resolved.url, limit: limit)
            }
            // Read into memory, never mapped: a mapped file cut short by
            // another app while it is parsed would crash the process.
            let data = try Data(contentsOf: resolved.url)
            guard data.count <= limit else { throw DocumentExtractionError.tooLarge(limit: limit) }
            return data
        } catch let failure as DocumentExtractionError {
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
                throw DocumentExtractionError.missing
            }
        }
        current = current.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: current.path) else {
            throw DocumentExtractionError.missing
        }
        return current
    }

    // MARK: iCloud

    static let systemICloudState: @Sendable (URL) -> ICloudFileState = { url in
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true else { return .local }
        return values.ubiquitousItemDownloadingStatus == .current ? .local : .needsDownload
    }

    private func waitForICloud(_ url: URL, progress: DocumentProgressHandler?) async throws {
        guard iCloudState(url) == .needsDownload else { return }
        progress?(.downloadingFromICloud)
        do {
            try startDownload(url)
        } catch {
            throw DocumentExtractionError.notDownloaded
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: iCloudWait)
        while clock.now < deadline {
            try await Task.sleep(for: iCloudPoll)
            if iCloudState(url) == .local { return }
        }
        throw DocumentExtractionError.notDownloaded
    }

    // MARK: Errors

    /// Maps a read error to its line. macOS privacy protection (Desktop,
    /// Documents, Downloads, iCloud Drive) reports "operation not permitted";
    /// plain permissions report "permission denied".
    static func failure(for error: Error) -> DocumentExtractionError {
        if let failure = error as? DocumentExtractionError { return failure }
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

    private static func posixFailure(_ error: NSError) -> DocumentExtractionError? {
        guard error.domain == NSPOSIXErrorDomain else { return nil }
        switch Int32(error.code) {
        case EPERM, EACCES: return .accessDenied
        case ENOENT: return .missing
        default: return nil
        }
    }

    // MARK: Routing

    /// The route for a file, from its extension first and its type second.
    /// Kinds the reader does not support throw `unsupported` with a way out.
    static func route(for url: URL, contentType: UTType?) throws -> DocumentRoute {
        let ext = url.pathExtension.lowercased()
        if let line = unsupportedByExtension[ext] { throw DocumentExtractionError.unsupported(line) }
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
                throw DocumentExtractionError.unsupported(unsupportedLine(for: url))
            }
            if type.conforms(to: .sourceCode) { return .plainText(.code, label: "Source code") }
            if type.conforms(to: .plainText) || type.conforms(to: .text) {
                return .plainText(.text, label: "Text")
            }
            if type.conforms(to: .audio) {
                throw DocumentExtractionError.unsupported("Audio files cannot be read.")
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                throw DocumentExtractionError.unsupported("Video files cannot be read.")
            }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
                throw DocumentExtractionError.unsupported(unsupportedLine(for: url))
            }
            if type.conforms(to: .application) || type.conforms(to: .executable) {
                throw DocumentExtractionError.unsupported("Apps and packages cannot be attached.")
            }
        }
        // Unknown: read as text only when the bytes look like text.
        return .plainText(.text, label: unknownLabel)
    }

    /// Checks the bytes against the route. A `.doc` saved as RTF reads as RTF;
    /// an Office file wrapped by its own password encryption is an OLE file,
    /// not a ZIP, and says it is protected.
    static func confirm(_ route: DocumentRoute, data: Data) throws -> DocumentRoute {
        switch route {
        case .pdf:
            guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else {
                throw DocumentExtractionError.wrongContent(.pdf)
            }
        case .docx, .pptx, .xlsx, .odt:
            if OOXMLArchive.looksLikeZip(data) { return route }
            if isOLE(data) { throw DocumentExtractionError.passwordProtected }
            throw DocumentExtractionError.wrongContent(route.kind)
        case .doc:
            if isOLE(data) { return .doc }
            if isRTF(data) { return .rtf }
            if OOXMLArchive.looksLikeZip(data) { return .docx }
            throw DocumentExtractionError.wrongContent(.word)
        case .rtf:
            guard isRTF(data) else { throw DocumentExtractionError.wrongContent(.word) }
        case .rtfd, .html, .plainText, .image:
            break
        }
        return route
    }

    /// The OLE compound-file signature: legacy Office files, and Office files
    /// encrypted with a password.
    static func isOLE(_ data: Data) -> Bool {
        data.prefix(8).elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    static func isRTF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual(Array("{\\rtf".utf8))
    }

    // MARK: Tables

    static let unknownLabel = "Unknown"

    private static let routesByExtension: [String: DocumentRoute] = {
        var table: [String: DocumentRoute] = ["pdf": .pdf, "rtf": .rtf, "rtfd": .rtfd, "odt": .odt, "ott": .odt]
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
    /// files that have none), with the label the schema's `kindLabel` names.
    private static let textKinds: [String: (kind: AttachmentKind, label: String)] = {
        var table: [String: (kind: AttachmentKind, label: String)] = [:]
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

    /// No NUL byte in the first check window, and those bytes decode as UTF-8
    /// (or carry a byte-order mark).
    static func looksLikeText(_ url: URL, configuration: DocumentExtractionConfiguration) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: configuration.binaryCheckBytes) else { return true }
        if head.isEmpty { return true }
        return (try? PlainTextReader.decode(head)) != nil
    }

    /// The same check for bytes already in hand.
    static func looksLikeText(_ data: Data, configuration: DocumentExtractionConfiguration) -> Bool {
        let head = Data(data.prefix(configuration.binaryCheckBytes))
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

    static func packageSize(_ url: URL) -> Int {
        packageFiles(url).reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// The package's files' bytes in name order, refusing as soon as the bytes
    /// actually read pass `limit`. The metadata pre-check can be raced by a
    /// file that grows between `resolve` and the read; this cap is on what was
    /// read, so a returned package never exceeds it.
    static func packageData(_ url: URL, limit: Int) throws -> Data {
        var data = Data()
        for file in packageFiles(url) {
            data.append(Data(file.lastPathComponent.utf8))
            let fileData = try Data(contentsOf: file)
            guard data.count + fileData.count <= limit else {
                throw DocumentExtractionError.tooLarge(limit: limit)
            }
            data.append(fileData)
        }
        return data
    }
}
