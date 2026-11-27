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
    case toggleMute
    case volumeUp
    case volumeDown
    case volume0
    case volume25
    case volume50
    case volume75
    case volume100
    case toggleMicrophoneMute
    case playPause
    case nextTrack
    case previousTrack

    var id: String { rawValue }

    /// The output volume a preset row sets, 0 to 100.
    var volumePreset: Int? {
        switch self {
        case .volume0: 0
        case .volume25: 25
        case .volume50: 50
        case .volume75: 75
        case .volume100: 100
        default: nil
        }
    }

    /// The media key a row presses, as the keyboard's own key would.
    var mediaKey: MediaKey? {
        switch self {
        case .playPause: .playPause
        case .nextTrack: .next
        case .previousTrack: .previous
        default: nil
        }
    }

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
        case .toggleMute: "Toggle Mute"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .volume0, .volume25, .volume50, .volume75, .volume100: "Set Volume to \(volumePreset ?? 0)%"
        case .toggleMicrophoneMute: "Toggle Microphone Mute"
        case .playPause: "Play/Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
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
        case .toggleMute: "Mute or unmute the sound output."
        case .volumeUp: "Turn the sound up one step."
        case .volumeDown: "Turn the sound down one step."
        case .volume0, .volume25, .volume50, .volume75, .volume100: "Set the output volume to \(volumePreset ?? 0)%."
        case .toggleMicrophoneMute: "Mute the microphone, or bring it back to its last level."
        case .playPause: "Play or pause what is playing, as the media key does."
        case .nextTrack: "Skip to the next track."
        case .previousTrack: "Go back to the previous track."
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
        case .toggleMute: "mute sound audio speaker silence unmute"
        case .volumeUp: "volume louder sound audio up increase"
        case .volumeDown: "volume quieter sound audio down decrease"
        case .volume0, .volume25, .volume50, .volume75, .volume100: "volume set sound audio level percent \(volumePreset ?? 0)"
        case .toggleMicrophoneMute: "microphone mic mute input call unmute"
        case .playPause: "play pause music media resume"
        case .nextTrack: "next track skip song music media forward"
        case .previousTrack: "previous track back song music media rewind"
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
        case .toggleMute: "speaker.slash"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .volume0, .volume25, .volume50, .volume75, .volume100: "speaker.wave.2"
        case .toggleMicrophoneMute: "mic.slash"
        case .playPause: "playpause"
        case .nextTrack: "forward"
        case .previousTrack: "backward"
        }
    }

    var isDestructive: Bool { self == .emptyTrash }

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

    /// One volume step, as the keyboard's volume keys move it (1/16).
    static let volumeStep = 6.25
    /// Where the microphone's level before a mute is kept, so unmuting
    /// brings it back.
    static let microphoneRestoreKey = "QuickToggle.microphoneRestoreLevel"
    static let defaultMicrophoneLevel = 75

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
        // Standard Additions, run in this process: no app is told anything,
        // so these need no Automation permission.
        case .toggleMute:
            return [appleScript("set volume output muted not (output muted of (get volume settings))")]
        case .volumeUp:
            return [appleScript("set volume output volume ((output volume of (get volume settings)) + \(volumeStep)) without output muted")]
        case .volumeDown:
            return [appleScript("set volume output volume ((output volume of (get volume settings)) - \(volumeStep))")]
        case .volume0, .volume25, .volume50, .volume75, .volume100:
            let level = volumePreset(for: toggle)
            return [appleScript(level == 0
                ? "set volume output volume 0"
                : "set volume output volume \(level) without output muted")]
        case .toggleMicrophoneMute:
            return microphonePlan(currentLevel: nil, restoreLevel: defaultMicrophoneLevel)
        case .playPause, .nextTrack, .previousTrack:
            // A media key is an event, not a process (`MediaKeyService`).
            return []
        }
    }

    private static func volumePreset(for toggle: QuickToggle) -> Int { toggle.volumePreset ?? 0 }

    private static func appleScript(_ source: String) -> ProcessPlan {
        ProcessPlan(executable: osascript, arguments: ["-e", source])
    }

    static let readMicrophoneLevel = appleScript("input volume of (get volume settings)")

    /// The microphone toggle: a live microphone goes to 0; a silent one
    /// comes back to `restoreLevel`. Unknown level: mute, the safe side.
    static func microphonePlan(currentLevel: Int?, restoreLevel: Int) -> [ProcessPlan] {
        let target = (currentLevel ?? 1) > 0 ? 0 : min(100, max(1, restoreLevel))
        return [appleScript("set volume input volume \(target)")]
    }

    /// The level an `input volume` read printed, or nil.
    static func parseVolume(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func finderDefaultsFlip(key: String, newValue: Bool) -> [ProcessPlan] {
        [
            ProcessPlan(executable: defaults, arguments: ["write", finderDomain, key, "-bool", newValue ? "true" : "false"]),
            ProcessPlan(executable: killall, arguments: ["Finder"]),
        ]
    }

    /// Reads the current state needed by toggles that flip a `defaults`
    /// value. A missing key falls back to the macOS default.
    static func readState(for toggle: QuickToggle) async -> [String: Bool] {
        switch toggle {
        case .toggleHiddenFiles:
            return [hiddenFilesKey: await readFinderBool(hiddenFilesKey) ?? false]
        case .toggleDesktopIcons:
            return [desktopIconsKey: await readFinderBool(desktopIconsKey) ?? true]
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

    private static func readFinderBool(_ key: String) async -> Bool? {
        guard let result = await AppLog.attemptAsync("Read Finder default \(key)", logger: AppLog.process, {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: defaults),
                arguments: ["read", finderDomain, key]
            )
        }), result.status == 0 else { return nil }
        return parseDefaultsBool(result.stdoutText)
    }

    /// Runs the plan. Returns nil on success or a short user-facing error message.
    @MainActor
    static func run(_ toggle: QuickToggle) async -> String? {
        if let key = toggle.mediaKey {
            return MediaKeyService.press(key) ? nil : "Could not press the media key."
        }
        if toggle == .toggleMicrophoneMute {
            return await toggleMicrophone()
        }
        let state = await readState(for: toggle)
        for step in plan(for: toggle, currentState: state) {
            if let failure = await execute(step) {
                return failure
            }
        }
        return nil
    }

    /// Reads the level, keeps it when muting, then sets the new one.
    @MainActor
    private static func toggleMicrophone(defaults store: UserDefaults = .standard) async -> String? {
        let read = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: readMicrophoneLevel.executable),
            arguments: readMicrophoneLevel.arguments
        )
        let current = read.flatMap { $0.status == 0 ? parseVolume($0.stdoutText) : nil }
        let saved = store.object(forKey: microphoneRestoreKey) as? Int
        if let current, current > 0 { store.set(current, forKey: microphoneRestoreKey) }
        for step in microphonePlan(currentLevel: current, restoreLevel: saved ?? defaultMicrophoneLevel) {
            if let failure = await execute(step) { return failure }
        }
        return nil
    }

    private static func execute(_ step: ProcessPlan) async -> String? {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: step.executable),
                arguments: step.arguments
            )
        } catch {
            return "Could not start \(URL(fileURLWithPath: step.executable).lastPathComponent)."
        }
        return failureMessage(for: step, status: result.status, stderr: result.stderrText)
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
