import CoreGraphics
import Foundation
import Vision

/// On-device text recognition with Apple Vision, for scanned PDF pages.
///
/// Runs entirely on this Mac. Written against the macOS 14 Vision API
/// (`VNRecognizeTextRequest`), because this module's floor is macOS 14 and the
/// newer Swift Vision request is not available there.
///
/// The blocking `perform` runs on a global queue rather than a detached task,
/// so it cannot outlive the caller as an orphaned task. A cancellation (the
/// caller cancelling, or the read's deadline) aborts the in-flight request
/// through `VNRequest.cancel()`, which is safe to call while `perform` runs.
enum VisionTextRecognizer {
    nonisolated static let languages = ["en-US", "zh-Hans", "zh-Hant"]

    /// Recognizes text in one rendered image. Returns "" when Vision finds
    /// nothing, refuses the image, or the recognition was cancelled; never
    /// throws, so a scanned page that fails OCR falls back to its thin text
    /// layer.
    nonisolated static func recognize(in image: CGImage) async -> String {
        let control = VisionRequestControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if control.isCancelled {
                        continuation.resume(returning: "")
                        return
                    }
                    // Vision's macOS 14 API is synchronous, so the request is
                    // built and performed here, on this queue.
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = languages
                    if #available(macOS 13.0, *) {
                        request.automaticallyDetectsLanguage = true
                    }
                    control.register(request)
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(returning: "")
                        return
                    }
                    let text = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// Guards the single in-flight Vision request so a cancellation on another
/// thread can abort it. `VNRequest.cancel()` is documented as safe to call
/// while `perform` runs; the lock only protects the reference and the
/// cancelled flag.
private final class VisionRequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ request: VNRecognizeTextRequest) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
        if cancelled { request.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        request?.cancel()
    }
}
