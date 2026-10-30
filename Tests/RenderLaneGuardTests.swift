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

    @Test func everyBitmapRenderingSuiteTakesTheRenderLane() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ownFiles: Set<String> = ["RenderLaneGuardTests.swift", "MainActorRenderLane.swift"]
        let files = try FileManager.default
            .contentsOfDirectory(at: testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !ownFiles.contains($0.lastPathComponent) }
        #expect(!files.isEmpty, "found the test sources")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.renderMarkers.contains(where: source.contains) else { continue }
            #expect(
                source.contains(".mainActorRenderLane"),
                "\(file.lastPathComponent) renders a view to a bitmap -> add .mainActorRenderLane to its @Suite"
            )
        }
    }
}
