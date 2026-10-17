import Foundation

/// How much of a streaming answer is drawn. Text arrives in bursts; drawing
/// it as it lands makes the answer jump. The shown count instead chases the
/// received count on a frame cadence: at least two characters a frame, else
/// a twelfth of the backlog, so a burst eases in and a long backlog catches
/// up fast. A backlog past `snapThreshold` shows at once.
enum StreamReveal {
    static let minimumPerFrame = 2.0
    static let backlogShare = 1.0 / 12.0
    static let snapThreshold = 4_000
    /// One frame at 60 Hz, the unit the rule is stated in.
    static let frame: TimeInterval = 1.0 / 60.0
    /// The most frames one tick may count. The timeline pauses once caught
    /// up, so the first tick after a pause sees the whole idle gap; counting
    /// it would draw a chunk at once. A slow frame still catches up a little.
    static let maxFramesPerTick = 2.0

    /// The shown count after `frames` frames (60 Hz units, fractional when a
    /// frame ran long) of chasing `total`. Never passes `total`.
    static func advance(shown: Int, total: Int, frames: Double) -> Int {
        let remaining = total - shown
        guard remaining > 0 else { return min(shown, total) }
        if remaining > snapThreshold { return total }
        let frames = max(1, frames)
        let floorStep = (minimumPerFrame * frames).rounded(.up)
        let shareStep = (Double(remaining) * (1 - pow(1 - backlogShare, frames))).rounded(.up)
        return shown + min(remaining, Int(max(floorStep, shareStep)))
    }

    /// The prefix of `text` that is `count` UTF-16 units long.
    static func prefix(of text: String, count: Int) -> String {
        guard count < text.utf16.count else { return text }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: max(0, count))
        return String(text[..<index])
    }
}

/// The running shown count for one streaming answer. A reference type the
/// frame callback advances without invalidating the view.
@MainActor
final class RevealClock {
    private(set) var shown: Int?
    private var lastFrame: Date?

    /// The count to draw at `now` for an answer `total` long. The first sight
    /// of an answer draws what has arrived (a view built mid-stream does not
    /// replay it); shrinking text restarts.
    func visible(total: Int, now: Date) -> Int {
        guard var current = shown, current <= total else {
            shown = total
            lastFrame = now
            return total
        }
        let elapsed = lastFrame.map { now.timeIntervalSince($0) } ?? StreamReveal.frame
        lastFrame = now
        current = StreamReveal.advance(shown: current, total: total, frames: min(elapsed / StreamReveal.frame, StreamReveal.maxFramesPerTick))
        shown = current
        return current
    }

    func reset() {
        shown = nil
        lastFrame = nil
    }
}
