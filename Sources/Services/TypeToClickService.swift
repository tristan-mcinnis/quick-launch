import AppKit
import ApplicationServices

/// A single on-screen, actionable element with its assigned hint key.
///
/// `AXUIElement` is an immutable CF handle but the imported C API has no Swift
/// Sendable annotation. Enumeration finishes before this value is consumed on
/// the main actor, so the handle is transferred rather than accessed from both
/// tasks concurrently.
struct TypeToClickTarget: @unchecked Sendable {
    let element: AXUIElement
    let hint: String
    /// Accessibility global frame (top-left origin, y grows down).
    let frame: CGRect
    /// Role / title / value — for debugging and future filtering.
    let label: String
}

/// AX roles are not a reliable indication that an element can be clicked.
/// Buttons in web views can use generic roles, while static text and images
/// often advertise no action at all. Keep the decision action-based.
enum TypeToClickElementPolicy {
    static func isActionable(
        actionNames: [String],
        enabled: Bool,
        hidden: Bool,
        size: CGSize
    ) -> Bool {
        actionNames.contains(kAXPressAction as String)
            && enabled
            && !hidden
            && size.width > 2
            && size.height > 2
    }
}

/// Pure hint-string generation, Vimium-style: all hints share one length so no
/// hint is ever a prefix of another. Kept free of AppKit so it is unit-testable.
enum HintGenerator {
    static func hints(count: Int, alphabet: String) -> [String] {
        guard count > 0 else { return [] }
        var seenCharacters = Set<Character>()
        let chars = Array(alphabet.filter { seenCharacters.insert($0).inserted })
        guard !chars.isEmpty else { return [] }
        // More than one unique, non-prefix hint cannot be represented with a
        // one-character alphabet. Returning no hints is safer than hanging.
        guard chars.count > 1 || count == 1 else { return [] }

        var length = 1
        var capacity = chars.count
        while capacity < count {
            length += 1
            capacity *= chars.count
        }

        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var n = i
            var s = ""
            for _ in 0..<length {
                s = String(chars[n % chars.count]) + s
                n /= chars.count
            }
            out.append(s)
        }
        return out
    }
}

struct TypeToClickScanResult: Sendable {
    let targets: [TypeToClickTarget]
    /// True when the AX safety budget stopped the walk before its queue emptied.
    let wasTruncated: Bool
}

protocol TypeToClickServicing: AnyObject, Sendable {
    /// Checks Accessibility trust. A user-triggered invocation may ask macOS
    /// to show its standard permission prompt.
    func isAccessibilityTrusted(prompt: Bool) -> Bool
    /// Enumerates the actionable elements of `pid`, sorted for reading, each
    /// paired with a generated hint, and reports an incomplete bounded walk.
    func targets(in pid: pid_t, alphabet: String) -> TypeToClickScanResult
    /// Presses (clicks) a target via its accessibility action.
    @discardableResult func press(_ target: TypeToClickTarget) -> Bool
}

/// Walks the accessibility tree of a process and collects actionable elements.
/// Mirrors the AX patterns already used by `WindowManager`.
final class TypeToClickService: TypeToClickServicing, @unchecked Sendable {

    private struct Collected {
        let element: AXUIElement
        let frame: CGRect
        let label: String
    }

    private static let maxDepth = 60
    private static let maxVisitedElements = 1500

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": prompt,
        ] as CFDictionary)
    }

    func targets(in pid: pid_t, alphabet: String) -> TypeToClickScanResult {
        let application = AXUIElementCreateApplication(pid)
        // One unresponsive AX element must not freeze the launcher indefinitely.
        AXUIElementSetMessagingTimeout(application, 0.25)

        var collected: [Collected] = []
        var seen = Set<CFHashCode>()
        // The feature acts on what the user can currently see. Starting at the
        // focused window avoids traversing every background browser window and
        // makes the hotkey respond consistently in large Electron apps.
        let roots = Self.focusedWindow(in: application).map { [$0] }
            ?? Self.windows(in: application)
        var wasTruncated = false
        for root in roots.isEmpty ? [application] : roots {
            if collect(root, depth: 0, out: &collected, seen: &seen) {
                wasTruncated = true
                break
            }
        }

        collected.sort {
            let rowA = Int($0.frame.midY / 24)
            let rowB = Int($1.frame.midY / 24)
            if rowA != rowB { return rowA < rowB }
            return $0.frame.minX < $1.frame.minX
        }

        let hints = HintGenerator.hints(count: collected.count, alphabet: alphabet)
        let targets = zip(collected, hints).map { collected, hint in
            TypeToClickTarget(
                element: collected.element,
                hint: hint,
                frame: collected.frame,
                label: collected.label
            )
        }
        return TypeToClickScanResult(targets: targets, wasTruncated: wasTruncated)
    }

    @discardableResult
    func press(_ target: TypeToClickTarget) -> Bool {
        AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
    }

    // MARK: - Tree walk

    /// Returns true when the safety budget truncated a non-empty queue.
    private func collect(
        _ root: AXUIElement,
        depth: Int,
        out: inout [Collected],
        seen: inout Set<CFHashCode>
    ) -> Bool {
        // Breadth-first traversal reaches the toolbar, sidebar, content, and
        // footer before any one complex web/list branch can consume the 1,500
        // element safety budget. A depth-first walk starved Finder siblings.
        var queue: [(element: AXUIElement, depth: Int)] = [(root, depth)]
        var index = 0
        while index < queue.count,
              seen.count < Self.maxVisitedElements,
              !Task<Never, Never>.isCancelled {
            let current = queue[index]
            index += 1
            guard current.depth < Self.maxDepth else { continue }

            let element = current.element
            let hash = CFHash(element)
            guard !seen.contains(hash) else { continue }
            seen.insert(hash)
            // Messaging timeouts are attached to individual AX handles and are
            // not documented as inheriting from the application root. Bound
            // every descendant before any attribute or action query.
            AXUIElementSetMessagingTimeout(element, 0.25)

            let actionNames = Self.actionNames(element)
            if actionNames.contains(kAXPressAction as String),
               let position = Self.point(element, kAXPositionAttribute),
               let size = Self.size(element, kAXSizeAttribute),
               TypeToClickElementPolicy.isActionable(
                   actionNames: actionNames,
                   enabled: Self.bool(element, kAXEnabledAttribute),
                   hidden: Self.optionalBool(element, kAXHiddenAttribute) ?? false,
                   size: size
               ) {
                // Read labels only for the small subset that can actually be
                // pressed. This avoids AX round-trips for every container.
                let role = Self.string(element, kAXRoleAttribute)
                let title = Self.string(element, kAXTitleAttribute)
                let description = Self.string(element, kAXDescriptionAttribute)
                let value = Self.string(element, kAXValueAttribute)
                let label = !title.isEmpty
                    ? title
                    : (!description.isEmpty ? description : (!value.isEmpty ? value : role))
                out.append(Collected(
                    element: element,
                    frame: CGRect(origin: position, size: size),
                    label: label
                ))
            }

            // Custom AppKit and web controls frequently sit below generic or
            // unknown roles. Always descend instead of using a role allow-list.
            let childDepth = current.depth + 1
            if childDepth < Self.maxDepth {
                queue.append(contentsOf: Self.children(element).map { ($0, childDepth) })
            }
        }
        return index < queue.count && seen.count >= Self.maxVisitedElements
    }

    // MARK: - Attribute access (mirrors WindowManager)

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        optionalBool(element, name) ?? true
    }

    private static func optionalBool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        guard let value = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func windows(in application: AXUIElement) -> [AXUIElement] {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
