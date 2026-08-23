import AppKit
import ApplicationServices
import Foundation

/// Everything Quick Launch can read about the window behind it, gathered
/// piece by piece so a capture still works when some pieces are missing.
struct CaptureContext: Equatable, Sendable {
    var appName: String
    var windowTitle: String?
    var selectedText: String?
    var focusedValue: String?
    var appText: String?
    var pageURL: String?
    /// Finder frontmost: paths highlighted in the front window, bounded to 20.
    var selectedFilePaths: [String] = []
    var hasScreenshot: Bool = false

    /// Human list for the attachment card: "Screenshot, App content, Selection".
    var includedSources: [String] {
        var list: [String] = []
        if hasScreenshot { list.append("Screenshot") }
        if pageURL != nil { list.append("Page") }
        if appText?.isEmpty == false { list.append("App content") }
        if focusedValue?.isEmpty == false { list.append("Focused field") }
        if selectedText?.isEmpty == false { list.append("Selection") }
        if !selectedFilePaths.isEmpty { list.append("Files") }
        return list
    }

    var captureTypeTitle: String {
        let hasText = (appText?.isEmpty == false) || (selectedText?.isEmpty == false) || (focusedValue?.isEmpty == false)
            || !selectedFilePaths.isEmpty
        switch (hasScreenshot, hasText) {
        case (true, true): return "Screenshot + App Content"
        case (true, false): return "Screenshot"
        case (false, true): return "App Content"
        case (false, false): return "Window Metadata"
        }
    }

    /// Text block placed before the question so a text-only model still
    /// knows what the user is looking at. Bounded so it never swamps the prompt.
    func promptPreamble(limit: Int = 6_000) -> String {
        var lines: [String] = []
        var header = "Context from \(appName)"
        if let windowTitle, !windowTitle.isEmpty { header += " (window: \(windowTitle))" }
        if let pageURL, !pageURL.isEmpty { header += ", page: \(pageURL)" }
        lines.append(header + ".")
        if let selectedText, !selectedText.isEmpty {
            lines.append("Selected text:\n\(selectedText)")
        }
        if let focusedValue, !focusedValue.isEmpty, focusedValue != selectedText {
            lines.append("Focused field:\n\(focusedValue)")
        }
        if !selectedFilePaths.isEmpty {
            lines.append("Selected files:\n" + selectedFilePaths.joined(separator: "\n"))
        }
        if let appText, !appText.isEmpty {
            lines.append("Readable text in the window:\n\(appText)")
        }
        var joined = lines.joined(separator: "\n\n")
        if joined.count > limit {
            joined = String(joined.prefix(limit)) + "…"
        }
        return joined
    }
}

@MainActor
protocol ScreenAwarenessReading: AnyObject {
    /// Reads the focused window of `target` through Accessibility.
    func readContext(for target: SelectionTarget) -> CaptureContext
    /// Lets the user drag out a screen area; returns the image or nil when cancelled.
    func captureArea() async -> QuickImageAttachment?
}

/// Accessibility walk of the focused window: title, selection, focused
/// field, readable static text, and the page URL when a web area is present.
@MainActor
final class ScreenAwarenessService: ScreenAwarenessReading {
    static let maximumAppText = 4_000
    static let maximumElements = 400
    static let maximumDepth = 8

    func readContext(for target: SelectionTarget) -> CaptureContext {
        var context = CaptureContext(appName: target.applicationName)
        guard AXIsProcessTrusted() else { return context }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        guard let window = element(application, kAXFocusedWindowAttribute) else { return context }
        context.windowTitle = string(window, kAXTitleAttribute)

        if let focused = element(application, kAXFocusedUIElementAttribute) {
            context.selectedText = string(focused, kAXSelectedTextAttribute)?.nilIfBlank
            if let value = string(focused, kAXValueAttribute)?.nilIfBlank, value.count <= 2_000 {
                context.focusedValue = value
            }
        }

        var collected: [String] = []
        var total = 0
        var visited = 0
        var url: String?
        walk(window, depth: 0, visited: &visited) { node, role in
            if url == nil, role == "AXWebArea" {
                url = string(node, "AXURL") ?? (attribute(node, "AXURL") as? URL)?.absoluteString
            }
            guard total < Self.maximumAppText else { return }
            guard ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton"].contains(role) else { return }
            let text = (string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) ?? string(node, kAXDescriptionAttribute))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.count > 1, !collected.contains(text) else { return }
            collected.append(text)
            total += text.count + 1
        }
        context.pageURL = url
        if !collected.isEmpty {
            context.appText = String(collected.joined(separator: "\n").prefix(Self.maximumAppText))
        }
        if target.applicationName == "Finder" {
            context.selectedFilePaths = Self.finderSelectedFilePaths(window: window)
        }
        return context
    }

    /// The rows highlighted in a Finder list, gallery, or icon view, as file
    /// paths. Bounded to 20 so a Select All cannot flood the prompt.
    static func finderSelectedFilePaths(window: AXUIElement) -> [String] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXSelectedRowsAttribute as CFString,
            &raw
        ) == .success, let rows = raw as? [AXUIElement] else { return [] }
        var paths: [String] = []
        for row in rows.prefix(20) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(row, "AXURL" as CFString, &value) == .success,
                  let url = value as? URL ?? (value as? NSURL)?.absoluteURL
            else { continue }
            paths.append(url.path)
        }
        return paths
    }

    /// The system tool draws the selection rectangle; the file is read and
    /// deleted right away so nothing lingers on disk.
    func captureArea() async -> QuickImageAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-area-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", url.path]
        do {
            try process.run()
        } catch {
            return nil
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return ClipboardImageReader.attachment(data: data, mimeType: "image/png")
    }

    // MARK: Accessibility helpers

    private func walk(_ node: AXUIElement, depth: Int, visited: inout Int, visit: (AXUIElement, String) -> Void) {
        guard depth <= Self.maximumDepth, visited < Self.maximumElements else { return }
        visited += 1
        let role = string(node, kAXRoleAttribute) ?? ""
        visit(node, role)
        guard let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children.prefix(80) {
            walk(child, depth: depth + 1, visited: &visited, visit: visit)
        }
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func string(_ node: AXUIElement, _ name: String) -> String? {
        attribute(node, name) as? String
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// Recognises a double tap of one modifier key (right ⌘ by default) from
/// `flagsChanged` events. Pure state machine; the monitor feeds it.
struct ModifierDoubleTapDetector {
    let keyCode: UInt16
    let window: TimeInterval
    private var lastRelease: TimeInterval?
    private var pressedAt: TimeInterval?
    private var otherKeyDuringPress = false

    init(keyCode: UInt16 = 54, window: TimeInterval = 0.35) {
        self.keyCode = keyCode
        self.window = window
    }

    /// Returns true when this event completes a double tap.
    mutating func handleFlagsChanged(keyCode: UInt16, isDown: Bool, at time: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            otherKeyDuringPress = true
            lastRelease = nil
            return false
        }
        if isDown {
            pressedAt = time
            otherKeyDuringPress = false
            return false
        }
        defer { pressedAt = nil }
        guard !otherKeyDuringPress, let pressedAt, time - pressedAt < window else {
            lastRelease = nil
            return false
        }
        if let lastRelease, time - lastRelease < window {
            self.lastRelease = nil
            return true
        }
        lastRelease = time
        return false
    }

    /// Any ordinary key press cancels a pending tap.
    mutating func handleKeyDown() {
        otherKeyDuringPress = true
        lastRelease = nil
    }
}

/// Watches modifier keys system-wide for the double tap. Needs Accessibility,
/// which Quick Launch already asks for.
@MainActor
final class ModifierDoubleTapMonitor {
    private var detector = ModifierDoubleTapDetector()
    private var monitors: [Any] = []
    var onDoubleTap: (() -> Void)?

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let isDown = event.modifierFlags.contains(.command)
            if self.detector.handleFlagsChanged(keyCode: event.keyCode, isDown: isDown, at: event.timestamp) {
                self.onDoubleTap?()
            }
        }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.detector.handleKeyDown() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(global) }
        if let globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(globalKeys) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in flags(event); return event } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in keys(event); return event } as Any)
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
