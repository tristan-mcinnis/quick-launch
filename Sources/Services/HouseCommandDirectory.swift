import Foundation

/// The folder every house app writes its manifest into, and the only place
/// Quick Launch looks:
///
///     ~/Library/Application Support/House/commands/<app-id>.json
///
/// Reading is total. A folder that does not exist, a file that cannot be
/// read, a file that is not JSON, and a file from a schema this build does
/// not know all mean the same thing: that app offers nothing. Nothing here
/// throws, so a bad manifest can never block the launcher.
struct HouseCommandDirectory: Sendable {
    let root: URL

    init(root: URL = HouseCommandDirectory.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("House", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
    }

    /// Every readable manifest, sorted by app id so the launcher rows keep a
    /// stable order between reads. Files that are not `.json` are ignored,
    /// as is anything the parser refuses.
    func manifests() -> [HouseCommandManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        var manifests: [HouseCommandManifest] = []
        for name in files {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let manifest = HouseCommandManifest.parse(data)
            else { continue }
            // Two files claiming the same app id: the first by file name
            // wins, so the list cannot carry one app twice.
            guard !manifests.contains(where: { $0.app == manifest.app }) else { continue }
            manifests.append(manifest)
        }
        return manifests
    }
}
