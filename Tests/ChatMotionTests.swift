// ChatMotionTests: AI Chat has one motion table. Its values are pinned,
// Reduce Motion removes movement in every row, and no AI Chat view file
// carries a raw animation literal of its own.

import Foundation
import Testing
@testable import QuickLaunch

struct ChatMotionTests {
    @Test func overlappingValuesAreTheHouseMotionValues() {
        #expect(ChatMotion.slide == 0.2)
        #expect(ChatMotion.disclosure == 0.175)
        #expect(ChatMotion.appear == 0.3)
        #expect(ChatMotion.copySwap == 0.25)
        #expect(ChatMotion.hover == AQDesign.Motion.hover)
        #expect(ChatMotion.select == AQDesign.Motion.select)
    }

    @Test func reduceMotionRemovesMovementFromEveryRow() {
        #expect(ChatMotion.hoverAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.selectAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.fastAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.scrollAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.disclosureAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.appearAnimation(index: 2, reduceMotion: true) == nil)
        #expect(ChatMotion.copySwapAnimation(reduceMotion: true) == nil)
        #expect(ChatMotion.copySwapAnimation(reduceMotion: false) != nil)
        #expect(ChatMotion.hoverAnimation(reduceMotion: false) != nil)
    }

    /// The structural guard: a literal duration or an animation call that
    /// bypasses ChatMotion in an AI Chat view file fails here.
    @Test func chatViewsTakeEveryAnimationFromTheTable() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let files = [
            "AIChatWindowView", "AttachmentChip", "ChatRailMotion", "CodeBlockView",
            "QuickAIThread", "QuickAIComposer", "ToolActivityGroup", "ChatContextRecordView",
            "ChatPreSendControls", "CollapsibleMessageText",
        ]
        let literal = try Regex(#"\.(easeInOut|easeOut|easeIn|linear|spring|timingCurve)\("#)
        var offences: [String] = []
        for name in files {
            let text = try String(contentsOf: views.appendingPathComponent(name + ".swift"), encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let raw = l.contains(literal)
                let unrouted = (l.contains("withAnimation(") || l.contains(".animation(")) && !l.contains("Motion")
                if raw || unrouted { offences.append("\(name).swift:\(n + 1): \(l.trimmingCharacters(in: .whitespaces))") }
            }
        }
        #expect(offences.isEmpty, "\(offences.joined(separator: "\n"))")
    }
}
