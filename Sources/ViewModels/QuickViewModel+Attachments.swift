import Foundation

/// Attachments in the view model (spec section 5, WP-D): the view model
/// owns the composer's tray, runs the Add Context rows that attach (File…,
/// Link…, Finder Selection), turns what a question carries into references
/// on its message, and keeps each attachment's text in the session store
/// (`QuickStore.attachments`), in memory only. Chat history keeps the
/// references; after a relaunch a sent attachment's chip reads "Not loaded"
/// and is read again only when the user chooses Re-attach.
extension QuickViewModel {
    /// The app's one reader. An actor that holds only its configuration, so
    /// both views share it.
    static let sharedAttachmentExtractor = AttachmentExtractor()

    /// The session's attachment text and pictures, shared with the other view.
    var attachmentStore: AttachmentSessionStore { store.attachments }

    /// Any context waiting for the next question takes precedence over
    /// copying the previous answer when the composer is empty.
    var hasPendingChatContext: Bool { hasPendingAttachment || launchSelection != nil }

    // MARK: - Add Context

    /// Finder is the app behind the overlay, so Add Context lists Finder
    /// Selection.
    var isFinderBehind: Bool {
        selectionTarget?.applicationName == Self.finderApplicationName
    }

    static let finderApplicationName = "Finder"

    /// The Add Context menu in order, for the surface: the captures this
    /// surface offers, File…, Link…, and Finder Selection when Finder is
    /// behind. Before the pane's own search filter.
    var addContextAllRows: [AddContextRow] {
        AddContextRow.menu(captures: addContextOptions, finderIsBehind: isFinderBehind)
    }

    /// The rows after the pane's own search filter, best match first. Typing
    /// there narrows this list; the composer draft is never touched. The
    /// highlight always indexes this list, so the keys and the drawn rows
    /// agree.
    var addContextRows: [AddContextRow] {
        guard !addContextQuery.isEmpty else { return addContextAllRows }
        return Self.rankByQuery(addContextAllRows, query: addContextQuery, title: \.title)
    }

    /// One Add Context row, from a click or Return.
    func runAddContextRow(_ row: AddContextRow) {
        switch row {
        case .capture(let entry):
            addContextTask = Task { @MainActor [weak self] in
                await self?.addContext(entry)
                self?.addContextTask = nil
            }
        case .file:
            addContextTask = Task { @MainActor [weak self] in
                await self?.chooseAttachmentFiles()
                self?.addContextTask = nil
            }
        case .link:
            // The pane turns into the Link field, prefilled with a link on
            // the clipboard. Reading the pasteboard never writes it.
            attachmentTray.beginLinkEntry(clipboard: pasteboard.readString())
            errorMessage = nil
        case .finderSelection:
            closeAddContextMenu()
            attachFinderSelection()
        }
    }

    /// `↩` in the Link field: the link becomes a chip and the menu closes.
    func submitAttachmentLink() {
        if attachmentTray.submitLinkEntry() { closeAddContextMenu() }
    }

    /// File…: the open panel, then a chip per file. The window (or the
    /// launcher panel) steps aside for the panel through the external-action
    /// seams and comes back with what was typed and the chips already there.
    func chooseAttachmentFiles() async {
        isAddContextMenuPresented = false
        attachmentTray.cancelLinkEntry()
        guard let attachmentFilePicker else {
            errorMessage = "Choosing files is not available here."
            requestInputFocus()
            return
        }
        let typed = input
        // Hiding the launcher may clear its surface; the chips wait here.
        let kept = attachmentTray.handOff()
        prepareForExternalAction?()
        let urls = await attachmentFilePicker.chooseFiles(allowedExtensions: AttachmentTray.openPanelFileExtensions)
        attachmentTray.adopt(kept)
        if urls.isEmpty {
            recoverFromExternalActionFailure?()
        } else {
            attachmentTray.add(contentsOf: urls.map(AttachmentSource.file))
            overlayPresenter.restoreAfterExternalAction()
        }
        if input.isEmpty, !typed.isEmpty { input = typed }
        requestInputFocus()
    }

    /// Finder Selection: the files selected in the Finder window behind the
    /// overlay, at most 20, each read as a chip.
    func attachFinderSelection() {
        guard let target = selectionTarget, isFinderBehind, let screenAwareness else {
            errorMessage = "Finder Selection needs a Finder window behind Quick Launch."
            requestInputFocus()
            return
        }
        let paths = screenAwareness.readContext(for: target).selectedFilePaths
        guard !paths.isEmpty else {
            errorMessage = "Nothing is selected in Finder."
            requestInputFocus()
            return
        }
        errorMessage = nil
        attachmentTray.add(contentsOf: paths.prefix(AttachmentLimits.finderSelectionFiles).map {
            AttachmentSource.file(URL(fileURLWithPath: $0))
        })
        requestInputFocus()
    }

    // MARK: - Sending

    /// A send waits for chips still reading, with "Reading report.pdf…" as
    /// the status line; Escape (`cancel()`) stops the reads and keeps the
    /// typed text. Returns false when the wait was cancelled.
    func waitForReadingAttachments() async -> Bool {
        if attachmentTray.isReading {
            isWaitingForAttachments = true
            isStreaming = true
            streamingStatus = attachmentTray.readingStatusLine
            await attachmentTray.waitUntilRead()
            let cancelled = !isWaitingForAttachments || Task.isCancelled
            isWaitingForAttachments = false
            guard !cancelled else { return false }
            isStreaming = false
            streamingStatus = nil
        }
        // A failed chip stays visible until the user retries or removes it.
        // Never silently send a question with one of its attachments missing.
        if let failed = attachmentTray.items.first(where: \.isFailed) {
            errorMessage = "Could not read \(failed.name). Retry or remove it before sending."
            requestInputFocus()
            return false
        }
        return true
    }

    /// Escape while a send waits for its chips.
    func cancelAttachmentWait() {
        guard isWaitingForAttachments else { return }
        isWaitingForAttachments = false
        attachmentTray.cancelReading()
    }

    /// What the next question carries: the screenshots and pictures the
    /// view model holds, then the chips that were read, in the order added.
    func pendingAttachmentContents() -> [AttachmentContent] {
        let screenshots = pendingImages.enumerated().map { index, image in
            AttachmentExtractor.imageContent(
                image,
                name: pendingImages.count > 1 ? "Screenshot \(index + 1)" : "Screenshot",
                kind: .screenshot
            )
        }
        return screenshots + attachmentTray.readyContents
    }

    /// A page read for a URL typed in the question, kept as a Link
    /// attachment of that message so follow-ups still have it.
    static func pageAttachment(url: URL, text: String) -> AttachmentContent {
        let ref = ChatAttachmentRef(
            kind: .link,
            name: url.host() ?? url.absoluteString,
            byteCount: text.utf8.count,
            characterCount: text.count,
            contentHash: AttachmentExtractor.sha256(Data(text.utf8)),
            extractorVersion: AttachmentExtractor.version,
            url: url
        )
        return AttachmentContent(ref: ref, text: text, kindLabel: "Web page")
    }

    /// Whether an image can go to a vision model: one is chosen with a
    /// model, and a cloud one has its key. Otherwise images are read as text
    /// on this Mac (OCR) and the chat's own model answers.
    var visionRouteWorks: Bool {
        guard let visionProvider, !visionModelName.isEmpty else { return false }
        if service == nil, visionProvider.kind == .openAICompatible, visionProvider.location == .cloud,
           (apiKeyProvider(visionProvider.id) ?? "").isEmpty {
            return false
        }
        return true
    }

    /// No vision route: use existing OCR text, or read current/session pixels
    /// locally. Reference-only retries use the same fallback as new images.
    func readImagesAsText(_ contents: [AttachmentContent]) async -> [AttachmentContent] {
        var result: [AttachmentContent] = []
        for var content in contents {
            guard !Task.isCancelled else { return result }
            if content.ref.kind.isImage {
                if content.text == nil, let stored = attachmentStore.text(for: content.ref) {
                    content.text = stored.text
                    content.kindLabel = stored.kindLabel
                    content.notes = stored.notes
                }
                if content.text == nil,
                   let image = content.image ?? attachmentStore.image(for: content.ref) {
                    streamingStatus = "Reading text from \(content.ref.name) on this Mac…"
                    let text = await recognizeImageText(image.data)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Task.isCancelled else { return result }
                    content.text = text.isEmpty ? "(No text was found in the image.)" : text
                    content.kindLabel = "Text read from the image on this Mac"
                }
                content.image = nil
            }
            result.append(content)
        }
        streamingStatus = nil
        return result
    }

    /// Older turns may have been sent through vision before that route became
    /// unavailable. OCR their session pixels once; missing pixels remain missing
    /// so the request composer can name them instead of silently dropping them.
    func cacheImageText(for references: [ChatAttachmentRef]) async {
        for ref in references where ref.kind.isImage {
            guard !Task.isCancelled else { return }
            guard attachmentStore.text(for: ref) == nil else { continue }
            let contents = await readImagesAsText([AttachmentContent(ref: ref)])
            guard !Task.isCancelled else { return }
            for content in contents where content.text != nil { attachmentStore.store(content) }
        }
    }

    /// Each user turn's pictures, by message id, from the session store.
    func turnImages(for messages: [QuickMessage]) -> [UUID: [QuickImageAttachment]] {
        var images: [UUID: [QuickImageAttachment]] = [:]
        for message in messages where message.role == .user {
            let found = message.attachmentRefs.filter(\.kind.isImage).compactMap { attachmentStore.image(for: $0) }
            if !found.isEmpty { images[message.id] = found }
        }
        return images
    }

    /// The budget attachments are fitted into for `provider`'s model. A
    /// command-line provider reads the prompt on stdin and gets no budget;
    /// the hard caps still hold.
    func attachmentContextBudget(provider: InferenceProvider, model: String) -> ContextBudget {
        guard provider.kind == .openAICompatible else { return .unlimited }
        return ContextBudget(contextWindow: modelPreferences.profile(providerID: provider.id, model: model).contextWindow)
    }

    // MARK: - The strip's routing line

    /// Where the attachments go, at the strip's end: the vision note for
    /// pictures ("Sent to DeepSeek API", or "Sent as text (read on this
    /// Mac)" with no vision route), "Only on this Mac" or "Sent to …" for
    /// documents, and "Will be cut to fit …" when they are over the share.
    var attachmentRoutingLine: String? {
        let live = attachmentTray.items.filter { !$0.isFailed }
        let hasImage = !pendingImages.isEmpty || live.contains { $0.kind.isImage }
        if hasImage {
            return visionRouteWorks
                ? visionRoutingNote.replacingOccurrences(of: "Sent ", with: "Will send ")
                : Self.pendingImageAsTextLine
        }
        guard !live.isEmpty, let provider = activeProvider else { return nil }
        let model = resolvedModel(for: provider, override: chatModelOverride(for: provider)) ?? ""
        let budget = attachmentContextBudget(provider: provider, model: model)
        let share = AttachmentRequestComposer.share(
            characterLimit: budget.characterLimit,
            reserved: input.utf8.count + settings.systemPrompt.utf8.count
        )
        let characters = attachmentTray.readyContents.compactMap(\.text).reduce(0) { $0 + $1.utf8.count }
        if characters > share { return "Will be cut to fit \(provider.name)" }
        return provider.location == .local ? "Only on this Mac" : "Will send to \(provider.name)"
    }

    static let pendingImageAsTextLine = "Will send as text (read on this Mac)"
    static let imageAsTextLine = "Sent as text (read on this Mac)"

    // MARK: - Chips on sent questions

    /// A sent question's chips: ready while this session holds the text (or
    /// the picture); "Not loaded" after a relaunch, "Image not kept" for a
    /// picture; "Reading…" while a Re-attach runs.
    func attachmentChips(for message: QuickMessage) -> [AttachmentChipModel] {
        message.attachmentRefs.map(attachmentChip(for:))
    }

    func attachmentChip(for ref: ChatAttachmentRef) -> AttachmentChipModel {
        var chip = AttachmentChipModel(ref: ref, imageData: attachmentStore.storedImage(for: ref)?.data)
        if let state = reattachStates[ref.id] {
            chip.phase = state
            return chip
        }
        if ref.kind.isImage {
            if attachmentStore.storedImage(for: ref) != nil { return chip }
            if attachmentStore.isLoaded(ref) {
                chip.detail = Self.imageAsTextLine
                chip.spokenDetail = Self.imageAsTextLine
                return chip
            }
            chip.phase = .notLoaded(Self.imageNotKeptLine)
            return chip
        }
        if !attachmentStore.isLoaded(ref) { chip.phase = .notLoaded(Self.notLoadedLine) }
        return chip
    }

    static let notLoadedLine = "Not loaded"
    static let imageNotKeptLine = "Image not kept"

    /// A chip that can be read again: a file with its path, or a link, whose
    /// text this session does not hold.
    func canReattach(_ ref: ChatAttachmentRef) -> Bool {
        guard !ref.kind.isImage, ref.kind != .selection, ref.path != nil || ref.url != nil else { return false }
        switch reattachStates[ref.id] {
        case .reading?: return false
        case .failed?: return true
        default: return !attachmentStore.isLoaded(ref)
        }
    }

    /// Re-attach on a "Not loaded" chip: the same file is read again, or
    /// the link fetched again, only now that the user chose it. A file that
    /// changed since (its hash differs) is not taken in its place.
    func reattach(_ ref: ChatAttachmentRef) {
        guard canReattach(ref) else { return }
        let source: AttachmentSource
        if ref.kind == .link, let url = ref.url {
            source = .link(url)
        } else if let path = ref.path {
            source = .file(URL(fileURLWithPath: path))
        } else {
            return
        }
        reattachStates[ref.id] = .reading
        let reader = attachmentReader
        reattachTasks[ref.id] = Task { @MainActor [weak self] in
            let result: Result<AttachmentContent, Error>
            do {
                result = .success(try await reader.content(for: source))
            } catch {
                result = .failure(error)
            }
            self?.finishReattach(ref, result: result)
        }
    }

    private func finishReattach(_ ref: ChatAttachmentRef, result: Result<AttachmentContent, Error>) {
        reattachTasks[ref.id] = nil
        switch result {
        case .success(let content):
            if ref.kind != .link, let hash = ref.contentHash, content.ref.contentHash != hash {
                reattachStates[ref.id] = .failed(Self.changedSinceLine)
                return
            }
            guard let text = content.text else {
                reattachStates[ref.id] = .failed(AttachmentFailure.empty.chipLine)
                return
            }
            // Under the sent reference's key: the turn it belongs to reads it.
            attachmentStore.storeText(
                AttachmentSessionStore.Text(text: text, kindLabel: content.kindLabel, notes: content.notes),
                for: ref
            )
            reattachStates[ref.id] = nil
        case .failure(let error):
            let line = (error as? AttachmentReadFailure)?.line ?? error.localizedDescription
            reattachStates[ref.id] = .failed(line)
        }
    }

    static let changedSinceLine = "Changed since it was attached; attach it again"

    /// Open on a sent chip: a link in the browser. A file opens in Quick
    /// Look from the view; the view model only says where it is.
    func openAttachment(_ ref: ChatAttachmentRef) {
        if ref.kind == .link, let url = ref.url {
            workspace.open(url)
        }
    }

    /// The file behind a sent chip, when it is still on this Mac.
    func attachmentFileURL(_ ref: ChatAttachmentRef) -> URL? {
        guard let path = ref.path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Letting go

    /// A deleted chat's attachment text goes from memory unless another
    /// chat (or the one on screen) still names it.
    func forgetAttachments(of deleted: [QuickConversation]) {
        let refs = deleted.flatMap { $0.messages.flatMap(\.attachmentRefs) }
        guard !refs.isEmpty else { return }
        let deletedIDs = Set(deleted.map(\.id))
        var kept = history.filter { !deletedIDs.contains($0.id) }.flatMap { $0.messages.flatMap(\.attachmentRefs) }
        if let open = currentConversation, !deletedIDs.contains(open.id) {
            kept += open.messages.flatMap(\.attachmentRefs)
        }
        for view in store.views(besides: self) {
            if let open = view.currentConversation, !deletedIDs.contains(open.id) {
                kept += open.messages.flatMap(\.attachmentRefs)
            }
        }
        attachmentStore.remove(refs, keeping: kept)
    }
}
