import Foundation

enum ScreenHistoryVaultSaveError: LocalizedError, Equatable {
    case invalidRequest(String)
    case failed(String)
    case invalidResponse
    case unsafePath
    case missingFile
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            "This screen moment cannot be saved: \(message)"
        case .failed(let message):
            "Save to Vault failed: \(message)"
        case .invalidResponse:
            "Save to Vault returned an invalid response."
        case .unsafePath:
            "Save to Vault refused an unsafe result path."
        case .missingFile:
            "Save to Vault did not create the triage note."
        case .timedOut:
            "Save to Vault took too long. Try again."
        }
    }
}

actor ScreenHistoryVaultSaveService: ScreenHistoryVaultSaving {
    static let maximumRecordIDCharacters = 160
    static let maximumApplicationCharacters = 200
    static let maximumWindowTitleCharacters = 500
    static let maximumOCRExcerptCharacters = 4_000
    static let maximumNoteCharacters = 1_000
    static let maximumProjectSlugCharacters = 100

    private let helperURL: URL
    private let vaultRootURL: URL
    private let requestTimeout: Duration

    init(
        helperURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("vault/.claude/tools/ops/screen-history-save.py"),
        vaultRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("vault"),
        requestTimeout: Duration = .seconds(4)
    ) {
        self.helperURL = helperURL.standardizedFileURL
        self.vaultRootURL = vaultRootURL.standardizedFileURL
        self.requestTimeout = requestTimeout
    }

    @discardableResult
    func save(
        _ frame: ScreenHistoryFrame,
        note: String?,
        projectSlug: String?
    ) async throws -> URL {
        let payload = try Self.payload(frame: frame, note: note, projectSlug: projectSlug)
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [helperURL, vaultRootURL] in
                let response = try await Self.run(
                    helperURL: helperURL,
                    vaultRootURL: vaultRootURL,
                    payload: payload
                )
                return try Self.verifyResponse(response, vaultRootURL: vaultRootURL)
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                throw ScreenHistoryVaultSaveError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ScreenHistoryVaultSaveError.invalidResponse
            }
            return result
        }
    }

    nonisolated static func payload(
        frame: ScreenHistoryFrame,
        note: String?,
        projectSlug: String?
    ) throws -> Data {
        let recordID = frame.sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordID.isEmpty, recordID.count <= maximumRecordIDCharacters else {
            throw ScreenHistoryVaultSaveError.invalidRequest("the local record ID is invalid")
        }
        if let note, note.count > maximumNoteCharacters {
            throw ScreenHistoryVaultSaveError.invalidRequest(
                "the note is longer than \(maximumNoteCharacters) characters"
            )
        }
        if let projectSlug, projectSlug.count > maximumProjectSlugCharacters {
            throw ScreenHistoryVaultSaveError.invalidRequest("the project slug is too long")
        }

        let object: [String: Any] = [
            "local_record_id": recordID,
            "seen_at": formattedTimestamp(frame.capturedAt),
            "source": frame.source.rawValue,
            "application": frame.application.map {
                String($0.prefix(maximumApplicationCharacters))
            } ?? NSNull(),
            "window_title": frame.windowTitle.map {
                String($0.prefix(maximumWindowTitleCharacters))
            } ?? NSNull(),
            "ocr_excerpt": String(frame.ocrText.prefix(maximumOCRExcerptCharacters)),
            "note": note ?? NSNull(),
            "project_slug": projectSlug ?? NSNull(),
        ]
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw ScreenHistoryVaultSaveError.invalidRequest("the local record is not valid JSON")
        }
    }

    nonisolated static func formattedTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated static func run(
        helperURL: URL,
        vaultRootURL: URL,
        payload: Data
    ) async throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helperURL.path, "--json"]
        process.currentDirectoryURL = vaultRootURL
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_PROJECT_DIR"] = vaultRootURL.path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(
                        decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard finished.terminationStatus == 0 else {
                        if let response = try? Self.helperError(from: output) {
                            continuation.resume(throwing: response)
                        } else {
                            continuation.resume(throwing: ScreenHistoryVaultSaveError.failed(
                                errorOutput.isEmpty ? "helper exit \(finished.terminationStatus)" : errorOutput
                            ))
                        }
                        return
                    }
                    continuation.resume(returning: output)
                }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(payload)
                    try? stdin.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: ScreenHistoryVaultSaveError.failed(
                        error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    nonisolated static func helperError(from data: Data) throws -> ScreenHistoryVaultSaveError {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = response["error"] as? String,
              !message.isEmpty
        else { throw ScreenHistoryVaultSaveError.invalidResponse }
        return .failed(String(message.prefix(500)))
    }

    nonisolated static func verifyResponse(_ data: Data, vaultRootURL: URL) throws -> URL {
        guard data.count <= 32_768,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["ok"] as? Bool == true,
              let relativePath = response["path"] as? String,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0")
        else { throw ScreenHistoryVaultSaveError.invalidResponse }

        let components = NSString(string: relativePath).pathComponents
        guard components.count == 3,
              components[0] == "kb",
              components[1] == "triage",
              !components.contains(".."),
              components[2].hasSuffix(".md")
        else { throw ScreenHistoryVaultSaveError.unsafePath }

        let candidate = vaultRootURL.appendingPathComponent(relativePath).standardizedFileURL
        let triage = vaultRootURL.appendingPathComponent("kb/triage").standardizedFileURL
            .resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(triage.path + "/") else {
            throw ScreenHistoryVaultSaveError.unsafePath
        }

        let values = try? candidate.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw ScreenHistoryVaultSaveError.missingFile
        }
        return resolved
    }
}
