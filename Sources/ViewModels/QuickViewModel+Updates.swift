import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Launch at login

    func applyLaunchAtLogin() {
        let controller = SystemLaunchAtLoginController()
        try? controller.setEnabled(settings.launchAtLogin)
    }

    // MARK: - Install update

    func installUpdate() {
        guard case .updateAvailable(let version) = updateState else { return }
        updateState = .installing(newVersion: version)
        let isHB = FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/quick-launch")
        guard isHB else {
            workspace.open(
                URL(string: "https://github.com/tristan-mcinnis/quick-launch/releases/latest")!
            )
            updateState = .idle
            return
        }

        Task { [weak self, version] in
            let installError: String?
            do {
                let result = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                    arguments: ["upgrade", "quick-launch"]
                )
                installError = result.status == 0
                    ? nil
                    : "Homebrew exited with status \(result.status)"
            } catch {
                installError = error.localizedDescription
            }

            if let installError {
                self?.updateState = .error(message: installError)
            } else {
                self?.updateState = .installed(newVersion: version)
            }
        }
    }

    // MARK: - Manual update check

    func checkForUpdateManual() async {
        updateState = .checking
        do {
            guard let tag = try await Self.latestReleaseTag() else {
                updateState = .error(message: "Could not parse release info")
                return
            }
            await handleUpdateCheck(remoteVersion: tag)
        } catch {
            updateState = .error(message: error.localizedDescription)
        }
    }

    /// The launch-time check: same fetch, never surfaces an error.
    func checkForUpdateSilently() async {
        guard let tag = try? await Self.latestReleaseTag() else { return }
        await handleUpdateCheck(remoteVersion: tag)
    }

    private static func latestReleaseTag() async throws -> String? {
        let url = URL(string: "https://api.github.com/repos/tristan-mcinnis/quick-launch/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["tag_name"] as? String
    }

    // MARK: - Update check

    /// Takes a release tag as GitHub writes it ("v1.2.0") or a bare version.
    func handleUpdateCheck(remoteVersion tag: String) async {
        let remoteVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if QuickViewModel.isVersionNewer(remoteVersion, than: currentVersion) {
            updateState = .updateAvailable(newVersion: remoteVersion)
        } else {
            updateState = .upToDate
        }
    }

    // MARK: - Version comparison

    nonisolated static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let normalize: (String) -> [Int] = { version in
            let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return stripped.split(separator: ".").compactMap { Int($0) }
        }

        var lhs = normalize(candidate)
        var rhs = normalize(current)

        // Pad shorter array with zeros
        let maxLen = max(lhs.count, rhs.count)
        while lhs.count < maxLen { lhs.append(0) }
        while rhs.count < maxLen { rhs.append(0) }

        for (l, r) in zip(lhs, rhs) {
            if l > r { return true }
            if l < r { return false }
        }
        return false // equal
    }
}
