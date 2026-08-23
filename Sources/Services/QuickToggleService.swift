import Foundation

/// One-shot system toggles the launcher can run: dark mode, lock screen,
/// hidden files, and friends. Every toggle is a fixed list of process
/// calls; nothing typed by the user ever reaches an argument.
enum QuickToggle: String, CaseIterable, Identifiable, Sendable {
    case toggleDarkMode
    case lockScreen
    case emptyTrash
    case ejectAllDisks
    case toggleHiddenFiles
    case toggleDesktopIcons
    case sleepDisplay
    case startScreenSaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleDarkMode: "Toggle Dark Mode"
        case .lockScreen: "Lock Screen"
        case .emptyTrash: "Empty Trash"
        case .ejectAllDisks: "Eject All Disks"
        case .toggleHiddenFiles: "Toggle Hidden Files"
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .sleepDisplay: "Sleep Display"
        case .startScreenSaver: "Start Screen Saver"
        }
    }

    var detail: String {
        switch self {
        case .toggleDarkMode: "Switch the system appearance between light and dark."
        case .lockScreen: "Lock the screen right away."
        case .emptyTrash: "Delete everything in the Trash for good."
        case .ejectAllDisks: "Eject every external disk that can be ejected."
        case .toggleHiddenFiles: "Show or hide hidden files in Finder, then restart Finder."
        case .toggleDesktopIcons: "Show or hide the icons on the desktop, then restart Finder."
        case .sleepDisplay: "Turn the display off without sleeping the Mac."
        case .startScreenSaver: "Start the screen saver now."
        }
    }

    var keywords: String {
        switch self {
        case .toggleDarkMode: "appearance light theme night"
        case .lockScreen: "lock sleep away secure"
        case .emptyTrash: "trash bin delete clear"
        case .ejectAllDisks: "eject disk drive usb unmount"
        case .toggleHiddenFiles: "hidden files finder dotfiles show"
        case .toggleDesktopIcons: "desktop icons hide clean finder"
        case .sleepDisplay: "display screen sleep off monitor"
        case .startScreenSaver: "screensaver screen saver lock"
        }
    }

    var systemImage: String {
        switch self {
        case .toggleDarkMode: "circle.lefthalf.filled"
        case .lockScreen: "lock.fill"
        case .emptyTrash: "trash"
        case .ejectAllDisks: "eject.fill"
        case .toggleHiddenFiles: "eye.slash"
        case .toggleDesktopIcons: "menubar.dock.rectangle"
        case .sleepDisplay: "display"
        case .startScreenSaver: "sparkles.tv"
        }
    }

    var isDestructive: Bool { self == .emptyTrash }

    /// Dark mode and lock screen go through System Events; trash and eject
    /// go through Finder. Both need an Automation grant for Quick Launch.
    var needsAutomationPermission: Bool {
        switch self {
        case .toggleDarkMode, .lockScreen, .emptyTrash, .ejectAllDisks: true
        case .toggleHiddenFiles, .toggleDesktopIcons, .sleepDisplay, .startScreenSaver: false
        }
    }
}

/// One external call. `arguments` never contains user text.
struct ProcessPlan: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum QuickToggleService {
    static let osascript = "/usr/bin/osascript"
    static let defaults = "/usr/bin/defaults"
    static let killall = "/usr/bin/killall"
    static let pmset = "/usr/bin/pmset"
    static let open = "/usr/bin/open"
    static let finderDomain = "com.apple.finder"
    static let hiddenFilesKey = "AppleShowAllFiles"
    static let desktopIconsKey = "CreateDesktop"

    static let automationHint = "Allow Quick Launch to control System Events/Finder in System Settings › Privacy & Security › Automation"

    /// Ordered steps to run for a toggle. Pure; tests cover this.
    static func plan(for toggle: QuickToggle, currentState: [String: Bool] = [:]) -> [ProcessPlan] {
        switch toggle {
        case .toggleDarkMode:
            return [ProcessPlan(
                executable: osascript,
                arguments: ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]
            )]
        case .lockScreen:
            return [ProcessPlan(
                executable: osascript,
                arguments: ["-e", "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"]
            )]
        case .emptyTrash:
            return [ProcessPlan(
                executable: osascript,
                arguments: ["-e", "tell application \"Finder\" to empty the trash"]
            )]
        case .ejectAllDisks:
            return [ProcessPlan(
                executable: osascript,
                arguments: ["-e", "tell application \"Finder\" to eject (every disk whose ejectable is true)"]
            )]
        case .toggleHiddenFiles:
            let current = currentState[hiddenFilesKey] ?? false
            return finderDefaultsFlip(key: hiddenFilesKey, newValue: !current)
        case .toggleDesktopIcons:
            let current = currentState[desktopIconsKey] ?? true
            return finderDefaultsFlip(key: desktopIconsKey, newValue: !current)
        case .sleepDisplay:
            return [ProcessPlan(executable: pmset, arguments: ["displaysleepnow"])]
        case .startScreenSaver:
            return [ProcessPlan(executable: open, arguments: ["-a", "ScreenSaverEngine"])]
        }
    }

    private static func finderDefaultsFlip(key: String, newValue: Bool) -> [ProcessPlan] {
        [
            ProcessPlan(executable: defaults, arguments: ["write", finderDomain, key, "-bool", newValue ? "true" : "false"]),
            ProcessPlan(executable: killall, arguments: ["Finder"]),
        ]
    }

    /// Reads the current state needed by toggles that flip a `defaults`
    /// value. A missing key falls back to the macOS default.
    static func readState(for toggle: QuickToggle) -> [String: Bool] {
        switch toggle {
        case .toggleHiddenFiles:
            return [hiddenFilesKey: readFinderBool(hiddenFilesKey) ?? false]
        case .toggleDesktopIcons:
            return [desktopIconsKey: readFinderBool(desktopIconsKey) ?? true]
        default:
            return [:]
        }
    }

    /// `defaults read` output for a bool: "1", "0", "true", "false", "YES", "NO".
    static func parseDefaultsBool(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: nil
        }
    }

    private static func readFinderBool(_ key: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: defaults)
        process.arguments = ["read", finderDomain, key]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseDefaultsBool(String(decoding: data, as: UTF8.self))
    }

    /// Runs the plan. Returns nil on success or a short user-facing error message.
    @MainActor
    static func run(_ toggle: QuickToggle) async -> String? {
        let state = readState(for: toggle)
        for step in plan(for: toggle, currentState: state) {
            if let failure = await execute(step) {
                return failure
            }
        }
        return nil
    }

    private struct StepResult: Sendable {
        let status: Int32
        let stderr: String
    }

    private static func execute(_ step: ProcessPlan) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return "Could not start \(URL(fileURLWithPath: step.executable).lastPathComponent)."
        }
        let result: StepResult = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: StepResult(
                    status: finished.terminationStatus,
                    stderr: String(decoding: data, as: UTF8.self)
                ))
            }
        }
        return failureMessage(for: step, status: result.status, stderr: result.stderr)
    }

    /// nil when the step succeeded. Pure; tests cover the permission hint.
    static func failureMessage(for step: ProcessPlan, status: Int32, stderr: String) -> String? {
        guard status != 0 else { return nil }
        let tool = URL(fileURLWithPath: step.executable).lastPathComponent
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.executable == osascript, status == 1,
           trimmed.localizedCaseInsensitiveContains("not allowed") || trimmed.contains("-1743") {
            return "Automation was blocked. \(automationHint)."
        }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "\(tool) exited with status \(status)." : "\(tool) failed: \(firstLine)"
    }
}
