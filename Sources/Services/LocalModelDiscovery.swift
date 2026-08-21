import Foundation

enum LocalModelDiscovery {
    /// Find models already stored in LM Studio without starting its daemon.
    /// The API refresh path replaces these identifiers with LM Studio's own
    /// catalogue when the local server is running.
    static func lmStudioModels(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models", isDirectory: true)
    ) -> [String] {
        let cliModels = lmStudioCLIModels()
        if !cliModels.isEmpty { return cliModels }

        return scannedLMStudioModels(root: root)
    }

    /// `lms ls --json` exposes LM Studio's actual model keys and does not need
    /// the inference server to be running. Folder names are only a fallback.
    static func lmStudioCLIModels() -> [String] {
        guard let executable = ExecutableResolver.resolve("lms") else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["ls", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return parseLMStudioModels(output.fileHandleForReading.readDataToEndOfFile())
        } catch {
            return []
        }
    }

    static func parseLMStudioModels(_ data: Data) -> [String] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(Set(entries.compactMap { entry -> String? in
            guard entry["type"] as? String == "llm" else { return nil }
            return entry["modelKey"] as? String
        })).sorted()
    }

    private static func scannedLMStudioModels(root: URL) -> [String] {
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

            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relative.split(separator: "/").map(String.init)
            guard components.count >= 3 else { continue }
            identifiers.insert(components[0] + "/" + components[1])
        }
        return identifiers.sorted()
    }
}

enum ExecutableResolver {
    static func resolve(_ executable: String) -> URL? {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchDirectories = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".opencode/bin"),
            home.appendingPathComponent(".lmstudio/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
        ]
        for directory in searchDirectories {
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
