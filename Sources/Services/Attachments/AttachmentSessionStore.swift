import Foundation
import Observation

/// Where attachment text lives: in memory, for this app session only.
///
/// When the user attaches a file, a link, or a selection, its extracted
/// text is kept here, keyed by the reference's content hash, so every later
/// turn of the chat can send it again without a re-attach. Chat history
/// keeps only the `ChatAttachmentRef` (name, kind, size, hash, path or
/// URL), never the text. Nothing here is written to disk: after a relaunch
/// an old attachment's chip reads "Not loaded", and the file is read again
/// (or the link fetched again) only when the user chooses Re-attach.
///
/// Images and screenshots are kept here too, by reference id, so a
/// follow-up sends each image with its own turn; they are gone at quit,
/// as the contract says.
///
/// Bounded: past `characterLimit` of text (or `imageByteLimit` of images)
/// the least recently used entry goes first. One store per app, shared by
/// the launcher and the AI Chat window through `QuickStore`, since both
/// show the same chats.
@MainActor
@Observable
final class AttachmentSessionStore {
    /// The disk cache (`AttachmentTextCache`, spec section 3.8) is built
    /// and tested but off. Keeping extracted text on disk needs the
    /// contract change in spec section 3.9, which Tristan has not approved.
    /// This is the one switch: not a setting, and nothing turns it on at
    /// run time. Turning it on means wiring the cache at the three points
    /// section 3.8 names (store on send, read on a miss, clear with the
    /// history), after the contract text is approved.
    static let attachmentCacheEnabled = false

    /// One attachment's text as the request needs it.
    struct Text: Equatable, Sendable {
        var text: String
        /// "PDF", "Swift source"; nil means the kind's own name.
        var kindLabel: String?
        var notes: [AttachmentNote]
    }

    let characterLimit: Int
    let imageByteLimit: Int

    private var texts: [String: Text] = [:]
    private var images: [UUID: QuickImageAttachment] = [:]
    /// Least recently used first. Not observed: touching an entry must
    /// never redraw a chip.
    @ObservationIgnored private var textOrder: [String] = []
    @ObservationIgnored private var imageOrder: [UUID] = []
    @ObservationIgnored private(set) var characterCount = 0
    @ObservationIgnored private(set) var imageByteCount = 0

    init(
        characterLimit: Int = AttachmentLimits.sessionTextCharacters,
        imageByteLimit: Int = AttachmentLimits.sessionImageBytes
    ) {
        self.characterLimit = characterLimit
        self.imageByteLimit = imageByteLimit
    }

    // MARK: - Keys

    /// The key a reference's text is kept under: its content hash and
    /// extractor version, so the same file attached twice shares one entry.
    /// A reference without a hash (a selection or a page read before
    /// hashing) uses its id. Images have no text key.
    static func key(for ref: ChatAttachmentRef) -> String {
        if let hash = ref.contentHash {
            return "\(hash)-v\(ref.extractorVersion ?? 0)"
        }
        return "id:\(ref.id.uuidString)"
    }

    // MARK: - Text

    /// Keeps what reading one source gave: its text, or its image.
    func store(_ content: AttachmentContent) {
        if let image = content.image {
            storeImage(image, for: content.ref)
        }
        if let text = content.text {
            storeText(Text(text: text, kindLabel: content.kindLabel, notes: content.notes), for: content.ref)
        }
    }

    func storeText(_ text: Text, for ref: ChatAttachmentRef) {
        let key = Self.key(for: ref)
        if let old = texts[key] { characterCount -= old.text.count }
        texts[key] = text
        characterCount += text.text.count
        touchText(key)
        evictText(keeping: key)
    }

    /// The text for `ref`, or nil when this session never read it (or let
    /// it go). A read counts as a use.
    func text(for ref: ChatAttachmentRef) -> Text? {
        let key = Self.key(for: ref)
        guard let text = texts[key] else { return nil }
        touchText(key)
        return text
    }

    /// Whether `ref` can ride a request now: its text (or its image) is in
    /// memory. Not a use.
    func isLoaded(_ ref: ChatAttachmentRef) -> Bool {
        if ref.kind.isImage { return images[ref.id] != nil || texts[Self.key(for: ref)] != nil }
        return texts[Self.key(for: ref)] != nil
    }

    // MARK: - Images

    func storeImage(_ image: QuickImageAttachment, for ref: ChatAttachmentRef) {
        if let old = images[ref.id] { imageByteCount -= old.data.count }
        images[ref.id] = image
        imageByteCount += image.data.count
        imageOrder.removeAll { $0 == ref.id }
        imageOrder.append(ref.id)
        while imageByteCount > imageByteLimit, imageOrder.count > 1, let oldest = imageOrder.first {
            imageOrder.removeFirst()
            if let dropped = images.removeValue(forKey: oldest) { imageByteCount -= dropped.data.count }
        }
    }

    /// The image `ref` names, for a chip's thumbnail. Not a use.
    func storedImage(for ref: ChatAttachmentRef) -> QuickImageAttachment? {
        ref.kind.isImage ? images[ref.id] : nil
    }

    /// The image `ref` names, while this session still holds it.
    func image(for ref: ChatAttachmentRef) -> QuickImageAttachment? {
        guard ref.kind.isImage, let image = images[ref.id] else { return nil }
        imageOrder.removeAll { $0 == ref.id }
        imageOrder.append(ref.id)
        return image
    }

    // MARK: - Letting go

    /// Clear History: every text and image goes.
    func removeAll() {
        texts.removeAll()
        images.removeAll()
        textOrder.removeAll()
        imageOrder.removeAll()
        characterCount = 0
        imageByteCount = 0
    }

    /// A chat was deleted: its attachments go unless another chat still
    /// names them.
    func remove(_ deleted: [ChatAttachmentRef], keeping stillReferenced: [ChatAttachmentRef]) {
        let keptKeys = Set(stillReferenced.filter { !$0.kind.isImage }.map(Self.key(for:)))
        let keptImages = Set(stillReferenced.filter(\.kind.isImage).map(\.id))
        for ref in deleted {
            if ref.kind.isImage {
                guard !keptImages.contains(ref.id), let image = images.removeValue(forKey: ref.id) else { continue }
                imageByteCount -= image.data.count
                imageOrder.removeAll { $0 == ref.id }
            }
            let key = Self.key(for: ref)
            guard !keptKeys.contains(key), let text = texts.removeValue(forKey: key) else { continue }
            characterCount -= text.text.count
            textOrder.removeAll { $0 == key }
        }
    }

    /// Every text key held, for tests and the privacy check.
    var textKeys: Set<String> { Set(texts.keys) }
    var imageCount: Int { images.count }

    // MARK: - Bound

    private func touchText(_ key: String) {
        textOrder.removeAll { $0 == key }
        textOrder.append(key)
    }

    /// Drops the least recently used text until the total fits; the entry
    /// just stored stays even when it alone is over.
    private func evictText(keeping kept: String) {
        var index = 0
        while characterCount > characterLimit, index < textOrder.count {
            let key = textOrder[index]
            guard key != kept else {
                index += 1
                continue
            }
            textOrder.remove(at: index)
            if let dropped = texts.removeValue(forKey: key) { characterCount -= dropped.text.count }
        }
    }
}
