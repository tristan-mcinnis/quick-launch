import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screenshot workflow", .serialized)
@MainActor
struct ScreenshotWorkflowTests {
    private static let sampleAttachment: QuickImageAttachment = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        return QuickImageAttachment(data: png, mimeType: "image/png", pixelWidth: 2, pixelHeight: 2)
    }()

    private static let safari = SelectionTarget(processIdentifier: 4242, applicationName: "Safari")

    // MARK: - Commands and attachment

    @Test func screenshotCommandsAreSearchableAndAttachThenPresentTheOverlay() async {
        let capture = FakeScreenshotService()
        let vm = QuickViewModel(screenshotService: capture)
        vm.rememberSelectionTarget(Self.safari)

        var presented = 0
        let token = NotificationCenter.default.addObserver(
            forName: .presentOverlay, object: nil, queue: nil
        ) { _ in presented += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        vm.settings.screenshotTextSearch = false
        vm.input = "focused window"
        let matches = vm.launcherMatches
        let windowIndex = matches.firstIndex {
            guard case .item(let item) = $0 else { return false }
            return item.itemID == ScreenshotKind.window.commandID
        }
        #expect(windowIndex != nil)
        vm.applicationSelectionIndex = windowIndex ?? 0
        await vm.submitResolvingFuzzyAlias()

        #expect(capture.captured.map(\.kind) == [.window])
        #expect(capture.captured.first?.target == Self.safari)
        #expect(capture.captured.first?.ownProcess == ProcessInfo.processInfo.processIdentifier)
        #expect(vm.pendingImage == Self.sampleAttachment)
        #expect(vm.input.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(presented == 1)
        #expect(vm.launcherMatches.isEmpty)
    }

    @Test func overlayShortcutKeepsTypedQuestion() async {
        let capture = FakeScreenshotService()
        let vm = QuickViewModel(screenshotService: capture)
        vm.input = "what does this say"
        let attached = await vm.attachScreenshot(.display, clearingInput: false)
        #expect(attached)
        #expect(vm.input == "what does this say")
        #expect(vm.pendingImage != nil)
        #expect(capture.captured.map(\.kind) == [.display])
    }

    @Test func windowScreenshotNeedsAnAppBehindTheOverlay() async {
        let capture = FakeScreenshotService()
        capture.failure = ScreenshotCaptureError.noPreviousApp
        let vm = QuickViewModel(screenshotService: capture)
        let attached = await vm.attachScreenshot(.window, clearingInput: true)
        #expect(!attached)
        #expect(vm.pendingImage == nil)
        #expect(vm.errorMessage?.contains("No app window") == true)
    }

    @Test func missingPermissionExplainsTheSystemSettingsStep() async {
        let capture = FakeScreenshotService()
        capture.failure = ScreenshotCaptureError.notAuthorized
        let vm = QuickViewModel(screenshotService: capture)
        _ = await vm.attachScreenshot(.display, clearingInput: true)
        #expect(vm.errorMessage?.contains("Screen & System Audio Recording") == true)
    }

    @Test func footerExplainsImageActions() async {
        let vm = QuickViewModel(screenshotService: FakeScreenshotService())
        _ = await vm.attachScreenshot(.window, clearingInput: true)
        let labels = vm.footerHints.map(\.label)
        #expect(labels == ["Ask", "Remove", "Retake"])
        vm.removePendingImage()
        #expect(vm.pendingImage == nil)
        #expect(vm.footerHints.map(\.label).contains("Screenshot"))
    }

    // MARK: - Vision routing

    @Test func imageGoesToTheVisionProviderAndStaysForFollowUps() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "A settings window.", finishReason: "stop")])
        var settings = QuickSettings()
        // The injected service is the test seam; every provider resolves to it.
        settings.visionProviderID = InferenceProvider.deepSeekID
        let vm = QuickViewModel(settings: settings, service: mock)

        vm.pendingImage = Self.sampleAttachment
        vm.input = "what is this"
        await vm.submit()
        #expect(await mock.lastImage == Self.sampleAttachment)
        #expect(vm.pendingImage == nil)
        #expect(vm.currentConversation?.providerID == InferenceProvider.deepSeekID)

        vm.input = "and the second line?"
        await vm.submit()
        #expect(await mock.sendCallCount == 2)
        #expect(await mock.lastImage == Self.sampleAttachment)

        vm.startNewConversation()
        vm.input = "unrelated"
        await vm.submit()
        #expect(await mock.lastImage == nil)
        #expect(vm.history.allSatisfy { conversation in
            conversation.messages.allSatisfy { !$0.content.contains("base64") }
        })
    }

    @Test func visionModelSettingOverridesTheProviderModel() {
        var settings = QuickSettings()
        settings.visionProviderID = InferenceProvider.deepSeekID
        settings.visionModel = InferenceProvider.deepSeekVisionModel
        let vm = QuickViewModel(settings: settings)
        #expect(vm.visionProvider?.id == InferenceProvider.deepSeekID)
        #expect(vm.visionModelName == InferenceProvider.deepSeekVisionModel)
        #expect(vm.visionRoutingNote == "Sent to DeepSeek API")
        vm.pendingImage = Self.sampleAttachment
        #expect(vm.activeModelDisplay.contains(InferenceProvider.deepSeekVisionModel))

        let fresh = QuickViewModel()
        #expect(fresh.visionProvider?.id == InferenceProvider.deepSeekID)
        #expect(fresh.visionModelName == InferenceProvider.deepSeekVisionModel)
        #expect(fresh.visionRoutingNote == "Sent to DeepSeek API")

        var offline = QuickSettings()
        offline.visionProviderID = InferenceProvider.mlxVisionID
        offline.visionModel = ""
        let local = QuickViewModel(settings: offline)
        #expect(local.visionRoutingNote.hasSuffix("on this Mac"))
    }

    @Test func visionSettingsRoundTripAndDeepSeekGainsItsVisionModelOnce() throws {
        var settings = QuickSettings()
        settings.visionProviderID = InferenceProvider.deepSeekID
        settings.visionModel = "custom-vision"
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(back.visionProviderID == InferenceProvider.deepSeekID)
        #expect(back.visionModel == "custom-vision")

        var legacy = QuickSettings()
        legacy.configurationVersion = 10
        let index = legacy.providers.firstIndex { $0.id == InferenceProvider.deepSeekID }!
        legacy.providers[index].models = ["deepseek-v4-flash"]
        legacy.providers[index].selectedModel = "deepseek-v4-flash"
        legacy.visionProviderID = InferenceProvider.mlxVisionID
        legacy.visionModel = ""
        let legacyData = try JSONEncoder().encode(legacy)
        let migrated = try JSONDecoder().decode(QuickSettings.self, from: legacyData)
        #expect(migrated.providers[index].models.contains(InferenceProvider.deepSeekVisionModel))
        #expect(migrated.visionProviderID == InferenceProvider.deepSeekID)
        #expect(migrated.providers[index].selectedModel == InferenceProvider.deepSeekVisionModel)
    }

    // MARK: - Result actions

    @Test func resultCanBeSavedAsASnippetAndOpensItsEditor() {
        let catalog = RecordingLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog)
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "m")
        vm.currentConversation?.messages.append(QuickMessage(role: .user, content: "Translate: 你好"))
        vm.output = "Hello"
        vm.isActionPalettePresented = true

        vm.saveOutputAsSnippet()

        #expect(catalog.created.map(\.title) == ["Translate: 你好"])
        #expect(catalog.created.map(\.value) == ["Hello"])
        #expect(!vm.isActionPalettePresented)
        #expect(vm.isCatalogActionPanePresented)
        #expect(vm.contextualCatalogItem?.value == "Hello")
    }

    @Test func snippetTitlesAndSearchQueriesComeFromTheFirstUsefulLine() {
        #expect(QuickViewModel.snippetTitle(from: "\n# Heading here\nbody") == "Heading here")
        #expect(QuickViewModel.snippetTitle(from: "   ") == "Quick Launch result")
        let long = String(repeating: "word ", count: 30)
        #expect(QuickViewModel.snippetTitle(from: long).count <= 48)
        #expect(QuickViewModel.searchQuery(from: "- First point\nsecond") == "First point")
    }

    @Test func tunaStoreCreatesSnippetsWithABackup() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-create-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = folder.appendingPathComponent("Tuna.plist")
        let config = folder.appendingPathComponent("config.toml")
        let nested = try PropertyListSerialization.data(
            fromPropertyList: [["kind": "text", "id": "one", "label": "Greeting", "value": "Hello"]],
            format: .binary, options: 0
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CustomItemsCatalogItems": nested], format: .binary, options: 0
        )
        try plist.write(to: preferences)
        try "".write(to: config, atomically: true, encoding: .utf8)

        let service = TunaCatalogService(preferencesURL: preferences, configURL: config)
        let created = try service.createSnippet(title: "Sign-off", value: "Best regards")
        #expect(created.kind == .snippet)
        #expect(created.title == "Sign-off")
        #expect(service.snippets.map(\.title) == ["Greeting", "Sign-off"])

        let reloaded = TunaCatalogService(preferencesURL: preferences, configURL: config)
        #expect(reloaded.snippets.contains { $0.title == "Sign-off" && $0.value == "Best regards" })
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains("quick-launch-backup") }
        #expect(backups.count == 1)

        #expect(throws: TunaCatalogService.MutationError.self) {
            try service.createSnippet(title: " ", value: "x")
        }
    }
}

private final class FakeScreenshotService: ScreenshotCapturing {
    struct Call {
        let kind: ScreenshotKind
        let target: SelectionTarget?
        let ownProcess: pid_t
    }

    var isScreenRecordingAuthorized = true
    var failure: Error?
    var captured: [Call] = []

    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment {
        captured.append(Call(kind: kind, target: target, ownProcess: ownProcess))
        if let failure { throw failure }
        return ScreenshotWorkflowTests.sampleAttachmentForFake
    }
}

extension ScreenshotWorkflowTests {
    static var sampleAttachmentForFake: QuickImageAttachment { sampleAttachment }
}

private final class RecordingLauncherCatalog: LauncherCatalogServicing {
    var snippets: [LauncherCatalogItem] = []
    var quickLinks: [LauncherCatalogItem] = []
    var created: [LauncherCatalogItem] = []

    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        let item = LauncherCatalogItem(
            kind: .snippet, itemID: "new-\(created.count)", title: title, detail: "Snippet", value: value
        )
        created.append(item)
        snippets.append(item)
        return item
    }
}
