import AppKit
import Foundation

@MainActor
final class ApplicationCatalogService: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]

    init(fileManager: FileManager = .default) {
        applications = Self.discoverApplications(fileManager: fileManager)
    }

    func launch(_ application: LaunchableApplication) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: application.url,
            configuration: configuration,
            completionHandler: nil
        )
        return true
    }

    private static func discoverApplications(
        fileManager: FileManager
    ) -> [LaunchableApplication] {
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            NSHomeDirectory() + "/Applications",
        ].map(URL.init(fileURLWithPath:))

        var seen = Set<String>()
        var results: [LaunchableApplication] = []

        for root in roots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let bundle = Bundle(url: url)
                let info = bundle?.infoDictionary
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let application = LaunchableApplication(
                    name: name,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    url: url
                )
                guard seen.insert(application.id).inserted else { continue }
                results.append(application)
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
