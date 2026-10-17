import Foundation
import AppKit
import Markdown

/// The prose run at the end of a streaming answer, kept as finished blocks
/// plus a tail. Each flush changes only the tail, so the text view replaces
/// the tail's characters instead of setting the whole run again, and the run
/// is measured by a layout that re-lays-out from the edit.
@MainActor
final class StreamingRun {
    /// Blocks that can no longer change. Only ever appended to within one
    /// `epoch`.
    private(set) var frozen = NSMutableAttributedString()
    /// The last block(s), including the blank line that separates them from
    /// the frozen text.
    private(set) var tail = NSAttributedString()
    /// Bumps whenever the frozen text is replaced rather than extended.
    private(set) var epoch = 0

    /// What a text storage already holds of this run.
    struct Shown {
        fileprivate var epoch = -1
        fileprivate var frozenLength = 0
    }

    /// The whole run, for the cases that need one string.
    var text: NSAttributedString {
        let whole = NSMutableAttributedString(attributedString: frozen)
        whole.append(tail)
        return whole
    }

    fileprivate func set(frozen newFrozen: NSMutableAttributedString, tail newTail: NSAttributedString, extends: Bool) {
        if !extends { epoch += 1 }
        frozen = newFrozen
        tail = newTail
    }

    /// Brings `storage` to this run's text (plus `suffix`, the caret). When
    /// the storage already holds this epoch's frozen text, only the characters
    /// after it are replaced.
    func apply(to storage: NSTextStorage, shown: inout Shown, suffix: NSAttributedString? = nil) {
        let from = shown.frozenLength
        let incremental = shown.epoch == epoch && from <= frozen.length && from <= storage.length
        let replacement = NSMutableAttributedString()
        if incremental {
            replacement.append(frozen.attributedSubstring(from: NSRange(location: from, length: frozen.length - from)))
        } else {
            replacement.append(frozen)
        }
        replacement.append(tail)
        if let suffix { replacement.append(suffix) }
        storage.beginEditing()
        if incremental {
            storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: replacement)
        } else {
            storage.setAttributedString(replacement)
        }
        storage.endEditing()
        shown = Shown(epoch: epoch, frozenLength: frozen.length)
    }

    // MARK: - Measuring

    /// A layout of the run's own, kept between flushes so a flush re-lays-out
    /// from the edit, not from the top.
    private let measureStorage = NSTextStorage()
    private let measureLayout = NSLayoutManager()
    private let measureContainer = NSTextContainer()
    private var measureShown = Shown()
    private var measureVersion = -1
    private var version = 0
    private var measureReady = false

    /// Height the run needs at `width`, `suffix` (the caret) included.
    func height(width: CGFloat, suffix: NSAttributedString?) -> CGFloat {
        if !measureReady {
            measureStorage.addLayoutManager(measureLayout)
            measureContainer.lineFragmentPadding = 0
            measureLayout.addTextContainer(measureContainer)
            measureReady = true
        }
        if measureContainer.size.width != width {
            measureContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        if measureVersion != version {
            apply(to: measureStorage, shown: &measureShown, suffix: suffix)
            measureVersion = version
        }
        measureLayout.ensureLayout(for: measureContainer)
        return measureLayout.usedRect(for: measureContainer).height.rounded(.up)
    }

    fileprivate func bump() { version += 1 }
}

/// An answer split into segments and rendered as it streams, doing work in
/// proportion to what the last flush added.
///
/// The split is the same one `MarkdownRenderer.segments` makes and the
/// prose renders as `MarkdownRenderer.render` would, but top-level blocks
/// that a later block has closed are frozen: never parsed or rendered again.
/// Each flush parses only from the first unfrozen block. Anything that could
/// make an earlier block change after the fact (a link reference definition,
/// a fenced block nested in a list) stops the freezing or, for definitions,
/// turns it off, and the output stays equal to the whole-answer render.
@MainActor
final class StreamingAnswer {
    struct Snapshot {
        let segments: [AnswerSegment]
        /// The live prose run when the answer ends in prose.
        let run: StreamingRun?
    }

    private var source = ""
    private var snapshot = Snapshot(segments: [], run: nil)
    private let run = StreamingRun()

    /// Segments before `runStart`, final.
    private var frozenSegments: [AnswerSegment] = []
    /// Where the open prose run begins (after the last closed code block).
    private var runStart = 0
    /// Where parsing resumes: a top-level block start at or after `runStart`.
    private var parseStart = 0
    /// The source bytes before `parseStart`; a new flush must extend them.
    private var committed: [UInt8] = []
    /// The rendered blocks in `runStart..<parseStart`.
    private var openText = NSMutableAttributedString()
    private var openCarriesBreak = false

    func update(_ markdown: String) -> Snapshot {
        if markdown == source { return snapshot }
        source = markdown
        let bytes = Array(markdown.utf8)
        // Text that is not an extension of what was frozen starts over, and a
        // link reference definition can rewrite earlier links, so such an
        // answer is never frozen.
        let extendsCommitted = Self.hasPrefix(bytes, committed)
        // Scan only what arrived since the last flush (plus one byte, for a
        // marker split across two flushes).
        if !extendsCommitted { sawDefinition = false }
        if !sawDefinition {
            sawDefinition = Self.containsDefinitionMarker(bytes, from: extendsCommitted ? max(0, scanned - 1) : 0)
        }
        scanned = bytes.count
        let hasDefinition = sawDefinition
        if hasDefinition || !extendsCommitted { reset() }
        snapshot = hasDefinition ? wholeSnapshot(markdown) : advance(bytes: bytes, markdown: markdown)
        return snapshot
    }

    private var sawDefinition = false
    private var scanned = 0

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        guard !prefix.isEmpty else { return true }
        return prefix.withUnsafeBufferPointer { p in
            bytes.withUnsafeBufferPointer { memcmp(p.baseAddress!, $0.baseAddress!, p.count) == 0 }
        }
    }

    /// `]:` anywhere from `start` on.
    private static func containsDefinitionMarker(_ bytes: [UInt8], from start: Int) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            var index = start
            while index + 1 < buffer.count {
                if buffer[index] == 0x5D, buffer[index + 1] == 0x3A { return true }
                index += 1
            }
            return false
        }
    }

    private func reset() {
        frozenSegments = []
        runStart = 0
        parseStart = 0
        committed = []
        openText = NSMutableAttributedString()
        openCarriesBreak = false
        frozenReplaced = true
    }

    private func wholeSnapshot(_ markdown: String) -> Snapshot {
        let segments = MarkdownRenderer.segments(markdown)
        guard case .prose(let last)? = segments.last?.content else { return Snapshot(segments: segments, run: nil) }
        run.set(frozen: NSMutableAttributedString(), tail: MarkdownRenderer.render(last), extends: false)
        run.bump()
        return Snapshot(segments: segments, run: run)
    }

    private func hasGap(after index: Int, in children: [Markup]) -> Bool {
        guard let range = children[index].range,
              let next = children[index + 1].range?.lowerBound.line else { return false }
        // A list ends at column 1 of the line after its last (the blank line).
        let end = range.upperBound.column == 1 && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1 : range.upperBound.line
        return next > end + 1
    }

    private func advance(bytes: [UInt8], markdown: String) -> Snapshot {
        let base = parseStart
        let tailBytes = Array(bytes[base...])
        let document = Document(parsing: String(decoding: tailBytes, as: UTF8.self))
        let children = Array(document.children)
        let lineStarts = MarkdownRenderer.utf8LineStarts(tailBytes)
        func start(of child: Markup) -> Int? {
            child.range.flatMap { MarkdownRenderer.utf8Offset(of: $0.lowerBound, lineStarts: lineStarts) }
        }
        if children.contains(where: { $0.range == nil }) { reset(); return wholeSnapshot(markdown) }

        // Phase A: walk the blocks a later block has closed. A top-level code
        // block closes the prose run before it and becomes a segment; a block
        // with code nested in it stops the walk.
        var segments = frozenSegments
        var closed = false
        var pendingFrom = 0
        var stop = 0
        var index = 0
        while index < children.count - 1 {
            let child = children[index]
            // Text that follows a block on the very next line can still turn
            // out to belong to it (a table row, a lazy continuation), so only
            // a blank line closes a block. A fenced block is closed by the
            // block after it.
            if !(child is CodeBlock), !hasGap(after: index, in: children) { break }
            if let block = child as? CodeBlock {
                guard let span = MarkdownRenderer.codeSpan(of: block, bytes: tailBytes, lineStarts: lineStarts)
                else { break }
                MarkdownRenderer.appendProse(
                    markdown, bytes: bytes, range: runStart..<(base + span.range.lowerBound), into: &segments
                )
                segments.append(AnswerSegment(id: segments.count, content: .code(span.content)))
                runStart = base + span.range.upperBound
                openText = NSMutableAttributedString()
                openCarriesBreak = false
                closed = true
                pendingFrom = index + 1
            } else {
                var nested: [CodeBlock] = []
                MarkdownRenderer.collectCodeBlocks(child, into: &nested)
                if !nested.isEmpty { break }
            }
            index += 1
            stop = index
        }
        // Closing a run replaces the frozen text; otherwise it only grows.
        let extends = !closed && !frozenReplaced
        frozenReplaced = false
        frozenSegments = segments

        // Phase B: render the prose blocks just frozen onto the open run.
        if pendingFrom < stop {
            var walker = AttributedStringWalker(
                continuing: openText.length > 0, carryingBlockBreak: openCarriesBreak
            )
            for child in children[pendingFrom..<stop] { walker.visit(child) }
            openText.append(MarkdownRenderer.applyProseLineHeight(walker.rendered))
            openCarriesBreak = walker.pendingBlockBreak
        }
        if stop < children.count, let offset = start(of: children[stop]) {
            // The line the first live block starts on.
            let lineStart = lineStarts.last(where: { $0 <= offset }) ?? 0
            parseStart = max(runStart, base + lineStart)
        }
        if committed.count != parseStart { committed = Array(bytes[0..<parseStart]) }

        // Phase C: the live blocks. Segments follow the whole-answer split.
        let liveFrom = stop < children.count ? (start(of: children[stop]) ?? 0) : tailBytes.count
        let spans = MarkdownRenderer.codeSpans(in: document, bytes: tailBytes, lineStarts: lineStarts)
            .filter { $0.range.lowerBound >= liveFrom }
        var cursor = runStart
        var sawCode = false
        for span in spans {
            let lower = base + span.range.lowerBound
            guard lower >= cursor else { continue }
            MarkdownRenderer.appendProse(markdown, bytes: bytes, range: cursor..<lower, into: &segments)
            segments.append(AnswerSegment(id: segments.count, content: .code(span.content)))
            cursor = base + span.range.upperBound
            sawCode = true
        }
        MarkdownRenderer.appendProse(markdown, bytes: bytes, range: cursor..<bytes.count, into: &segments)
        guard case .prose(let lastSource)? = segments.last?.content,
              cursor < bytes.count else { return Snapshot(segments: segments, run: nil) }

        if sawCode {
            run.set(frozen: NSMutableAttributedString(), tail: MarkdownRenderer.render(lastSource), extends: false)
        } else {
            var walker = AttributedStringWalker(
                continuing: openText.length > 0, carryingBlockBreak: openCarriesBreak
            )
            for child in children[stop...] { walker.visit(child) }
            run.set(
                frozen: openText,
                tail: MarkdownRenderer.applyProseLineHeight(walker.rendered),
                extends: extends
            )
        }
        run.bump()
        return Snapshot(segments: segments, run: run)
    }

    /// Set when the frozen text was dropped since the last snapshot.
    private var frozenReplaced = true
}
