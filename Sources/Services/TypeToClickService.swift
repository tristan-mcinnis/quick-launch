import AppKit
import ApplicationServices

/// A single on-screen, actionable element with its assigned hint key.
struct TypeToClickTarget {
    let element: AXUIElement
    let hint: String
    /// Accessibility global frame (top-left origin, y grows down).
    let frame: CGRect
    /// Role / title / value — for debugging and future filtering.
    let label: String
}

/// Pure hint-string generation, Vimium-style: all hints share one length so no
/// hint is ever a prefix of another. Kept free of AppKit so it is unit-testable.
enum HintGenerator {
    static func hints(count: Int, alphabet: String) -> [String] {
        guard count > 0 else { return [] }
        let chars = Array(alphabet)
        guard !chars.isEmpty else { return [] }

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

@MainActor
protocol TypeToClickServicing: AnyObject {
    /// Enumerates the actionable elements of `pid`, sorted for reading, each
    /// paired with a generated hint.
    func targets(in pid: pid_t, alphabet: String) -> [TypeToClickTarget]
    /// Presses (clicks) a target via its accessibility action.
    func press(_ target: TypeToClickTarget)
}

/// Walks the accessibility tree of a process and collects actionable elements.
/// Mirrors the AX patterns already used by `WindowManager`.
@MainActor
final class TypeToClickService: TypeToClickServicing {

    private struct Collected {
        let element: AXUIElement
        let frame: CGRect
        let label: String
    }

    private static let actionableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXTextFieldRole, kAXTextAreaRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXMenuItemRole, kAXSliderRole,
        kAXComboBoxRole, kAXCellRole, kAXStaticTextRole,
        kAXImageRole, kAXTabGroupRole,
    ]

    private static let containerRoles: Set<String> = [
        kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole,
        kAXSheetRole, kAXOutlineRole, kAXTableRole, kAXListRole,
        kAXToolbarRole, kAXRowRole, kAXBrowserRole, kAXLayoutAreaRole,
        kAXMenuRole, kAXMenuBarRole, kAXApplicationRole, kAXDockItemRole,
        kAXGridRole, kAXColumnRole, "AXWebArea", kAXPopoverRole,
        kAXDrawerRole, kAXIncrementorRole,
    ]

    private static let maxDepth = 60
    private static let maxElements = 3000

    func targets(in pid: pid_t, alphabet: String) -> [TypeToClickTarget] {
        var collected: [Collected] = []
        var seen = Set<CFHashCode>()
        collect(AXUIElementCreateApplication(pid), depth: 0, out: &collected, seen: &seen)

        collected.sort {
            let rowA = Int($0.frame.midY / 24)
            let rowB = Int($1.frame.midY / 24)
            if rowA != rowB { return rowA < rowB }
            return $0.frame.minX < $1.frame.minX
        }

        let hints = HintGenerator.hints(count: collected.count, alphabet: alphabet)
        return zip(collected, hints).map { collected, hint in
            TypeToClickTarget(
                element: collected.element,
                hint: hint,
                frame: collected.frame,
                label: collected.label
            )
        }
    }

    func press(_ target: TypeToClickTarget) {
        _ = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
    }

    // MARK: - Tree walk

    private func collect(
        _ element: AXUIElement,
        depth: Int,
        out: inout [Collected],
        seen: inout Set<CFHashCode>
    ) {
        guard depth < Self.maxDepth, out.count < Self.maxElements else { return }

        let hash = CFHash(element)
        guard !seen.contains(hash) else { return }
        seen.insert(hash)

        let role = Self.string(element, kAXRoleAttribute)

        if Self.actionableRoles.contains(role),
           let position = Self.point(element, kAXPositionAttribute),
           let size = Self.size(element, kAXSizeAttribute),
           size.width > 2, size.height > 2,
           Self.bool(element, kAXEnabledAttribute) {
            let title = Self.string(element, kAXTitleAttribute)
            let value = Self.string(element, kAXValueAttribute)
            let label = !title.isEmpty ? title : (!value.isEmpty ? value : role)
            out.append(Collected(
                element: element,
                frame: CGRect(origin: position, size: size),
                label: label
            ))
        }

        if role.isEmpty || Self.containerRoles.contains(role) || Self.actionableRoles.contains(role) {
            for child in Self.children(element) {
                collect(child, depth: depth + 1, out: &out, seen: &seen)
            }
        }
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
        guard let value = attribute(element, name) else { return true }
        return (value as? Bool) ?? true
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
