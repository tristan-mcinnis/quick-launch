import AppKit
import CoreServices
import Foundation

@MainActor
final class ApplicationCatalogService: ApplicationCatalogServicing {
    private(set) var applications: [LaunchableApplication]
    private(set) var version = 0
    /// Extra `.app` bundles the user added in Settings, outside the scanned folders.
    private var extraApplicationPaths: [String] = []
    private var folderStamps: [String: Date]
    private var refreshTask: Task<Void, Never>?

    nonisolated static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        NSHomeDirectory() + "/Applications",
    ]

    init(fileManager: FileManager = .default) {
        applications = Self.discoverApplications(fileManager: fileManager, extraPaths: [])
        folderStamps = Self.stamps(fileManager: fileManager)
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

    /// Apps the user added by hand. Triggers a rescan when the list changed.
    func setExtraApplicationPaths(_ paths: [String]) {
        let cleaned = Array(Set(paths)).sorted()
        guard cleaned != extraApplicationPaths else { return }
        extraApplicationPaths = cleaned
        rescan(force: true)
    }

    /// Called on every overlay open: six `stat` calls, and a background
    /// rescan only when an Applications folder changed since the last look.
    func refreshIfNeeded(fileManager: FileManager = .default) {
        let current = Self.stamps(fileManager: fileManager)
        guard current != folderStamps else { return }
        folderStamps = current
        rescan(force: false)
    }

    /// Spotlight's alternate names, read off the main thread once after launch.
    func loadAlternateNames() {
        let urls = applications.map(\.url)
        Task.detached(priority: .utility) { [weak self] in
            var names: [String: [String]] = [:]
            for url in urls {
                let found = Self.alternateNames(for: url)
                if !found.isEmpty { names[url.path] = found }
            }
            let result = names
            await MainActor.run { [weak self] in
                guard let self, !result.isEmpty else { return }
                self.applications = self.applications.map { application in
                    var updated = application
                    updated.alternateNames = result[application.url.path] ?? []
                    return updated
                }
                self.version += 1
            }
        }
    }

    private func rescan(force: Bool) {
        refreshTask?.cancel()
        let extra = extraApplicationPaths
        let known = Dictionary(uniqueKeysWithValues: applications.map { ($0.url.path, $0.alternateNames) })
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            var found = Self.discoverApplications(fileManager: .default, extraPaths: extra)
            for index in found.indices {
                let path = found[index].url.path
                found[index].alternateNames = known[path] ?? Self.alternateNames(for: found[index].url)
            }
            guard !Task.isCancelled else { return }
            let result = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard force || result != self.applications else { return }
                self.applications = result
                self.version += 1
                AppIconCache.prewarm(paths: result.map(\.url.path))
            }
        }
    }

    nonisolated private static func stamps(fileManager: FileManager) -> [String: Date] {
        var stamps: [String: Date] = [:]
        for root in roots {
            if let date = (try? fileManager.attributesOfItem(atPath: root))?[.modificationDate] as? Date {
                stamps[root] = date
            }
        }
        return stamps
    }

    nonisolated static func alternateNames(for url: URL) -> [String] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let names = MDItemCopyAttribute(item, "kMDItemAlternateNames" as CFString) as? [String]
        else { return [] }
        let own = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return names.filter {
            let lowered = $0.lowercased()
            return lowered != own && lowered != stem && !lowered.hasSuffix(".app")
        }
    }

    nonisolated private static func discoverApplications(
        fileManager: FileManager,
        extraPaths: [String]
    ) -> [LaunchableApplication] {
        var seen = Set<String>()
        var results: [LaunchableApplication] = []

        func add(_ url: URL) {
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
            guard seen.insert(application.id).inserted else { return }
            results.append(application)
        }

        for root in roots.map(URL.init(fileURLWithPath:)) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                add(url)
            }
        }
        for path in extraPaths {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  fileManager.fileExists(atPath: path) else { continue }
            add(url)
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
