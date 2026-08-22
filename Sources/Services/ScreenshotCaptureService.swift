import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What a screenshot command captures.
enum ScreenshotKind: String, CaseIterable, Sendable {
    /// The focused window of the app that was in front before Quick Launch.
    case window
    /// The whole display under the mouse pointer, minus Quick Launch itself.
    case display

    static let commandPrefix = "screenshot."

    var commandID: String { Self.commandPrefix + rawValue }

    init?(commandID: String) {
        guard commandID.hasPrefix(Self.commandPrefix) else { return nil }
        self.init(rawValue: String(commandID.dropFirst(Self.commandPrefix.count)))
    }

    var title: String {
        switch self {
        case .window: "Send Focused Window to AI"
        case .display: "Send Screen to AI"
        }
    }

    var detail: String {
        switch self {
        case .window: "Screenshot plus the app's title, selection, and readable text"
        case .display: "A screenshot of this display, then ask about it"
        }
    }

    var systemImage: String {
        switch self {
        case .window: "macwindow.on.rectangle"
        case .display: "rectangle.dashed.badge.record"
        }
    }

    /// Shortcut inside the open overlay.
    var overlayKeyCaps: [String] {
        switch self {
        case .window: ["⌘", "⇧", "S"]
        case .display: ["⌘", "⇧", "D"]
        }
    }
}

enum ScreenshotCaptureError: LocalizedError, Equatable {
    case notAuthorized
    case noPreviousApp
    case noWindow(String)
    case noDisplay
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Allow Quick Launch under Privacy & Security › Screen & System Audio Recording, then try again."
        case .noPreviousApp:
            "No app window was behind Quick Launch. Switch to the app first, then open Quick Launch."
        case .noWindow(let name):
            "\(name) has no window on screen to capture."
        case .noDisplay:
            "Could not find the display under the pointer."
        case .encodingFailed:
            "The screenshot could not be encoded."
        }
    }
}

@MainActor
protocol ScreenshotCapturing: AnyObject {
    var isScreenRecordingAuthorized: Bool { get }
    /// Captures `kind`. `target` is the app behind Quick Launch; `ownProcess`
    /// is excluded from display captures so the overlay never appears in its
    /// own screenshot.
    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment
}

/// ScreenCaptureKit-backed capture. Images stay in memory as one attachment;
/// nothing is written to disk.
@MainActor
final class ScreenshotCaptureService: ScreenshotCapturing {
    /// Long-edge cap in pixels. Keeps cloud vision requests fast and cheap
    /// while leaving text readable.
    static let maximumLongEdge: CGFloat = 2_560

    var isScreenRecordingAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt once and adds the app to the list.
            _ = CGRequestScreenCaptureAccess()
            throw ScreenshotCaptureError.notAuthorized
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        switch kind {
        case .window:
            guard let target else { throw ScreenshotCaptureError.noPreviousApp }
            guard let window = Self.frontWindow(of: target.processIdentifier, in: content.windows) else {
                throw ScreenshotCaptureError.noWindow(target.applicationName)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display:
            guard let display = Self.displayUnderPointer(in: content.displays) else {
                throw ScreenshotCaptureError.noDisplay
            }
            let own = content.windows.filter { $0.owningApplication?.processID == ownProcess }
            filter = SCContentFilter(display: display, excludingWindows: own)
        }

        let configuration = SCStreamConfiguration()
        let points = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = CGSize(width: points.width * scale, height: points.height * scale)
        let fit = min(1, Self.maximumLongEdge / max(pixels.width, pixels.height, 1))
        configuration.width = max(1, Int(pixels.width * fit))
        configuration.height = max(1, Int(pixels.height * fit))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return try Self.attachment(from: image)
    }

    /// The topmost normal window that belongs to `pid`.
    static func frontWindow(of pid: pid_t, in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 40
                && window.frame.height > 40
        }
        // ScreenCaptureKit lists windows front to back. Fall back to the
        // largest window when ordering is not what we expect.
        return candidates.first ?? windows
            .filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func displayUnderPointer(in displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return displays.first }
        return displays.first { $0.displayID == number.uint32Value } ?? displays.first
    }

    static func attachment(from image: CGImage) throws -> QuickImageAttachment {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
              !png.isEmpty,
              png.count <= ClipboardImageReader.maximumBytes
        else { throw ScreenshotCaptureError.encodingFailed }
        return QuickImageAttachment(
            data: png,
            mimeType: "image/png",
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
