// RenderLaneGuardTests: every suite that renders a view to a bitmap takes the
// main-actor render lane (MainActorRenderLane.swift). Without the lane, the
// heavy suites run in parallel, fill the main queue with long render jobs, and
// starve the main-actor tests that hop many times.

import Foundation
import Testing

@Suite("Render lane guard")
struct RenderLaneGuardTests {
    /// Calls that draw a whole view into a bitmap on the main actor.
    private static let renderMarkers = [
        "cacheDisplay(",
        "bitmapImageRepForCachingDisplay(",
        "renderOnGround(",
        "OverlayRenderProofTests.render(",
    ]

    /// Source lines that are code, not comments.
    private static func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.hasPrefix("//") && !$0.text.hasPrefix("/*") && !$0.text.hasPrefix("*") }
    }

    /// Every `@Suite` in a file that renders must take the lane: a second
    /// suite in the same file, or a marker only in a comment, does not count.
    static func unmarkedSuites(in source: String) -> [Int] {
        let lines = codeLines(source)
        guard lines.contains(where: { line in renderMarkers.contains(where: line.text.contains) }) else {
            return []
        }
        return lines
            .filter { $0.text.hasPrefix("@Suite") && !$0.text.contains(".mainActorRenderLane") }
            .map(\.number)
    }

    @Test func everyBitmapRenderingSuiteTakesTheRenderLane() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ownFiles: Set<String> = ["RenderLaneGuardTests.swift", "MainActorRenderLane.swift"]
        let files = try FileManager.default
            .contentsOfDirectory(at: testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !ownFiles.contains($0.lastPathComponent) }
        #expect(!files.isEmpty, "found the test sources")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in Self.unmarkedSuites(in: source) {
                Issue.record("\(file.lastPathComponent):\(line): suite in a file that renders a view to a bitmap -> add .mainActorRenderLane to its @Suite")
            }
        }
    }

    @Test func theGuardIsPerSuiteAndIgnoresComments() {
        let twoSuites = """
        @Suite("A", .mainActorRenderLane)
        struct A { func r() { host.cacheDisplay(in: rect, to: rep) } }
        @Suite("B")
        struct B {}
        """
        #expect(Self.unmarkedSuites(in: twoSuites) == [3])
        let commentOnly = """
        // host.cacheDisplay(in: rect, to: rep) is not called here.
        @Suite("C")
        struct C {}
        """
        #expect(Self.unmarkedSuites(in: commentOnly).isEmpty)
        let markerOnlyInComment = """
        @Suite("D")
        // .mainActorRenderLane
        struct D { func r() { host.cacheDisplay(in: rect, to: rep) } }
        """
        #expect(Self.unmarkedSuites(in: markerOnlyInComment) == [1])
    }
}
