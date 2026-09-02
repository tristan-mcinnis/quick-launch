import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Core features: emoji, translate, caffeinate, latest screenshot", .serialized)
@MainActor
struct CoreFeatureTests {
    // MARK: Emoji & Symbols

    @Test func emojiCatalogIsLargeNamedAndSearchable() {
        let items = EmojiCatalog.items
        #expect(items.count > 1_200)
        #expect(items.allSatisfy { $0.kind == .emoji && !$0.title.isEmpty && !$0.value.isEmpty })
        #expect(Set(items.map(\.id)).count == items.count)

        let vm = QuickViewModel()
        vm.enterCatalog(.emoji)
        vm.input = "fire"
        #expect(vm.catalogMatches.first?.value == "🔥")
        vm.input = "thumbs up"
        #expect(vm.catalogMatches.first?.value == "👍")
        vm.input = "command"
        #expect(vm.catalogMatches.contains { $0.value == "⌘" })
        vm.input = "check"
        #expect(vm.catalogMatches.prefix(2).contains { $0.value.unicodeScalars.first == "✅" })
        vm.input = "warning"
        #expect(vm.catalogMatches.first?.value.unicodeScalars.first == "⚠")
        vm.input = "rocket"
        #expect(vm.catalogMatches.first?.value == "🚀")
        vm.input = "china"
        #expect(vm.catalogMatches.first?.value == "🇨🇳")
    }

    @Test func emojiRootAndActions() {
        let vm = QuickViewModel()
        vm.input = "emoji"
        #expect(vm.launcherMatches.contains(.catalog(.emoji, count: EmojiCatalog.items.count)))
        vm.enterCatalog(.emoji)
        vm.input = "sparkles"
        let first = vm.launcherMatches.first!
        #expect(vm.focusedItemActions.map(\.title) == ["Paste to Active App", "Copy to Clipboard"])
        vm.handleCommandK()
        #expect(vm.contextualCatalogItem?.value.unicodeScalars.first == "✨")
        #expect(first == .item(vm.contextualCatalogItem!))
    }

    @Test func emojiPasteCopiesWhenNoTargetExists() async {
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(pasteboard: pasteboard)
        vm.enterCatalog(.emoji)
        vm.input = "rocket"
        await vm.submitResolvingFuzzyAlias()
        #expect(pasteboard.string == "🚀")
    }

    // MARK: Translate

    @Test func translationDirectionFollowsTheScript() {
        #expect(TranslationDirection.detect("你好，世界") == .toEnglish)
        #expect(TranslationDirection.detect("こんにちは") == .toEnglish)
        #expect(TranslationDirection.detect("hello world") == .toChinese)
        #expect(TranslationDirection.detect("hello 你好") == .toChinese)
        #expect(TranslationDirection.detect("明天 meeting at 3pm 可以吗") == .toEnglish)
        #expect(TranslationDirection.detect("12345") == .toChinese)
    }

    @Test func shiftReturnTranslatesTheTypedTextThroughTheSavedPrompt() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "你好", finishReason: "stop")])
        let vm = QuickViewModel(service: mock)
        vm.input = "hello there"
        #expect(vm.translationDirection == .toChinese)
        #expect(vm.footerHints.map(\.label).contains("To Chinese"))
        await vm.translateInput()
        let sent = await mock.lastPrompt ?? ""
        #expect(sent.contains("Simplified Chinese"))
        #expect(sent.contains("hello there"))
        #expect(!sent.contains("{selection}"))
        #expect(vm.output == "你好")

        vm.startNewConversation()
        vm.input = "谢谢"
        #expect(vm.translationDirection == .toEnglish)
        await vm.translateInput()
        let sentBack = await mock.lastPrompt ?? ""
        #expect(sentBack.contains("to English"))
        #expect(sentBack.contains("谢谢"))
    }

    @Test func defaultsAndMigrationIncludeTheChinesePrompt() throws {
        #expect(QuickSettings().savedPrompts.contains { $0.alias == "zh" })
        let legacy = #"""
        {"configurationVersion":13,"savedPrompts":[{"alias":"translate","prompt":"x {selection}"}]}
        """#
        let migrated = try JSONDecoder().decode(QuickSettings.self, from: Data(legacy.utf8))
        #expect(migrated.savedPrompts.map(\.alias) == ["translate", "zh"])
    }

    // MARK: Caffeinate

    @Test func timedCaffeinateCommandsRunAndExpire() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        manager.onChange = { [weak vm] in vm?.syncCaffeinateState() }
        let titles = vm.systemCommands.filter { $0.value.hasPrefix("caffeinate.") }.map(\.title)
        #expect(titles == [
            "Turn Caffeinate On", "Caffeinate Until…", "Caffeinate for 30 Minutes", "Caffeinate for 1 Hour",
            "Caffeinate for 2 Hours", "Caffeinate for 4 Hours", "Agent Watch: On", "Caffeinate Status",
        ])
        #expect(vm.caffeinateItems.map(\.itemID).first == "caffeinate.toggle")
        #expect(vm.caffeinateItems.count == 8)
        let oneHour = vm.systemCommands.first { $0.value == "caffeinate.60" }!
        vm.performSystemCommand(oneHour)
        #expect(manager.enabledFor == 3_600)
        #expect(vm.isCaffeinating)
        #expect(vm.caffeinateEndsAt != nil)
        #expect(!vm.settings.caffeinateEnabled)
        #expect(vm.settings.caffeinateUntil != nil)
        #expect(vm.systemCommands.first { $0.value == "caffeinate.toggle" }?.detail.hasPrefix("Awake until") == true)

        manager.expire()
        #expect(!vm.isCaffeinating)
        #expect(vm.systemCommands.first { $0.value == "caffeinate.toggle" }?.title == "Turn Caffeinate On")

        vm.performSystemCommand(vm.systemCommands.first { $0.value == "caffeinate.agentWatch" }!)
        #expect(!vm.settings.caffeinateAgentWatch)
        #expect(manager.isAgentWatchEnabled == false)
        #expect(vm.systemCommands.first { $0.value == "caffeinate.agentWatch" }?.title == "Agent Watch: Off")

        vm.performSystemCommand(vm.systemCommands.first { $0.value == "caffeinate.status" }!)
        #expect(vm.output == manager.statusSummary)
        #expect(vm.lastQuestion == "Caffeinate status")
    }

    // MARK: Latest screenshot

    @Test func latestScreenshotPicksTheNewestFileAndAttachesIt() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func write(_ name: String, date: Date) throws {
            let image = NSImage(size: NSSize(width: 2, height: 2))
            image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let url = folder.appendingPathComponent(name)
            try png.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try write("Screenshot 2026-08-20 at 10.00.00.png", date: Date(timeIntervalSinceNow: -200))
        try write("Screenshot 2026-08-22 at 11.00.00.png", date: Date(timeIntervalSinceNow: -10))
        try write("unrelated.png", date: Date())
        try "not an image".write(to: folder.appendingPathComponent("Screenshot notes.txt"), atomically: true, encoding: .utf8)

        #expect(LatestScreenshotFinder.newestScreenshot(in: folder)?.lastPathComponent == "Screenshot 2026-08-22 at 11.00.00.png")

        let vm = QuickViewModel()
        vm.screenshotsFolder = folder
        #expect(vm.attachLatestScreenshot())
        #expect((vm.pendingImage?.pixelWidth ?? 0) >= 2)   // 2 pt, rendered at the display scale
        #expect(vm.systemCommands.contains { $0.value == LatestScreenshotFinder.commandID })

        let empty = QuickViewModel()
        empty.screenshotsFolder = folder.appendingPathComponent("missing")
        #expect(!empty.attachLatestScreenshot())
        #expect(empty.errorMessage?.contains("No screenshot found") == true)
    }
}

@MainActor
private final class RecordingCaffeinateManager: CaffeinateManaging {
    private(set) var isEnabled = false
    private(set) var endsAt: Date?
    var reason: String? { isEnabled ? "Caffeinated." : nil }
    var statusSummary: String { isEnabled ? "☕ Caffeinated." : "Decaffeinated. Normal Mac sleep is enabled." }
    var isAgentWatchEnabled = true
    var batteryCutoff = 20
    var keepsDisplayAwake = false
    var onChange: (() -> Void)?
    var enabledFor: TimeInterval?

    func setEnabled(_ enabled: Bool) -> Bool {
        isEnabled = enabled
        endsAt = nil
        onChange?()
        return true
    }

    func enable(for duration: TimeInterval) -> Bool {
        isEnabled = true
        enabledFor = duration
        endsAt = Date().addingTimeInterval(duration)
        onChange?()
        return true
    }

    func enable(until date: Date) -> Bool {
        enable(for: date.timeIntervalSinceNow)
    }

    func expire() {
        isEnabled = false
        endsAt = nil
        onChange?()
    }
}
