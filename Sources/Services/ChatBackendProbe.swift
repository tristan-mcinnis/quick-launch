import AppKit
import Foundation

/// The live `ChatBackendProbing`. tmux, pi, and recall are found the way
/// Continue in pi and the Memory tool find them (`ExecutableResolver`:
/// `~/.local/bin`, `/opt/homebrew/bin`, and the other usual folders, then
/// `PATH`); Ghostty by the bundle identifier the hand-off opens.
///
/// An actor, so every lookup runs on its executor, off the main thread.
actor ChatBackendProbe: ChatBackendProbing {
    typealias Resolve = @Sendable (_ name: String) -> URL?
    typealias ApplicationLookup = @Sendable (_ bundleIdentifier: String) -> URL?

    private let resolve: Resolve
    private let applicationURL: ApplicationLookup

    init(
        resolve: @escaping Resolve = { ExecutableResolver.resolve($0) },
        applicationURL: @escaping ApplicationLookup = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.resolve = resolve
        self.applicationURL = applicationURL
    }

    func probe() async -> ChatBackendStatus {
        ChatBackendStatus(
            tmuxFound: resolve("tmux") != nil,
            piFound: resolve("pi") != nil,
            ghosttyFound: applicationURL(PiHandoffService.ghosttyBundleIdentifier) != nil,
            recallFound: resolve("recall") != nil
        )
    }
}
