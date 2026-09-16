import Foundation

/// Something that can hold a sleep assertion. The real one talks to IOKit;
/// tests use a recorder.
@MainActor
protocol PowerAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    func hold(reason: String, keepDisplayAwake: Bool)
    func release()
}

/// The power source the Caffeinate policy reads: whether the Mac is on battery
/// and how full it is. The real implementation is IOKit; tests inject a
/// settable fake so a battery pause can be exercised without a real battery.
@MainActor
protocol PowerSourceReading: AnyObject {
    var onBattery: Bool { get }
    var batteryPercent: Int { get }
    var onChange: (() -> Void)? { get set }
    func start()
}
