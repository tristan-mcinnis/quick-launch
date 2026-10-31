import AppKit
import ApplicationServices
import OSLog

enum TypeToClickKeyPolicy {
    static func matchesHotkey(
        _ hotkey: ActionHotkey?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let hotkey, hotkey.keyCode == keyCode else { return false }
        let ignoredFlags: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad]
        let normalizedEvent = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        let normalizedHotkey = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        return normalizedEvent == normalizedHotkey
    }

    static func queryCharacter(
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let normalizedModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        // Control and Option may still be held from the global hotkey. Command
        // remains reserved for refresh and normal app/menu shortcuts.
        guard !normalizedModifiers.contains(.command),
              let character = charactersIgnoringModifiers?.lowercased(),
              character.count == 1,
              let scalar = character.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return character
    }

    static func action(for modifiers: NSEvent.ModifierFlags) -> TypeToClickAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if flags.contains(.control) { return .secondaryClick }
        let clickModifiers = flags.intersection([.command, .shift, .option])
        return clickModifiers.isEmpty
            ? .activate
            : .click(modifiers: clickModifiers.rawValue)
    }
}

enum TypeToClickCoordinates {
    /// AppKit places the primary display at the global zero origin. Do not
    /// depend on NSScreen array order when deriving the AX y-axis flip.
    static func primaryTop(screenFrames: [CGRect]) -> CGFloat {
        screenFrames.first(where: { $0.origin == .zero })?.maxY
            ?? screenFrames.first?.maxY
            ?? 0
    }

    static func panelRect(
        for accessibilityFrame: CGRect,
        primaryTop: CGFloat,
        panelOrigin: CGPoint
    ) -> NSRect {
        NSRect(
            x: accessibilityFrame.minX - panelOrigin.x,
            y: primaryTop - accessibilityFrame.minY - accessibilityFrame.height - panelOrigin.y,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }
}

enum TypeToClickOverlayPolicy {
    /// Before typing, expose every visible target. Once a query exists, keep
    /// only its fuzzy matches so the on-screen map narrows with the search.
    static func displayedTargets<T>(query: String, all: [T], matches: [T]) -> [T] {
        TypeToClickSearch.normalize(query).isEmpty ? all : matches
    }

    /// An open native menu already supplies its path context. Keep its badge
    /// compact and aligned with the visible leaf command while search/status
    /// continue to use the full path.
    static func badgeLabel(for target: TypeToClickTarget) -> String {
        guard target.kind == .menuItem else { return target.label }
        return target.label.components(separatedBy: " › ").last ?? target.label
    }

    static func mergeBadge(
        _ badge: TypeToClickBadge,
        for kind: TypeToClickTargetKind,
        into badges: inout [TypeToClickBadge]
    ) {
        guard kind == .menuItem,
              let collision = badges.firstIndex(where: { $0.rect == badge.rect })
        else {
            badges.append(badge)
            return
        }
        if badge.isSelected || badge.isPulsing {
            badges[collision] = badge
        }
    }
}

/// The time Type to Click's budgets and delays run on: the wall clock in the
/// app. A test passes a clock whose `now` moves only by the delays slept, so
/// the retry budget and staleness never depend on how busy the machine is.
struct TypeToClickClock: Sendable {
    var now: @Sendable () -> Date
    /// Returns early when the task is cancelled, as `try? Task.sleep` does.
    var sleep: @Sendable (Duration) async -> Void

    static let system = TypeToClickClock(now: { Date() }, sleep: { try? await Task.sleep(for: $0) })
}
