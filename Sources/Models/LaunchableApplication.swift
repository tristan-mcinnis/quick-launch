import Foundation

struct LaunchableApplication: Identifiable, Equatable, Sendable {
    var name: String
    var bundleIdentifier: String?
    var url: URL
    /// Names Spotlight also answers to (`kMDItemAlternateNames`): "System
    /// Preferences" for System Settings. Filled in after launch.
    var alternateNames: [String] = []

    var id: String { bundleIdentifier ?? url.path }
}
