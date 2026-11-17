import Foundation

/// Finds a project folder, a stage folder, or the current document under the
/// Work folder from a few spoken words ("jade fox", "discussion guide"). Pure
/// over the file system, so tests run it on a temporary folder.
///
/// The Work folder is laid out `<Client>/<year>/<project>/NN-stage/`, and each
/// project's `START-HERE.md` lists the current documents of every stage
/// folder. The resolver reads that list first and falls back to the newest
/// version or date in the file names only when the list is missing.
struct WorkItemResolver: Sendable {
    let root: URL

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Documents/Work", directoryHint: .isDirectory)

    init(root: URL = WorkItemResolver.defaultRoot) {
        self.root = root
    }

    enum Target: String, Sendable {
        case folder
        case file
    }

    enum Resolution: Equatable, Sendable {
        /// One thing to open, and other close candidates the model may name.
        case found(URL, alternatives: [URL])
        /// More than one project matched equally; nothing is opened.
        case ambiguous([URL])
        /// Nothing matched; the reason is for the model.
        case notFound(String)
    }

    /// Words that only say what kind of thing is wanted.
    private static let fillerWords: Set<String> = [
        "the", "a", "an", "my", "our", "for", "of", "folder", "project", "file", "latest",
        "newest", "current", "last", "open", "finder", "doc", "document",
    ]

    /// Spoken words and the stage folder number they point at.
    static let stageWords: [String: Int] = [
        "brief": 1, "briefing": 1,
        "proposal": 2, "scope": 2,
        "finance": 3, "costing": 3, "cost": 3, "budget": 3, "quote": 3, "invoice": 3, "sow": 3,
        "kickoff": 4,
        "recruitment": 5, "recruit": 5, "screener": 5,
        "guide": 6, "dg": 6, "discussion": 6,
        "fieldwork": 7, "field": 7, "transcript": 7, "transcripts": 7, "schedule": 7,
        "knowledge": 8,
        "analysis": 9, "synthesis": 9, "findings": 9, "workbook": 9,
        "report": 10, "reporting": 10, "deck": 10, "readout": 10, "topline": 10,
    ]

    /// Words that also match a file name inside the stage folder.
    private static let fileAliases: [String: [String]] = [
        "guide": ["dg", "guide"], "discussion": ["dg", "guide"], "dg": ["dg", "guide"],
        "screener": ["screener"], "proposal": ["proposal"], "costing": ["costing", "cost"],
        "deck": ["deck", "report"], "report": ["report", "deck"], "topline": ["topline"],
        "schedule": ["schedule"], "transcript": ["transcript"], "sow": ["sow"],
    ]

    // MARK: - Resolving

    func resolve(project: String, item: String?, target: Target) -> Resolution {
        let projectWords = Self.words(project)
        guard !projectWords.isEmpty else { return .notFound("No project name was given.") }
        let ranked = rankProjects(projectWords)
        guard let best = ranked.first else {
            return .notFound("No project folder under \(root.path) matches \"\(project)\".")
        }
        let ties = ranked.prefix { $0.score == best.score }
        if ties.count > 1, ties.count <= 6 {
            // Same score: the newest year wins only when it is the only one in that year.
            let newestYear = ties.map(\.year).max() ?? 0
            let newest = ties.filter { $0.year == newestYear }
            if newest.count > 1 { return .ambiguous(newest.map(\.url)) }
        } else if ties.count > 6 {
            return .ambiguous(Array(ties.prefix(6).map(\.url)))
        }
        let projectURL = (ties.max { $0.year < $1.year } ?? best).url
        let itemWords = Self.words(item ?? "")

        guard let stage = stageFolder(in: projectURL, itemWords: itemWords) else {
            if target == .folder || itemWords.isEmpty {
                return .found(projectURL, alternatives: [])
            }
            return .notFound("Found the project \(projectURL.lastPathComponent), but no folder in it matches \"\(item ?? "")\".")
        }
        if target == .folder {
            return .found(stage, alternatives: [])
        }
        let files = rankFiles(in: stage, project: projectURL, itemWords: itemWords)
        guard let first = files.first else {
            return .found(stage, alternatives: [])
        }
        return .found(first, alternatives: Array(files.dropFirst().prefix(3)))
    }

    // MARK: - Projects

    struct ProjectMatch: Equatable {
        let url: URL
        let score: Int
        let year: Int
    }

    /// Every project folder: `<Client>/<year>/<project>`, plus folders in a
    /// client's `projects/` or `unknown/`.
    func projectFolders() -> [URL] {
        var found: [URL] = []
        for client in Self.directories(in: root) where !Self.isSkipped(client.lastPathComponent) {
            for group in Self.directories(in: client) {
                let name = group.lastPathComponent
                guard Self.isYear(name) || name == "projects" || name == "unknown" else { continue }
                found += Self.directories(in: group).filter { !Self.isSkipped($0.lastPathComponent) }
            }
        }
        return found
    }

    func rankProjects(_ queryWords: [String]) -> [ProjectMatch] {
        let joinedQuery = queryWords.joined()
        return projectFolders().compactMap { url -> ProjectMatch? in
            let name = url.lastPathComponent
            let nameWords = Self.words(name)
            let client = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let clientWords = Self.words(client)
            var score = 0
            for word in queryWords {
                if nameWords.contains(word) {
                    score += 3
                } else if clientWords.contains(word) {
                    score += 1
                } else if word.count >= 3, nameWords.joined().contains(word) {
                    score += 2
                } else {
                    return nil
                }
            }
            // "jadefox" for "jade-fox", and the whole phrase as one run.
            if nameWords.joined().contains(joinedQuery) { score += 2 }
            let yearName = url.deletingLastPathComponent().lastPathComponent
            return ProjectMatch(url: url, score: score, year: Int(yearName) ?? 0)
        }
        .sorted { ($0.score, $0.year) > ($1.score, $1.year) }
    }

    // MARK: - Stage folders

    func stageFolder(in project: URL, itemWords: [String]) -> URL? {
        guard !itemWords.isEmpty else { return nil }
        let children = Self.directories(in: project)
        let wanted = itemWords.compactMap { Self.stageWords[$0] }
        if let number = wanted.first {
            let prefix = String(format: "%02d-", number)
            if let match = children.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) {
                return match
            }
        }
        // A folder named by the words themselves ("desk research").
        return children.first { child in
            let childWords = Self.words(child.lastPathComponent)
            return itemWords.allSatisfy { childWords.contains($0) }
        }
    }

    // MARK: - Files

    /// The documents in a stage folder, the one to open first. The project's
    /// `START-HERE.md` list of current files narrows the set when it has one.
    func rankFiles(in stage: URL, project: URL, itemWords: [String]) -> [URL] {
        let all = Self.files(in: stage).filter { ChatSource.isDocument(extension: $0.pathExtension.lowercased()) }
        guard !all.isEmpty else { return [] }
        let current = Self.currentFiles(startHere: project.appending(path: "START-HERE.md"), stage: stage.lastPathComponent)
        let listed = all.filter { current.contains($0.lastPathComponent) }
        let pool = listed.isEmpty ? all : listed
        let hints = Set(itemWords.flatMap { Self.fileAliases[$0] ?? [] })
        return pool
            .map { (url: $0, key: Self.fileKey($0, hints: hints)) }
            .sorted { $1.key.lexicographicallyPrecedes($0.key) }
            .map(\.url)
    }

    /// Sorts best first: names the thing asked for, not a side copy, an
    /// office file or PDF before notes, then the higher version, the later
    /// date, and the later change.
    private static func fileKey(_ url: URL, hints: Set<String>) -> [Double] {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let nameWords = Set(words(name))
        let named: Double = hints.isEmpty || !hints.isDisjoint(with: nameWords) ? 1 : 0
        let sideWords: Set<String> = ["marked", "changes", "draft", "old", "copy", "notes", "audit"]
        let main: Double = sideWords.isDisjoint(with: nameWords) ? 1 : 0
        let kind: Double = switch url.pathExtension.lowercased() {
        case "docx", "pptx", "xlsx", "pdf", "key", "pages", "numbers", "doc", "ppt", "xls": 2
        case "md", "txt": 1
        default: 0
        }
        let version = versionNumber(in: name)
        let date = Double(dateStamp(in: name) ?? 0)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return [named, main, kind, version, date, modified]
    }

    /// `v3.11` as 3.011, `v12` as 12; 0 without one.
    static func versionNumber(in name: String) -> Double {
        guard let match = name.firstMatch(of: /v(\d+)(?:\.(\d+))?/) else { return 0 }
        let major = Double(match.1) ?? 0
        let minor = match.2.flatMap { Double($0) } ?? 0
        return major + minor / 1000
    }

    /// The last `yyyymmdd` in a name, or nil.
    static func dateStamp(in name: String) -> Int? {
        name.matches(of: /(20\d{6})/).last.flatMap { Int($0.1) }
    }

    /// The file names `START-HERE.md` lists as current under one stage
    /// folder's heading, or an empty set.
    static func currentFiles(startHere: URL, stage: String) -> Set<String> {
        guard let text = try? String(contentsOf: startHere, encoding: .utf8) else { return [] }
        var inSection = false
        var names: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                inSection = line.contains("`\(stage)/`")
                continue
            }
            guard inSection, line.hasPrefix("- "), !line.hasPrefix("- Folders") else { continue }
            if let match = line.firstMatch(of: /`([^`\/]+)`/) {
                names.insert(String(match.1))
            }
        }
        return names
    }

    // MARK: - File system

    private static func directories(in url: URL) -> [URL] {
        children(of: url).filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
                $0.isDirectory == true && $0.isPackage != true
            } ?? false
        }
    }

    private static func files(in url: URL) -> [URL] {
        children(of: url).filter { child in
            (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    private static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isYear(_ name: String) -> Bool {
        name.count == 4 && name.allSatisfy(\.isNumber)
    }

    private static func isSkipped(_ name: String) -> Bool {
        name.hasPrefix("_") || name.hasPrefix("00-") || name.hasPrefix("99-")
    }

    /// Lowercased words of a name or a phrase, accents folded, filler dropped.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !fillerWords.contains($0) }
    }

    /// `Client/2026/project/06-discussion-guide/file.docx`, for the model.
    func relativePath(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    /// Whether `url` is inside `root` by whole path components, links followed.
    func contains(_ url: URL) -> Bool {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return parts.count > rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
    }
}
