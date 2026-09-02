import Foundation

/// Something that can hold a sleep assertion. The real one talks to IOKit;
/// tests use a recorder.
@MainActor
protocol PowerAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    func hold(reason: String, keepDisplayAwake: Bool)
    func release()
}
