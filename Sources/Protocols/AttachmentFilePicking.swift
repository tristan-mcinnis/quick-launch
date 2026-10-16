import AppKit
import UniformTypeIdentifiers

/// Add Context › File…: asks the user for files to attach. The app's own is
/// `SystemAttachmentFilePicker` (an open panel); tests pass a fake, so no
/// panel ever opens. An empty answer means the user cancelled.
@MainActor
protocol AttachmentFilePicking: AnyObject {
    func chooseFiles(allowedExtensions: [String]) async -> [URL]
    /// A save panel for exporting a clipboard payload to a file the user
    /// picks. Nil when the user cancels, or when this picker has no save
    /// path. Default nil so existing fakes still compile.
    func chooseExportDestination(suggestedName: String, allowedExtensions: [String]) async -> URL?
}

extension AttachmentFilePicking {
    func chooseExportDestination(suggestedName: String, allowedExtensions: [String]) async -> URL? { nil }
}

/// The open panel: several files at once, files only, section 3.3's types.
/// A file chosen here needs no macOS files prompt, since the user picked it.
@MainActor
final class SystemAttachmentFilePicker: AttachmentFilePicking {
    func chooseFiles(allowedExtensions: [String]) async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to your question."
        // The launcher is a menu-bar app: it comes forward so the panel has
        // the keyboard.
        NSApp.activate()
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls : []
    }

    func chooseExportDestination(suggestedName: String, allowedExtensions: [String]) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if !allowedExtensions.isEmpty {
            panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        panel.prompt = "Save"
        panel.message = "Save this clipboard item as a file."
        NSApp.activate()
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
