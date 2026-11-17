import Foundation
import UniformTypeIdentifiers

/// What one tool call left in the thread: the quiet line drawn above the
/// answer ("Searched memory: 4 hits") and the sources it found. Kept on the
/// answer's `QuickMessage`, so a chat reopened from history shows the same
/// lines and the same source list it had when it was answered.
struct ChatToolRecord: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        /// `search_web`, or an explicit "search web" ask.
        case web
        /// `recall_memory`.
        case memory
        /// A read of today's captures.
        case today
        /// Vault search, retired 2026-10-20. Kept so an old chat that holds
        /// one of these lines still opens.
        case vault
        /// `read_skill`.
        case skill
        /// Older messages or tool results were left out to fit the model's
        /// context window.
        case context
        /// Capture to Memory ran on this answer. Drawn under the answer.
        case capture
        /// `read_url`.
        case page
        /// `open_work_item`.
        case open
        /// `show_plate`.
        case plate
        /// `read_calendar`.
        case calendar
        /// `propose_todoist_task`: a task waiting for the user's Add.
        case todoistProposal
        /// The user pressed Add to Todoist. Drawn under the answer.
        case todoistAdded
        /// `propose_task_change` or `propose_event_move`: a change waiting
        /// for the user's Return.
        case changeProposal
        /// The change was made. ⌘Z undoes the newest one.
        case changeDone
        /// ⌘Z put a change back.
        case changeUndone
    }

    var kind: Kind
    /// The line itself, short and plain.
    var summary: String
    /// Files and records the call found, in the order the tool ranked them.
    var sources: [ChatSource]
    /// Set only when the call failed; nil in a record saved before this
    /// field existed, so an older chat still opens.
    var failed: Bool?
    /// The task a `.todoistProposal` or `.todoistAdded` line is about.
    var proposal: TodoistProposal?
    /// The change a `.changeProposal`, `.changeDone` or `.changeUndone`
    /// line is about. Nil in a record saved before changes existed.
    var change: ChangeProposal?
    /// The plate's numbered rows on a `.plate` line, as they were shown:
    /// what "3" or "3 done" points at.
    var worklist: [PlateItem]?

    init(
        kind: Kind,
        summary: String,
        sources: [ChatSource] = [],
        failed: Bool = false,
        proposal: TodoistProposal? = nil,
        change: ChangeProposal? = nil,
        worklist: [PlateItem]? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.sources = sources
        self.failed = failed ? true : nil
        self.proposal = proposal
        self.change = change
        self.worklist = worklist
    }

    var isFailure: Bool { failed == true }

    /// The glyph for the line. Tertiary ink, like every tool line.
    var systemImage: String {
        switch kind {
        case .web: "globe"
        case .memory: "brain.head.profile"
        case .today: "checklist"
        case .vault: "archivebox"
        case .skill: "book"
        case .context: "scissors"
        case .capture: "checkmark"
        case .page: "doc.richtext"
        case .open: "folder"
        case .plate: "tray.full"
        case .calendar: "calendar"
        case .todoistProposal: "plus.circle"
        case .todoistAdded: "checkmark.circle"
        case .changeProposal: "arrow.right.circle"
        case .changeDone: "checkmark.circle"
        case .changeUndone: "arrow.uturn.backward.circle"
        }
    }

    /// Lines above the answer. A capture and a Todoist add confirm the
    /// answer, and a proposal waits on it, so those sit under it.
    var drawsAboveAnswer: Bool {
        switch kind {
        case .capture, .todoistProposal, .todoistAdded, .changeProposal, .changeDone, .changeUndone: false
        default: true
        }
    }
}

/// One source a tool found: a memory file or a task.
struct ChatSource: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The record's title, or the file's store-relative path when it has none.
    var title: String
    /// The day it belongs to (`yyyy-MM-dd`), when the tool gave one.
    var day: String?
    /// A path on this Mac, or nil when the source has no local file (a
    /// project row from the vault's portfolio search, a path outside the
    /// vault clone). Only a source with a path can be opened.
    var path: String?

    var id: String { (path ?? "") + "\u{1F}" + title }

    /// The day to draw beside the title: none when the title already names
    /// it (a daily note's file name is its date).
    var shownDay: String? {
        guard let day, !title.contains(day) else { return nil }
        return day
    }

    init(title: String, day: String? = nil, path: String? = nil) {
        self.title = title
        self.day = day
        self.path = path
    }

    /// The folders a source may open from: the memory repo, the skills repo
    /// and the Work folder, the only places the tools read.
    static let defaultRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "memory", directoryHint: .isDirectory),
            home.appending(path: "skills", directoryHint: .isDirectory),
            home.appending(path: "Documents/Work", directoryHint: .isDirectory),
        ]
    }()

    /// Document types a source may be: text and Markdown, PDFs, images,
    /// office documents, and email. Anything else could be something `open`
    /// runs, installs, imports, or follows (a jar, a `.webloc`, a
    /// configuration profile), so it is refused.
    private static let documentTypes: [UTType] = [
        .plainText, .json, .yaml, .rtf, .pdf, .image, .spreadsheet, .presentation, .emailMessage,
    ] + [
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        "com.apple.iwork.pages.sffpages",
    ].compactMap { UTType($0) }

    /// Types refused even when they are also a document type above: a shell
    /// script is plain text, a macro workbook is a spreadsheet, and an SVG
    /// is an image a browser runs.
    private static let refusedTypes: [UTType] = [
        .sourceCode, .script, .executable, .xml, .archive, .package, .bundle, .propertyList,
    ]

    /// Whether `open` would only show a file of this extension.
    static func isDocument(extension pathExtension: String) -> Bool {
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else { return false }
        return documentTypes.contains { type.conforms(to: $0) }
            && !refusedTypes.contains { type.conforms(to: $0) }
    }

    /// The file to open, or nil when it must not be opened: no path, a
    /// relative path, a `..` component, a path that (with its links
    /// followed) is outside `roots`, anything that is not a plain readable
    /// file (a folder or a bundle), an executable file, or a type that is
    /// not a document. The URL returned is the link-free one that was
    /// checked.
    static func openableURL(
        for path: String?,
        roots: [URL] = defaultRoots,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let given = URL(fileURLWithPath: path)
        guard !given.pathComponents.contains("..") else { return nil }
        let url = given.resolvingSymlinksInPath()
        guard isDocument(extension: url.pathExtension.lowercased()),
              roots.contains(where: { isInside(url, root: $0) })
        else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path),
              !fileManager.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// Whether `url` (already link-free) is inside `root`, by whole path
    /// components.
    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.count > rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}

extension QuickSettings {
    /// The chat defaults: a chat's tools when it has not chosen its own, set
    /// by the switches in Settings › General › Chat. Memory, Tasks,
    /// and Skills are on out of the box; Web search is the one
    /// `modelWebSearchEnabled` switch, shared with the Translator.
    var newChatTools: Set<ChatToolKind> {
        Set(ChatToolKind.allCases.filter(isNewChatToolOn))
    }

    func isNewChatToolOn(_ kind: ChatToolKind) -> Bool {
        switch kind {
        case .memory: newChatMemoryEnabled
        case .tasks: newChatTasksEnabled
        case .skills: newChatSkillsEnabled
        case .web: modelWebSearchEnabled
        case .files: newChatFilesEnabled
        case .calendar: newChatCalendarEnabled
        }
    }

    mutating func setNewChatTool(_ kind: ChatToolKind, on: Bool) {
        switch kind {
        case .memory: newChatMemoryEnabled = on
        case .tasks: newChatTasksEnabled = on
        case .skills: newChatSkillsEnabled = on
        case .web: modelWebSearchEnabled = on
        case .files: newChatFilesEnabled = on
        case .calendar: newChatCalendarEnabled = on
        }
    }
}

extension ChatToolKind {
    /// The same glyphs the tool lines use.
    var systemImage: String {
        switch self {
        case .memory: "brain.head.profile"
        case .tasks: "checklist"
        case .skills: "book"
        case .web: "globe"
        case .files: "folder"
        case .calendar: "calendar"
        }
    }

    /// What the tool reads, for the `⌘K` › Tools rows.
    var detail: String {
        switch self {
        case .memory: "Search notes and today's captures with recall"
        case .tasks: "Read tasks and the plate; propose a Todoist task you confirm"
        case .skills: "Read a skill from ~/.claude/skills"
        case .web: "Search the web and read a link"
        case .files: "Open a project folder or its current document in Work"
        case .calendar: "Read the work calendar: agenda, a day, free slots"
        }
    }
}
