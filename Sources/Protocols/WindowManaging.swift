import Foundation

@MainActor
protocol WindowManaging: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool
    func move(_ move: WindowMove, target: SelectionTarget) -> Bool
}
