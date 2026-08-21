import Foundation

struct LaunchableApplication: Identifiable, Equatable, Sendable {
    var name: String
    var bundleIdentifier: String?
    var url: URL

    var id: String { bundleIdentifier ?? url.path }
}
