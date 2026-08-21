import Foundation

@MainActor
protocol ApplicationCatalogServicing: AnyObject {
    var applications: [LaunchableApplication] { get }
    func launch(_ application: LaunchableApplication) -> Bool
}
