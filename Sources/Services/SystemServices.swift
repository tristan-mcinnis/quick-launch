import AppKit
import Foundation

// AppKit implementations of the seams in `Sources/Protocols/SystemServicing.swift`.
// `QuickViewModel.init` installs these by default; tests inject fakes.

@MainActor
final class SystemPasteboard: PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func readString() -> String? {
        pasteboard.string(forType: .string)
    }

    func writeString(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

@MainActor
final class SystemWorkspace: WorkspaceOpening {
    init() {}

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL, activating: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    func revealInFileViewer(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }
}

extension NSRunningApplication: RunningApplicationControlling {}

@MainActor
final class SystemRunningApplications: RunningApplicationsQuerying {
    init() {}

    func isTerminated(processIdentifier: pid_t) -> Bool? {
        NSRunningApplication(processIdentifier: processIdentifier)?.isTerminated
    }

    func runningApplication(bundleIdentifier: String?, bundleURL: URL) -> (any RunningApplicationControlling)? {
        if let bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            return running
        }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL == bundleURL }
    }
}

@MainActor
final class SystemScreenGeometry: ScreenGeometryProviding {
    init() {}

    var screenCount: Int { NSScreen.screens.count }
}
