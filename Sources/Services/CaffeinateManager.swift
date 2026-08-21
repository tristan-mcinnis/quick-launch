import Foundation

@MainActor
protocol CaffeinateManaging: AnyObject {
    var isEnabled: Bool { get }
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
}

@MainActor
final class CaffeinateManager: CaffeinateManaging {
    private var process: Process?
    var isEnabled: Bool { process?.isRunning == true }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard !isEnabled else { return true }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-dimsu"]
            do {
                try process.run()
                self.process = process
                return true
            } catch {
                self.process = nil
                return false
            }
        }
        process?.terminate()
        process = nil
        return true
    }

    deinit { process?.terminate() }
}
