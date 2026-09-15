import Foundation
import Observation
import UniformTypeIdentifiers

/// What `⌘V` found on the pasteboard, reduced to what attaching needs. The
/// view reads the real pasteboard (`AttachmentPasteboardReader`); tests
/// build one by hand. Reading never writes, so the pasteboard's change
/// count does not move.
struct AttachmentPasteboardContents: Sendable, Equatable {
    var fileURLs: [URL] = []
    var image: QuickImageAttachment?
    var string: String?
}

/// The attachments waiting to ride the next question, as chips above the
/// composer. One tray per composer (Quick AI and AI Chat each own one).
/// Every way to attach calls `add(_:)`, which shows a chip at once in the
/// "Reading…" state and reads the source off the main actor through an
/// `AttachmentExtracting` reader. The tray also holds the strip's keyboard
/// selection, the Add Context › Link… field, and the one-step undo that
/// turns a pasted link chip back into text.
///
/// The tray never writes the pasteboard and never writes anything to disk;
/// an image's pixels stay in memory, in the chip's content.
@MainActor
@Observable
final class AttachmentTray {
    /// Where a chip is in its life.
    enum Phase: Equatable, Sendable {
        case reading
        case ready(AttachmentContent)
        /// The chip's one line. A failed chip stays so the user sees what
        /// failed, and never rides the request.
        case failed(String)
    }

    /// One chip.
    struct Item: Identifiable, Equatable, Sendable {
        let id: UUID
        var source: AttachmentSource?
        /// An unresolved drag stays with its chip across window handoffs.
        var dropSource: DropSource? = nil
        var phase: Phase
        /// The provisional kind until the source is read, then the
        /// reference's.
        var kind: ChatAttachmentKind
        /// The provisional name until the source is read, then the
        /// reference's.
        var name: String

        var content: AttachmentContent? {
            if case .ready(let content) = phase { return content }
            return nil
        }

        var isReading: Bool { phase == .reading }

        var failureLine: String? {
            if case .failed(let line) = phase { return line }
            return nil
        }

        var isFailed: Bool { failureLine != nil }

        /// The file behind the chip, for Quick Look and Open.
        var fileURL: URL? {
            if case .some(.file(let url)) = source { return url }
            return content?.ref.path.map { URL(fileURLWithPath: $0) }
        }
    }

    /// A lone link pasted into an empty composer became this chip; `⌘Z`
    /// turns it back into `text`.
    struct PastedLink: Equatable, Sendable {
        let itemID: UUID
        let text: String
    }

    /// What `⌘V` should do with the pasteboard.
    enum PasteAction: Equatable, Sendable {
        /// File URLs: attach the files instead of pasting their paths.
        case attachFiles([URL])
        /// An image: attach it.
        case attachImage(QuickImageAttachment)
        /// A lone http(s) URL into an empty composer: a Link chip.
        case attachLink(URL, text: String)
        /// Anything else: the field pastes it as text.
        case pasteText
    }

    // MARK: - Messages

    static let attachmentLimitNotice =
        "\(AttachmentLimits.attachmentsPerMessage) attachments is the most for one message."
    static let imageLimitNotice =
        "\(AttachmentLimits.imagesPerMessage) images is the most for one message."
    static let notWebLinkNotice = "Paste a link that starts with http:// or https://."
    static let pastedImageName = "Pasted image"
    static let droppedImageName = "Dropped image"

    // MARK: - State

    private(set) var items: [Item] = []
    /// One line for the last thing the tray refused: the eleventh chip, a
    /// seventh image, a folder, a second copy of a file. Cleared by the
    /// next change.
    private(set) var notice: String?
    /// The keyboard selection in the strip. Nil while the keys are the
    /// composer's.
    private(set) var focusedItemID: UUID?
    /// The Add Context › Link… field's text. Nil while the pane lists rows.
    var linkDraft: String?
    /// True while a drag with something to attach is over a drop target.
    var isDropTargeted = false
    /// Set by the owner: where the attachments go ("Sent to DeepSeek",
    /// "Only on this Mac", "Will be cut to fit Local Models").
    var routingLine: String?
    /// Set by the owner: Finder is the app behind the overlay, so Add
    /// Context lists Finder Selection.
    var finderIsBehind = false
    private(set) var pastedLink: PastedLink?

    // MARK: - Owner hooks

    /// Runs File…: the owner activates the app, shows the open panel with
    /// `openPanelFileExtensions`, and adds what was picked.
    @ObservationIgnored var onChooseFiles: (@MainActor () -> Void)?
    /// Runs Finder Selection: the owner reads the selected paths and adds
    /// them as files.
    @ObservationIgnored var onReadFinderSelection: (@MainActor () -> Void)?

    @ObservationIgnored private let extractor: any AttachmentExtracting
    @ObservationIgnored private let readTimeout: Duration
    /// The reads themselves, by chip. A read runs on its own task, so a
    /// hand-off (`handOff()`, `adopt(_:)`) can move it to another tray
    /// without starting it again.
    @ObservationIgnored private var reads: [UUID: Task<Result<AttachmentContent, AttachmentReadFailure>, Never>] = [:]
    /// Per chip, the task that waits on its read and files the result here.
    @ObservationIgnored private var readTasks: [UUID: Task<Void, Never>] = [:]

    init(
        extractor: any AttachmentExtracting,
        readTimeout: Duration = AttachmentLimits.extractionTimeout
    ) {
        self.extractor = extractor
        self.readTimeout = readTimeout
    }

    // MARK: - Reading the tray

    var isEmpty: Bool { items.isEmpty }
    var isReading: Bool { items.contains(where: \.isReading) }
    var isStripFocused: Bool { focusedItemID != nil }
    var canUndoPastedLink: Bool { pastedLink != nil }
    var isEnteringLink: Bool { linkDraft != nil }

    /// What rides the request: the chips that were read, in the order added.
    var readyContents: [AttachmentContent] { items.compactMap(\.content) }

    /// The status line while a send waits: "Reading report.pdf…".
    var readingStatusLine: String? {
        let reading = items.filter(\.isReading)
        guard let first = reading.first else { return nil }
        return reading.count == 1
            ? "Reading \(first.name)…"
            : "Reading \(reading.count) attachments…"
    }

    /// Chips that count against the limits: reading or read, never failed.
    private var liveItems: [Item] { items.filter { !$0.isFailed } }

    private var liveImageCount: Int { liveItems.filter { $0.kind.isImage }.count }

    // MARK: - Adding

    /// Adds one chip in the "Reading…" state and starts reading it. Returns
    /// the chip's id, or nil when the tray refused it; `notice` says why.
    @discardableResult
    func add(_ source: AttachmentSource) -> UUID? {
        let kind = source.provisionalKind
        let name = source.provisionalName
        if let refusal = refusal(for: source, kind: kind, name: name) {
            notice = refusal
            return nil
        }
        notice = nil
        let item = Item(id: UUID(), source: source, phase: .reading, kind: kind, name: name)
        items.append(item)
        startReading(item)
        return item.id
    }

    /// Adds each source in order; the ones past a limit are refused and
    /// the last refusal stays in `notice`.
    @discardableResult
    func add(contentsOf sources: [AttachmentSource]) -> [UUID] {
        var added: [UUID] = []
        var lastRefusal: String?
        for source in sources {
            if let id = add(source) {
                added.append(id)
            } else {
                lastRefusal = notice
            }
        }
        if let lastRefusal { notice = lastRefusal }
        return added
    }

    private func refusal(for source: AttachmentSource, kind: ChatAttachmentKind, name: String) -> String? {
        switch source {
        case .file(let url):
            guard url.isFileURL else { return "\(name) is not a file on this Mac." }
            if Self.isFolder(url) { return AttachmentReadFailure.folder.line }
        case .link(let url):
            guard Self.isWebURL(url) else { return Self.notWebLinkNotice }
        case .image, .selection:
            break
        }
        if let identity = source.identity,
           let existing = liveItems.first(where: { $0.source?.identity == identity }) {
            return "\(existing.name) is already attached."
        }
        if liveItems.count >= AttachmentLimits.attachmentsPerMessage {
            return Self.attachmentLimitNotice
        }
        if kind.isImage, liveImageCount >= AttachmentLimits.imagesPerMessage {
            return Self.imageLimitNotice
        }
        return nil
    }

    /// A folder, not a package: an `.rtfd` or a Keynote file is a folder
    /// on disk too, and goes to the reader, which reads it or says why not.
    /// A path that cannot be looked at goes by its trailing slash.
    static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              let isDirectory = values.isDirectory
        else { return url.hasDirectoryPath && url.pathExtension.isEmpty }
        return isDirectory && values.isPackage != true
    }

    private func startReading(_ item: Item) {
        let extractor = extractor
        let timeout = readTimeout
        let read = Task {
            let source: AttachmentSource?
            if let drop = item.dropSource {
                source = await drop.resolve(timeout: timeout)
            } else {
                source = item.source
            }
            guard !Task.isCancelled else { return Result<AttachmentContent, AttachmentReadFailure>.failure(.init("Cancelled")) }
            guard let source else { return .failure(.init(Self.nothingToAttachNotice)) }
            if case .file(let url) = source, Self.isFolder(url) { return .failure(.folder) }
            return await Self.read(source, with: extractor, timeout: timeout)
        }
        watch(item.id, read)
    }

    /// Files the result of `read` on chip `id` when it ends.
    private func watch(_ id: UUID, _ read: Task<Result<AttachmentContent, AttachmentReadFailure>, Never>) {
        reads[id] = read
        readTasks[id] = Task { [weak self] in
            let result = await read.value
            self?.finishReading(id, result: result)
        }
    }

    /// Reads one source with the reader, bounded by `timeout`.
    nonisolated private static func read(
        _ source: AttachmentSource,
        with extractor: any AttachmentExtracting,
        timeout: Duration
    ) async -> Result<AttachmentContent, AttachmentReadFailure> {
        do {
            let content = try await withThrowingTaskGroup(of: AttachmentContent?.self) { group in
                group.addTask { try await extractor.content(for: source) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let content = first else {
                    throw AttachmentReadFailure.tookTooLong
                }
                return content
            }
            return .success(content)
        } catch let failure as AttachmentReadFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(AttachmentReadFailure("Cancelled"))
        } catch {
            return .failure(AttachmentReadFailure(error.localizedDescription))
        }
    }

    private func finishReading(_ id: UUID, result: Result<AttachmentContent, AttachmentReadFailure>) {
        readTasks[id] = nil
        reads[id] = nil
        // A chip removed or cancelled while it read is already gone.
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isReading else { return }
        if let resolved = items[index].dropSource?.resolvedSource {
            if let identity = resolved.identity,
               let existing = liveItems.first(where: { $0.id != id && $0.source?.identity == identity }) {
                items.remove(at: index)
                afterRemoval()
                notice = "\(existing.name) is already attached."
                return
            }
            items[index].source = resolved
        }
        switch result {
        case .success(let content):
            let isNewImage = content.ref.kind.isImage && !items[index].kind.isImage
            if isNewImage, liveImageCount >= AttachmentLimits.imagesPerMessage {
                items[index].phase = .failed(Self.imageLimitNotice)
                return
            }
            items[index].kind = content.ref.kind
            items[index].name = content.ref.name
            items[index].phase = .ready(content)
        case .failure(let failure):
            items[index].phase = .failed(failure.line)
        }
    }

    /// Waits until no chip is reading. The send calls this, with
    /// `readingStatusLine` on screen; `cancelReading()` ends the wait.
    func waitUntilRead() async {
        while let entry = readTasks.first {
            await entry.value.value
            readTasks[entry.key] = nil
            if Task.isCancelled { return }
        }
    }

    /// Retry a failed read in place, keeping its position and keyboard focus.
    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isFailed else { return false }
        let item = items[index]
        if item.source == nil, liveItems.count >= AttachmentLimits.attachmentsPerMessage {
            notice = Self.attachmentLimitNotice
            return false
        }
        if item.source == nil, item.kind.isImage, liveImageCount >= AttachmentLimits.imagesPerMessage {
            notice = Self.imageLimitNotice
            return false
        }
        if let source = item.source,
           let refusal = refusal(for: source, kind: item.kind, name: item.name) {
            notice = refusal
            return false
        }
        notice = nil
        items[index].phase = .reading
        startReading(items[index])
        return true
    }

    /// Space on a failed chip retries it instead of opening its file.
    @discardableResult
    func retryFocusedFailure() -> Bool {
        guard let focusedItemID, items.contains(where: { $0.id == focusedItemID && $0.isFailed }) else { return false }
        _ = retry(focusedItemID)
        return true
    }

    // MARK: - Removing

    /// Escape while a send waits: stops every read and drops those chips.
    /// Chips already read stay, and so does the typed text. Returns false
    /// when nothing was reading.
    @discardableResult
    func cancelReading() -> Bool {
        let reading = Set(items.filter(\.isReading).map(\.id))
        guard !reading.isEmpty else { return false }
        for id in reading { stopReading(id) }
        items.removeAll { reading.contains($0.id) }
        afterRemoval()
        return true
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        stopReading(id)
        items.remove(at: index)
        if focusedItemID == id {
            focusedItemID = items.isEmpty ? nil : items[max(0, index - 1)].id
        }
        afterRemoval()
    }

    /// Backspace in an empty composer: drops the newest chip.
    @discardableResult
    func removeNewest() -> Bool {
        guard let newest = items.last else { return false }
        remove(newest.id)
        return true
    }

    func removeAll() {
        for id in Set(readTasks.keys).union(reads.keys) { stopReading(id) }
        items.removeAll()
        focusedItemID = nil
        pastedLink = nil
        notice = nil
    }

    /// The message was sent: hands over the chips that were read, in order,
    /// and empties the tray. A chip still reading is dropped, so the send
    /// waits (`waitUntilRead()`) first; a failed chip never rides.
    func takeForSend() -> [AttachmentContent] {
        let contents = readyContents
        removeAll()
        return contents
    }

    private func stopReading(_ id: UUID) {
        reads[id]?.cancel()
        reads[id] = nil
        readTasks[id]?.cancel()
        readTasks[id] = nil
    }

    // MARK: - Hand-off

    /// The chips as they move to another tray (Open in AI Chat): each chip
    /// in its phase, and the reads still running, which go on where they
    /// land instead of starting again.
    struct Handoff: Sendable {
        var items: [Item] = []
        var reads: [UUID: Task<Result<AttachmentContent, AttachmentReadFailure>, Never>] = [:]

        var isEmpty: Bool { items.isEmpty }
    }

    /// Empties this tray into a hand-off without stopping a read.
    func handOff() -> Handoff {
        let handoff = Handoff(items: items, reads: reads)
        // The waiters go; the reads keep running for the tray that adopts
        // them. A waiter that still wakes finds no chip here and does nothing.
        for task in readTasks.values { task.cancel() }
        readTasks.removeAll()
        reads.removeAll()
        items.removeAll()
        focusedItemID = nil
        pastedLink = nil
        notice = nil
        linkDraft = nil
        return handoff
    }

    /// Takes chips handed over from another tray, after its own; a read
    /// still running reports here.
    func adopt(_ handoff: Handoff) {
        for item in handoff.items where !items.contains(where: { $0.id == item.id }) {
            items.append(item)
            guard item.isReading else { continue }
            if let read = handoff.reads[item.id] {
                watch(item.id, read)
            } else {
                startReading(item)
            }
        }
    }

    private func afterRemoval() {
        if let pastedLink, !items.contains(where: { $0.id == pastedLink.itemID }) {
            self.pastedLink = nil
        }
        if let focusedItemID, !items.contains(where: { $0.id == focusedItemID }) {
            self.focusedItemID = items.last?.id
        }
        if items.isEmpty { focusedItemID = nil }
        notice = nil
    }

    /// Clears the notice once the user moves on.
    func dismissNotice() {
        notice = nil
    }

    // MARK: - Keyboard in the strip

    /// `⇧Tab` from the composer: the newest chip takes the keyboard.
    @discardableResult
    func enterStrip() -> Bool {
        guard let newest = items.last else { return false }
        focusedItemID = newest.id
        return true
    }

    /// `esc` in the strip: the keys go back to the composer.
    @discardableResult
    func leaveStrip() -> Bool {
        guard focusedItemID != nil else { return false }
        focusedItemID = nil
        return true
    }

    /// `←` `→` in the strip. Stops at either end.
    @discardableResult
    func moveFocus(_ delta: Int) -> Bool {
        guard let focusedItemID,
              let index = items.firstIndex(where: { $0.id == focusedItemID })
        else { return false }
        let next = min(max(index + delta, 0), items.count - 1)
        self.focusedItemID = items[next].id
        return true
    }

    /// Backspace: in the strip it removes the selected chip; in an empty
    /// composer it removes the newest. Returns false when the key is the
    /// field's.
    @discardableResult
    func handleBackspace(composerIsEmpty: Bool) -> Bool {
        if let focusedItemID {
            remove(focusedItemID)
            return true
        }
        guard composerIsEmpty else { return false }
        return removeNewest()
    }

    /// Space in the strip opens Quick Look on this file: the selected
    /// chip's, when it is a file on this Mac. A link or an image has none;
    /// Space then does nothing, and still stays out of the composer.
    var focusedFileURL: URL? {
        guard let focusedItemID else { return nil }
        return items.first(where: { $0.id == focusedItemID })?.fileURL
    }

    // MARK: - Paste

    /// What `⌘V` should do: files first (Finder also puts an icon image on
    /// the pasteboard), then text that is not a lone link (Office apps put
    /// a picture next to copied text), then an image, then a lone link into
    /// an empty composer. A link inside other text stays text.
    static func pasteAction(
        for contents: AttachmentPasteboardContents,
        composerText: String
    ) -> PasteAction {
        if !contents.fileURLs.isEmpty { return .attachFiles(contents.fileURLs) }
        let string = contents.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = webURL(from: string)
        if !string.isEmpty, link == nil { return .pasteText }
        if let image = contents.image { return .attachImage(image) }
        if let link, composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .attachLink(link, text: contents.string ?? string)
        }
        return .pasteText
    }

    /// `⌘V` in the composer. Returns true when the paste became chips (or
    /// was refused with a notice); false leaves it to the field as text.
    @discardableResult
    func paste(_ contents: AttachmentPasteboardContents, composerText: String) -> Bool {
        switch Self.pasteAction(for: contents, composerText: composerText) {
        case .attachFiles(let urls):
            add(contentsOf: urls.map(AttachmentSource.file))
            return true
        case .attachImage(let image):
            add(.image(image, name: Self.pastedImageName, kind: .image))
            return true
        case .attachLink(let url, let text):
            if let id = add(.link(url)) { pastedLink = PastedLink(itemID: id, text: text) }
            return true
        case .pasteText:
            return false
        }
    }

    /// `⌘Z` right after a link paste: the chip goes and its text comes back
    /// for the composer. Nil when there is nothing to undo.
    func undoPastedLink() -> String? {
        guard let pastedLink else { return nil }
        self.pastedLink = nil
        remove(pastedLink.itemID)
        return pastedLink.text
    }

    /// The composer's text changed: typing after a link paste makes `⌘Z`
    /// the field's again, and a notice has been read.
    func composerTextDidChange(_ text: String) {
        if !text.isEmpty { pastedLink = nil }
        if notice != nil, !text.isEmpty { notice = nil }
        if !text.isEmpty { focusedItemID = nil }
    }

    // MARK: - Add Context rows

    /// Runs a row that attaches rather than captures. Link… opens the field
    /// (prefilled with the clipboard when it holds one web link); File… and
    /// Finder Selection go to the owner. Returns false for a capture row,
    /// which the view model runs.
    @discardableResult
    func run(_ row: AddContextRow, clipboard: String?) -> Bool {
        switch row {
        case .capture:
            return false
        case .file:
            onChooseFiles?()
            return true
        case .link:
            beginLinkEntry(clipboard: clipboard)
            return true
        case .finderSelection:
            onReadFinderSelection?()
            return true
        }
    }

    func beginLinkEntry(clipboard: String?) {
        let candidate = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        linkDraft = Self.webURL(from: candidate) == nil ? "" : candidate
        notice = nil
    }

    /// `↩` in the Link field. Returns true when the link became a chip.
    @discardableResult
    func submitLinkEntry() -> Bool {
        guard let draft = linkDraft else { return false }
        guard let url = Self.webURL(from: draft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            notice = Self.notWebLinkNotice
            return false
        }
        guard add(.link(url)) != nil else { return false }
        linkDraft = nil
        return true
    }

    /// `esc` in the Link field: back to the rows.
    @discardableResult
    func cancelLinkEntry() -> Bool {
        guard linkDraft != nil else { return false }
        linkDraft = nil
        notice = nil
        return true
    }

    // MARK: - Drop

    /// What a drop target takes: files, web links, and images.
    static let droppableTypes: [UTType] = [.fileURL, .url, .image]

    /// A provider gets a chip before loading begins. Its complete read belongs
    /// to that chip, so Send waits and moving to AI Chat transfers the same read.
    /// A later drop appends; it never cancels an earlier drop still loading.
    func acceptDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            let hasFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let hasImage = provider.registeredTypeIdentifiers.contains {
                UTType($0)?.conforms(to: .image) == true
            }
            let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            guard hasFile || hasImage || hasURL else {
                notice = Self.nothingToAttachNotice
                continue
            }
            guard liveItems.count < AttachmentLimits.attachmentsPerMessage else {
                notice = Self.attachmentLimitNotice
                continue
            }
            let kind: ChatAttachmentKind = hasFile ? .text : (hasImage ? .image : .link)
            if kind.isImage, liveImageCount >= AttachmentLimits.imagesPerMessage {
                notice = Self.imageLimitNotice
                continue
            }
            let name = provider.suggestedName ?? (hasFile ? "Dropped file" : (hasImage ? Self.droppedImageName : "Dropped link"))
            let item = Item(
                id: UUID(), source: nil, dropSource: DropSource(provider: provider),
                phase: .reading, kind: kind, name: name
            )
            items.append(item)
            startReading(item)
        }
    }

    /// Includes provider resolution and extraction: a drop is ready to send
    /// only after both have finished.
    func waitForDrop() async {
        await waitUntilRead()
    }

    /// NSItemProvider is used only on the main actor. Reference identity makes
    /// this transferable with a Sendable chip without copying provider state.
    @MainActor
    final class DropSource: Equatable {
        private let provider: NSItemProvider
        private(set) var resolvedSource: AttachmentSource?

        init(provider: NSItemProvider) { self.provider = provider }

        nonisolated static func == (lhs: DropSource, rhs: DropSource) -> Bool { lhs === rhs }

        private func loadSource() async -> AttachmentSource? {
            await AttachmentTray.source(from: provider)
        }

        func resolve(timeout: Duration) async -> AttachmentSource? {
            if let resolvedSource { return resolvedSource }
            let source = await withTaskGroup(of: AttachmentSource?.self) { group in
                group.addTask { await self.loadSource() }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled else { return nil }
            resolvedSource = source
            return source
        }
    }

    static let nothingToAttachNotice = "Nothing here can be attached."

    private static func source(from provider: NSItemProvider) async -> AttachmentSource? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(from: provider), url.isFileURL {
            return .file(url)
        }
        guard !Task.isCancelled else { return nil }
        if let type = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: .image) }),
           let data = await loadData(from: provider, type: type),
           let image = ClipboardImageReader.attachment(
               data: data,
               mimeType: type.preferredMIMEType ?? "image/png"
           ) {
            return .image(image, name: droppedImageName, kind: .image)
        }
        guard !Task.isCancelled else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider), isWebURL(url) {
            return .link(url)
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? .fileURL : .url
        guard let data = await loadData(from: provider, type: type) else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        let load = DropLoad<Data>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard load.install(continuation) else { return }
                load.setProgress(provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in load.finish(data) })
            }
        } onCancel: { load.cancel() }
    }

    // MARK: - Links

    /// A web link typed or pasted on its own: http or https, a host, and
    /// no spaces. Anything else is not a link to attach.
    static func webURL(from text: String) -> URL? {
        guard !text.isEmpty,
              !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text)
        else { return nil }
        return isWebURL(url) ? url : nil
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host() ?? "").isEmpty
    }

    // MARK: - File…

    /// The extensions the File… panel offers: section 3.3's types.
    static let openPanelFileExtensions: [String] = [
        "pdf",
        "docx", "doc", "rtf", "rtfd", "odt",
        "pptx", "xlsx",
        "html", "htm", "xhtml",
        "txt", "text", "md", "markdown", "json", "yaml", "yml", "csv", "tsv", "xml", "log",
        "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "h", "m", "mm", "cpp", "hpp",
        "java", "kt", "rb", "sh", "zsh", "css", "scss", "sql", "lua", "php", "cs", "r", "pl",
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp",
    ]
}

/// Provider callbacks may arrive on any queue or after cancellation. The lock
/// guards the continuation, completion flag, and Progress; exactly one path
/// resumes, so removing a chip never waits indefinitely for its drag provider.
private final class DropLoad<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var progress: Progress?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let installed = lock.withLock {
            guard !finished else { return false }
            self.continuation = continuation
            return true
        }
        if !installed { continuation.resume(returning: nil) }
        return installed
    }

    func setProgress(_ progress: Progress) {
        let cancelled = lock.withLock {
            guard !finished else { return true }
            self.progress = progress
            return false
        }
        if cancelled { progress.cancel() }
    }

    func finish(_ value: Value?) {
        let continuation = lock.withLock {
            guard !finished else { return Optional<CheckedContinuation<Value?, Never>>.none }
            finished = true
            let kept = self.continuation
            self.continuation = nil
            progress = nil
            return kept
        }
        continuation?.resume(returning: value)
    }

    func cancel() {
        let progress = lock.withLock { self.progress }
        finish(nil)
        progress?.cancel()
    }
}
