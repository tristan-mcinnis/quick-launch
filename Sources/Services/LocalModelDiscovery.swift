import Foundation

enum LocalModelDiscovery {
    /// Find models already stored in LM Studio without starting its app or daemon.
    static func lmStudioModels(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models", isDirectory: true)
    ) -> [String] {
        return scannedLMStudioModels(root: root)
    }

    private static func scannedLMStudioModels(root: URL) -> [String] {
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var identifiers = Set<String>()
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            let isModelFile = name.hasSuffix(".gguf") && !name.hasPrefix("mmproj-")
            let isMLXConfig = name == "config.json"
            guard isModelFile || isMLXConfig else { continue }

            let normalizedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = normalizedRoot + "/"
            guard normalizedFile.hasPrefix(prefix) else { continue }
            let relative = String(normalizedFile.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            guard components.count >= 3 else { continue }
            identifiers.insert(components[0] + "/" + components[1])
        }
        return identifiers.sorted()
    }
}

enum ExecutableResolver {
    /// Where CLIs live on this Mac, searched before `PATH`: an app started
    /// from the Dock gets launchd's short `PATH`, which has none of them.
    static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".opencode/bin"),
            home.appendingPathComponent(".lmstudio/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
        ]
    }

    static func resolve(_ executable: String) -> URL? {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        for directory in searchDirectories() {
            let candidate = directory.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) } ?? []
        for directory in pathDirectories {
            let candidate = directory.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
