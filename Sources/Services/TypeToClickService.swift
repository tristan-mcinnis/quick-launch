import AppKit
import ApplicationServices

/// A single action that Type to Click can perform on its selected result.
enum TypeToClickAction: Equatable, Sendable {
    /// Prefer the element's semantic Accessibility action, then fall back to a
    /// guarded click at its current midpoint.
    case activate
    /// Send a left click carrying the requested AppKit modifier flags.
    case click(modifiers: UInt)
    /// Send a right click at the element midpoint.
    case secondaryClick
}

enum TypeToClickTargetKind: String, Sendable {
    case element
    case menuBarItem
    case menuItem

    var isMenuTarget: Bool { self != .element }
}

/// A searchable Accessibility element. Top-level menu-bar items have frames;
/// commands inside closed menus remain searchable by their complete path.
///
/// `AXUIElement` is an immutable CF handle but the imported C API has no Swift
/// Sendable annotation. Enumeration finishes before this value is consumed on
/// the main actor, so the handle is transferred rather than accessed from both
/// tasks concurrently.
struct TypeToClickTarget: @unchecked Sendable {
    let element: AXUIElement
    /// Accessibility global frame (top-left origin, y grows down). Menu items
    /// in a closed menu intentionally have no frame.
    let frame: CGRect?
    let label: String
    let searchText: String
    let role: String
    let actionNames: [String]
    let kind: TypeToClickTargetKind
}

/// Roles and semantic actions are both needed. Web controls often expose a
/// generic role with AXPress, while text fields and some Electron controls may
/// expose a useful role but no press action.
enum TypeToClickElementPolicy {
    private static let semanticActions: Set<String> = [
        kAXPressAction as String,
        kAXShowMenuAction as String,
        kAXConfirmAction as String,
    ]

    private static let interactiveRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        "AXLink",
        kAXMenuItemRole as String,
        kAXPopUpButtonRole as String,
        kAXComboBoxRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
    ]

    static func isActionable(
        actionNames: [String],
        role: String = "",
        enabled: Bool,
        hidden: Bool,
        size: CGSize
    ) -> Bool {
        enabled
            && !hidden
            && size.width > 2
            && size.height > 2
            && (!semanticActions.isDisjoint(with: actionNames)
                || interactiveRoles.contains(role))
    }

    static func canReceiveKeyboardFocus(role: String) -> Bool {
        role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }
}

enum TypeToClickMenuPolicy {
    /// A pathological branch may be too large to walk, but its visible
    /// top-level menu-bar item must still remain searchable.
    static func shouldCollectResult(isMenuBarItem: Bool, isIgnoredBranch: Bool) -> Bool {
        isMenuBarItem || !isIgnoredBranch
    }

    /// Open menu commands have real nonzero frames and should join the named
    /// target map. Closed commands report zero-sized placeholder coordinates,
    /// so they remain searchable without drawing a misleading badge.
    static func visibleFrame(
        role: String,
        position: CGPoint?,
        size: CGSize?,
        hidden: Bool
    ) -> CGRect? {
        guard role == kAXMenuBarItemRole as String || role == kAXMenuItemRole as String,
              !hidden,
              let position,
              let size,
              size.width > 2,
              size.height > 2
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

struct TypeToClickScanResult: Sendable {
    let targets: [TypeToClickTarget]
    /// True when an AX safety budget stopped either walk before its queue emptied.
    let wasTruncated: Bool
}

/// Walks the accessibility tree of a process and collects actionable elements.
final class TypeToClickService: TypeToClickServicing, @unchecked Sendable {

    private struct Collected {
        let element: AXUIElement
        let frame: CGRect?
        let label: String
        let searchText: String
        let role: String
        let actionNames: [String]
        let kind: TypeToClickTargetKind
    }

    private static let maxDepth = 60
    private static let maxVisitedElements = 1500
    private static let maxVisitedMenuElements = 500
    private static let ignoredMenuBranches: Set<String> = [
        "bookmarks", "open recent", "recent items",
    ]

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": prompt,
        ] as CFDictionary)
    }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var elements: [Collected] = []
        var seen = Set<CFHashCode>()
        let roots = Self.focusedWindow(in: application).map { [$0] }
            ?? Self.windows(in: application)
        var wasTruncated = false
        for root in roots.isEmpty ? [application] : roots {
            if collectElements(root, depth: 0, out: &elements, seen: &seen) {
                wasTruncated = true
                break
            }
        }

        elements.sort {
            guard let frameA = $0.frame, let frameB = $1.frame else { return $0.frame != nil }
            let rowA = Int(frameA.midY / 24)
            let rowB = Int(frameB.midY / 24)
            if rowA != rowB { return rowA < rowB }
            return frameA.minX < frameB.minX
        }

        if let menuBar = Self.elementAttribute(application, kAXMenuBarAttribute) {
            var menuItems: [Collected] = []
            if collectMenuItems(menuBar, out: &menuItems) {
                wasTruncated = true
            }
            // Put the visible system/app menu row before window controls. The
            // remaining closed commands stay searchable without spatial frames.
            elements = menuItems.filter { $0.frame != nil }
                + elements
                + menuItems.filter { $0.frame == nil }
        }

        // Type to Click is search-only. Targets intentionally have no arbitrary
        // generated codes; users reach them through labels, paths, and roles.
        let targets = elements.map { collected in
            TypeToClickTarget(
                element: collected.element,
                frame: collected.frame,
                label: collected.label,
                searchText: collected.searchText,
                role: collected.role,
                actionNames: collected.actionNames,
                kind: collected.kind
            )
        }

        return TypeToClickScanResult(targets: targets, wasTruncated: wasTruncated)
    }

    @discardableResult
    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        AXUIElementSetMessagingTimeout(target.element, 0.25)
        guard Self.bool(target.element, kAXEnabledAttribute) else { return false }

        // Closed-menu commands need semantic activation because they have no
        // usable coordinates. macOS reports success for AXPress/AXShowMenu on
        // some top-level menu-bar items without actually opening the menu, so
        // visible top-level items use the same guarded coordinate click as a
        // physical menu-bar click.
        if target.kind == .menuBarItem {
            guard let point = currentMidpoint(of: target.element) else { return false }
            return postClick(at: point, button: .left, modifiers: 0)
        }
        if target.kind == .menuItem {
            return performSemanticAction(on: target)
        }

        guard !(Self.optionalBool(target.element, kAXHiddenAttribute) ?? false) else {
            return false
        }

        switch action {
        case .activate:
            if performSemanticAction(on: target) { return true }
            if TypeToClickElementPolicy.canReceiveKeyboardFocus(role: target.role),
               AXUIElementSetAttributeValue(
                   target.element,
                   kAXFocusedAttribute as CFString,
                   kCFBooleanTrue
               ) == .success {
                return true
            }
            guard let point = currentMidpoint(of: target.element) else { return false }
            return postClick(at: point, button: .left, modifiers: 0)

        case .click(let modifiers):
            guard let point = currentMidpoint(of: target.element) else { return false }
            return postClick(at: point, button: .left, modifiers: modifiers)

        case .secondaryClick:
            guard let point = currentMidpoint(of: target.element) else { return false }
            return postClick(at: point, button: .right, modifiers: 0)
        }
    }

    private func performSemanticAction(on target: TypeToClickTarget) -> Bool {
        let currentActions = Self.actionNames(target.element)
        let preferred = [
            kAXPressAction as String,
            kAXShowMenuAction as String,
            kAXConfirmAction as String,
        ]
        for action in preferred where currentActions.contains(action) {
            if AXUIElementPerformAction(target.element, action as CFString) == .success {
                return true
            }
        }
        return false
    }

    private func currentMidpoint(of element: AXUIElement) -> CGPoint? {
        guard let position = Self.point(element, kAXPositionAttribute),
              let size = Self.size(element, kAXSizeAttribute),
              TypeToClickElementPolicy.isActionable(
                  actionNames: Self.actionNames(element),
                  role: Self.string(element, kAXRoleAttribute),
                  enabled: Self.bool(element, kAXEnabledAttribute),
                  hidden: Self.optionalBool(element, kAXHiddenAttribute) ?? false,
                  size: size
              )
        else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func postClick(
        at point: CGPoint,
        button: CGMouseButton,
        modifiers: UInt
    ) -> Bool {
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: point,
            mouseButton: button
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: upType,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return false }

        let appKit = NSEvent.ModifierFlags(rawValue: modifiers)
        var flags: CGEventFlags = []
        if appKit.contains(.command) { flags.insert(.maskCommand) }
        if appKit.contains(.shift) { flags.insert(.maskShift) }
        if appKit.contains(.option) { flags.insert(.maskAlternate) }
        if appKit.contains(.control) { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Tree walks

    /// Returns true when the safety budget truncated a non-empty queue.
    private func collectElements(
        _ root: AXUIElement,
        depth: Int,
        out: inout [Collected],
        seen: inout Set<CFHashCode>
    ) -> Bool {
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
            AXUIElementSetMessagingTimeout(element, 0.25)

            let actionNames = Self.actionNames(element)
            let role = Self.string(element, kAXRoleAttribute)
            if let position = Self.point(element, kAXPositionAttribute),
               let size = Self.size(element, kAXSizeAttribute),
               TypeToClickElementPolicy.isActionable(
                   actionNames: actionNames,
                   role: role,
                   enabled: Self.bool(element, kAXEnabledAttribute),
                   hidden: Self.optionalBool(element, kAXHiddenAttribute) ?? false,
                   size: size
               ) {
                let strings = Self.searchableStrings(element, role: role)
                let label = strings.first(where: { !$0.isEmpty }) ?? Self.roleName(role)
                out.append(Collected(
                    element: element,
                    frame: CGRect(origin: position, size: size),
                    label: label,
                    searchText: strings.joined(separator: " "),
                    role: role,
                    actionNames: actionNames,
                    kind: .element
                ))
            }

            let childDepth = current.depth + 1
            if childDepth < Self.maxDepth, role != kAXMenuBarRole as String {
                queue.append(contentsOf: Self.children(element).map { ($0, childDepth) })
            }
        }
        return index < queue.count && seen.count >= Self.maxVisitedElements
    }

    private func collectMenuItems(
        _ root: AXUIElement,
        out: inout [Collected]
    ) -> Bool {
        var queue: [(element: AXUIElement, path: [String], depth: Int)] = [(root, [], 0)]
        var seen = Set<CFHashCode>()
        var index = 0
        while index < queue.count,
              seen.count < Self.maxVisitedMenuElements,
              !Task<Never, Never>.isCancelled {
            let current = queue[index]
            index += 1
            guard current.depth < Self.maxDepth else { continue }
            let element = current.element
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, 0.25)

            let role = Self.string(element, kAXRoleAttribute)
            let explicitTitle = Self.string(element, kAXTitleAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = Self.string(element, kAXDescriptionAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The Apple item can expose its visible name as AXDescription
            // instead of AXTitle, depending on the macOS/app combination.
            let title = explicitTitle.isEmpty ? description : explicitTitle
            let isMenuBarItem = role == kAXMenuBarItemRole as String
            let isMenuResult = role == kAXMenuItemRole as String || isMenuBarItem
            let path = isMenuResult && !title.isEmpty ? current.path + [title] : current.path
            let normalizedTitle = title.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            ).lowercased()
            let isIgnoredBranch = Self.ignoredMenuBranches.contains(normalizedTitle)
            if isMenuResult,
               !title.isEmpty,
               Self.bool(element, kAXEnabledAttribute),
               TypeToClickMenuPolicy.shouldCollectResult(
                   isMenuBarItem: isMenuBarItem,
                   isIgnoredBranch: isIgnoredBranch
               ) {
                let actionNames = Self.actionNames(element)
                if actionNames.contains(kAXPressAction as String) {
                    let shortcut = Self.string(element, kAXMenuItemCmdCharAttribute)
                    let help = Self.string(element, kAXHelpAttribute)
                    let label = path.joined(separator: " › ")
                    let frame = TypeToClickMenuPolicy.visibleFrame(
                        role: role,
                        position: Self.point(element, kAXPositionAttribute),
                        size: Self.size(element, kAXSizeAttribute),
                        hidden: Self.optionalBool(element, kAXHiddenAttribute) ?? false
                    )
                    out.append(Collected(
                        element: element,
                        frame: frame,
                        label: label,
                        searchText: [
                            label, description, help, shortcut,
                            isMenuBarItem ? "menu bar top row" : "menu command",
                        ].joined(separator: " "),
                        role: role,
                        actionNames: actionNames,
                        kind: isMenuBarItem ? .menuBarItem : .menuItem
                    ))
                }
            }

            // Keep a top-level Bookmarks/Recent item itself, but do not walk
            // the potentially huge user-generated branch beneath it.
            if isIgnoredBranch { continue }
            queue.append(contentsOf: Self.children(element).map {
                ($0, path, current.depth + 1)
            })
        }
        return index < queue.count && seen.count >= Self.maxVisitedMenuElements
    }

    // MARK: - Attribute access

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    private static func searchableStrings(_ element: AXUIElement, role: String) -> [String] {
        let attributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute,
            kAXPlaceholderValueAttribute,
            kAXSubroleAttribute,
        ]
        return attributes.map { string(element, $0) }
            + [roleName(role), role.replacingOccurrences(of: "AX", with: "")]
    }

    private static func roleName(_ role: String) -> String {
        role.replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "_", with: " ")
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
        elementAttribute(application, kAXFocusedWindowAttribute)
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
