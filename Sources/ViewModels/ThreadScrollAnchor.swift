import CoreGraphics
import Foundation

/// Where a chat's thread was left: the message at the top of the view and how
/// far below that message's head the view's top sat. A message and an offset,
/// not a y position, so the lazy thread's re-estimated heights do not move it.
struct ThreadScrollAnchor: Equatable, Sendable {
    let messageID: UUID
    let offset: CGFloat

    /// The anchor for a view whose top is at `viewTop`: the last laid-out
    /// message that starts at or above it, in thread order. Nil when no
    /// message has a known top yet, so a thread that has not laid out records
    /// nothing.
    static func make(viewTop: CGFloat, order: [UUID], tops: [UUID: CGFloat]) -> ThreadScrollAnchor? {
        var best: (id: UUID, top: CGFloat)?
        for id in order {
            guard let top = tops[id], top <= viewTop else { continue }
            if best == nil || top >= best!.top { best = (id, top) }
        }
        return best.map { ThreadScrollAnchor(messageID: $0.id, offset: viewTop - $0.top) }
    }

    /// The view top that puts the anchor back, given the message's current
    /// head and the furthest the view can go.
    func scrollTop(messageTop: CGFloat, maximumTop: CGFloat) -> CGFloat {
        min(max(0, messageTop + offset), max(0, maximumTop))
    }
}

/// The scroll anchor of each chat the reader scrolled up in. A chat left at
/// the bottom has none, and opens at the bottom.
struct ThreadScrollAnchorStore: Equatable, Sendable {
    static let capacity = 256

    private var anchors: [UUID: ThreadScrollAnchor] = [:]
    private var order: [UUID] = []

    func anchor(for chatID: UUID) -> ThreadScrollAnchor? { anchors[chatID] }

    /// Remembers the anchor, or forgets the chat's when it is nil (the reader
    /// is at the bottom again). The oldest chat is dropped past `capacity`.
    mutating func record(_ anchor: ThreadScrollAnchor?, for chatID: UUID) {
        guard let anchor else {
            if anchors.removeValue(forKey: chatID) != nil { order.removeAll { $0 == chatID } }
            return
        }
        if anchors.updateValue(anchor, forKey: chatID) == nil {
            order.append(chatID)
            while order.count > Self.capacity { anchors.removeValue(forKey: order.removeFirst()) }
        }
    }
}
