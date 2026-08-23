import Foundation

@MainActor
protocol ApplicationCatalogServicing: AnyObject {
    var applications: [LaunchableApplication] { get }
    /// Bumped whenever `applications` changes, so cached rankings refresh.
    var version: Int { get }
    func launch(_ application: LaunchableApplication) -> Bool
    /// `.app` bundles the user added by hand, outside the scanned folders.
    func setExtraApplicationPaths(_ paths: [String])
}

extension ApplicationCatalogServicing {
    var version: Int { 0 }
    func setExtraApplicationPaths(_ paths: [String]) {}
}
