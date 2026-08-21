import Testing
import Foundation
@testable import QuickLaunch

// TDD (RED phase) — ServerManager does not yet exist.
// Tests define the intended API for buildArguments(port:).
//
// Intended shape:
//   struct ServerManager {
//       static func buildArguments(port: Int) -> [String]
//       static func findAvailablePort(startingAt: Int) async throws -> Int  // socket-based, not tested here
//   }

@Suite("ServerManager")
struct ServerManagerTests {

    // MARK: - 1. Result contains "--serve"

    @Test func testBuildArgumentsContainsServe() {
        let args = ServerManager.buildArguments(port: 11450)
        #expect(args.contains("--serve"))
    }

    // MARK: - 2. Result contains "--port" followed by the port number as string

    @Test func testBuildArgumentsContainsPort() {
        let args = ServerManager.buildArguments(port: 11450)
        #expect(args.contains("--port"))
        // The port value must appear somewhere in the array
        #expect(args.contains("11450"))
    }

    // MARK: - 3. Result contains "--cors"

    @Test func testBuildArgumentsContainsCors() {
        let args = ServerManager.buildArguments(port: 11450)
        #expect(args.contains("--cors"))
    }

    // MARK: - 4. Result contains "--permissive"

    @Test func testBuildArgumentsContainsPermissive() {
        let args = ServerManager.buildArguments(port: 11450)
        #expect(args.contains("--permissive"))
    }

    // MARK: - 5. Port number appears as a String element (not an Int)

    @Test func testBuildArgumentsPortAsString() {
        let port = 11452
        let args = ServerManager.buildArguments(port: port)
        // The array is [String], so the port must be represented as "11452"
        #expect(args.contains("11452"))
        // Confirm it's directly a String element in the array, not embedded elsewhere
        let portStr = String(port)
        #expect(args.filter { $0 == portStr }.count >= 1)
    }
}
