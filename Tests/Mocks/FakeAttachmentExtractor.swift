import Foundation
@testable import QuickLaunch

/// A reader for `AttachmentTray` tests: it reads nothing. Each source gets
/// a made-up reference unless a test sets an outcome for it, and a held
/// source stays "Reading…" until the test releases it or the read is
/// cancelled.
actor FakeAttachmentExtractor: AttachmentExtracting {
    enum Outcome: Sendable {
        case content(AttachmentContent)
        case failure(String)
        /// Never finishes; only a cancel or the tray's timeout ends it.
        case hang
    }

    private var outcomes: [String: Outcome] = [:]
    private var held: Set<String> = []
    private(set) var requested: [String] = []
    private(set) var cancelled: [String] = []

    /// The key a test names a source by: a file's name, a link's URL, an
    /// image's name, or "selection".
    static func key(for source: AttachmentSource) -> String {
        switch source {
        case .file(let url): url.lastPathComponent
        case .link(let url): url.absoluteString
        case .image(_, let name, _): name
        case .selection: "selection"
        }
    }

    func set(_ outcome: Outcome, for key: String) {
        outcomes[key] = outcome
    }

    func hold(_ key: String) {
        held.insert(key)
    }

    func release(_ key: String) {
        held.remove(key)
    }

    func content(for source: AttachmentSource) async throws -> AttachmentContent {
        let key = Self.key(for: source)
        requested.append(key)
        do {
            while held.contains(key) {
                try await Task.sleep(for: .milliseconds(5))
            }
            switch outcomes[key] {
            case .content(let content):
                return content
            case .failure(let line):
                throw AttachmentReadFailure(line)
            case .hang:
                try await Task.sleep(for: .seconds(3_600))
                throw AttachmentReadFailure("unreachable")
            case nil:
                return Self.madeUpContent(for: source)
            }
        } catch is CancellationError {
            cancelled.append(key)
            throw CancellationError()
        }
    }

    static func madeUpContent(for source: AttachmentSource) -> AttachmentContent {
        switch source {
        case .file(let url):
            let kind = ChatAttachmentKind.guess(forFileAt: url)
            return AttachmentContent(
                ref: ChatAttachmentRef(
                    kind: kind,
                    name: url.lastPathComponent,
                    byteCount: 18_000,
                    characterCount: kind.isImage ? nil : 1_200,
                    contentHash: kind.isImage ? nil : String(repeating: "0f", count: 32),
                    extractorVersion: 1,
                    path: url.path,
                    pixelWidth: kind.isImage ? 640 : nil,
                    pixelHeight: kind.isImage ? 480 : nil
                ),
                text: kind.isImage ? nil : "Text of \(url.lastPathComponent)."
            )
        case .link(let url):
            return AttachmentContent(
                ref: ChatAttachmentRef(
                    kind: .link,
                    name: url.host() ?? url.absoluteString,
                    characterCount: 900,
                    url: url
                ),
                text: "Text of \(url.absoluteString)."
            )
        case .image(let image, let name, let kind):
            return AttachmentContent(
                ref: ChatAttachmentRef(
                    kind: kind,
                    name: name,
                    pixelWidth: image.pixelWidth,
                    pixelHeight: image.pixelHeight
                ),
                image: image
            )
        case .selection(let text, let appName):
            return AttachmentContent(
                ref: ChatAttachmentRef(
                    kind: .selection,
                    name: appName.map { "Selection · \($0)" } ?? "Selection",
                    characterCount: text.count
                ),
                text: text
            )
        }
    }
}
