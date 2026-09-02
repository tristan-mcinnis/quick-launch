import Foundation

protocol TypeToClickServicing: AnyObject, Sendable {
    func isAccessibilityTrusted(prompt: Bool) -> Bool
    /// Enumerates visible controls in the focused window plus the active app's
    /// complete menu hierarchy.
    func targets(in pid: pid_t) -> TypeToClickScanResult
    /// Revalidates and performs the requested action.
    @discardableResult func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool
}
