import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Transform source and lifecycle safety", .serialized)
@MainActor
struct QuickAIInputSafetyTests {
    private func settings(_ action: SavedPrompt? = nil) -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        if let action { settings.savedPrompts = [action] }
        return settings
    }

    @Test func reviewEncodingIsReadableByThePriorOutputSchema() throws {
        let action = SavedPrompt(alias: "edit", prompt: "Edit", outputBehavior: .reviewChanges)
        let data = try JSONEncoder().encode(action)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["outputBehavior"] as? String == "showInOverlay")
        #expect(object["reviewBeforeReplacing"] as? Bool == true)
        struct PriorSchema: Decodable {
            enum Output: String, Decodable { case showInOverlay, replaceSelection }
            let outputBehavior: Output
            let alias: String
        }
        let prior = try JSONDecoder().decode(PriorSchema.self, from: data)
        #expect(prior.outputBehavior == .showInOverlay)
        #expect(prior.alias == "edit")
        #expect(try JSONDecoder().decode(SavedPrompt.self, from: data).outputBehavior == .reviewChanges)
        let unknown = Data("\"future-output\"".utf8)
        #expect(try JSONDecoder().decode(ActionOutputBehavior.self, from: unknown) == .showInOverlay)
    }

    @Test func templateInputsNeverExecuteBracesInsideSourceData() {
        let action = SavedPrompt(alias: "edit", prompt: "For {argument name=\"audience\"}: {selection}")
        let source = "Keep {date}, {clipboard}, {selection} and {argument name=\"secret\"} literal."
        let result = SavedPromptResolver.prompt(for: action, source: source, arguments: ["Reader"], clipboard: "PRIVATE")
        #expect(result == "For Reader: " + source)
        #expect(!result.contains("PRIVATE"))
        #expect(SavedPromptResolver.readsClipboard("Use {Clipboard}"))
        #expect(!SavedPromptResolver.readsClipboard("Use the copied source"))
    }

    @Test func aTypedAliasMustCollectRequiredInputsBeforeSending() async throws {
        let action = SavedPrompt(alias: "edit", prompt: "For {argument name=\"audience\"}: {selection}")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Result", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(action), service: service)
        vm.openQuickAI()
        vm.input = "/edit Typed source"
        await vm.submit()
        #expect(vm.isTransformArgumentFieldPresented)
        #expect(await service.sendCallCount == 0)
        #expect(vm.pendingTransformArguments?.source == "Typed source")
        vm.transformArgumentInput = "My reader"
        await vm.submitTransformArgument()
        #expect(await service.sendCallCount == 1)
        #expect(await service.lastPrompt?.contains("For My reader: Typed source") == true)
    }

    @Test(arguments: [ActionOutputBehavior.reviewChanges, .replaceSelection])
    func typedSourceNeverOverwritesAnUnrelatedLaunchSelection(_ behavior: ActionOutputBehavior) async throws {
        let action = SavedPrompt(alias: "edit", prompt: "Edit: {selection}", outputBehavior: behavior)
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Transformed B", finishReason: "stop")])
        let selection = InputSafetySelection("Original A")
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(settings: settings(action), service: service, selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.captureLaunchSelection()
        vm.openQuickAI()
        vm.input = "/edit Original B"
        await vm.submit()
        if behavior == .reviewChanges {
            #expect(vm.pendingTransformReview?.original == "Original B")
            #expect(vm.pendingTransformReview?.target == nil)
            #expect(await vm.acceptTransformReview() == false)
        }
        #expect(selection.replacements.isEmpty)
        #expect(pasteboard.string == "Transformed B")
    }

    @Test func reviewTargetIsFrozenBeforeTheModelRuns() async throws {
        let action = SavedPrompt(alias: "edit", prompt: "Edit: {selection}", outputBehavior: .reviewChanges)
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Rewritten A", finishReason: "stop")])
        let selection = InputSafetySelection("Original A")
        let vm = QuickViewModel(settings: settings(action), service: service, selectedTextService: selection, pasteboard: FakePasteboard())
        vm.rememberSelectionTarget(selection.target)
        vm.captureLaunchSelection()
        vm.openQuickAI()
        vm.input = "/edit"
        let request = try #require(await vm.prepareRequest())
        #expect(request.actionTarget?.text == "Original A")
        selection.text = "Original B"
        vm.captureLaunchSelection()
        await vm.stream(request, startsNewChat: true)
        #expect(vm.pendingTransformReview?.target?.text == "Original A")
        #expect(await vm.acceptTransformReview() == false)
        #expect(selection.replacements.isEmpty)
    }

    @Test(arguments: ["close", "layers", "clear", "new", "mode"])
    func leavingTheSurfaceDropsAnInvisibleReview(_ route: String) async {
        let selection = InputSafetySelection("Original")
        let vm = QuickViewModel(settings: settings(), service: MockQuickService(), selectedTextService: selection)
        vm.openQuickAI()
        vm.pendingTransformReview = .init(original: "Original", proposed: "Replacement", sourceApp: "Fixture", target: .init(target: selection.target, text: "Original"))
        switch route {
        case "close": vm.closeQuickAI()
        case "layers": vm.reset(.layers)
        case "clear": vm.clearTransientDisplay()
        case "new": vm.startNewConversation()
        default: vm.enterInputMode(.caffeinateUntil)
        }
        #expect(vm.pendingTransformReview == nil)
        #expect(await vm.acceptTransformReview() == false)
        #expect(selection.replacements.isEmpty)
    }

    @Test func escapeDropsAnAbandonedOptionSelection() async {
        let action = SavedPrompt(alias: "edit", prompt: "{argument name=\"tone\" options=\"Brief,Friendly\"}: {selection}")
        let service = MockQuickService()
        let vm = QuickViewModel(settings: settings(action), service: service)
        vm.openQuickAI()
        await vm.beginTransformArguments(action: action, source: "Fixture")
        #expect(vm.pendingTransformArguments != nil)
        vm.closeTransformChooser()
        #expect(vm.pendingTransformArguments == nil)
        #expect(!vm.isTransformChooserPresented)
        await vm.chooseTransformArgument(index: 0)
        #expect(await service.sendCallCount == 0)
    }

    @Test func removingTheChosenSourceRemovesItsTransformAffordance() async {
        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        vm.explicitTransformSource = "Clipboard source"
        vm.explicitTransformSourceLabel = "Clipboard"
        vm.attachmentTray.add(.selection("Clipboard source", appName: "Clipboard"))
        await vm.attachmentTray.waitUntilRead()
        #expect(vm.selectionTransformSource == "Clipboard source")
        vm.attachmentTray.removeAll()
        #expect(vm.selectionTransformSource == nil)
        #expect(!vm.hasTransformSource)
    }

    @Test func bracesInsideLiveSelectionStayLiteralDuringPreparation() async throws {
        let source = "Literal {selection}, {clipboard} and {date}"
        let action = SavedPrompt(alias: "edit", prompt: "Edit: {selection}")
        let selection = InputSafetySelection(source)
        let vm = QuickViewModel(settings: settings(action), service: MockQuickService(), selectedTextService: selection)
        vm.rememberSelectionTarget(selection.target)
        vm.captureLaunchSelection()
        vm.input = "/edit"
        let request = try #require(await vm.prepareRequest())
        #expect(request.effectivePrompt == "Edit: " + source)
        #expect(request.actionSource == source)
    }

    @Test func aBareAliasUsesTheExplicitClipboardSourceNotTheLaunchSelection() async {
        let action = SavedPrompt(alias: "edit", prompt: "Edit: {selection}", outputBehavior: .replaceSelection)
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Rewritten B", finishReason: "stop")])
        let selection = InputSafetySelection("Original A")
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(settings: settings(action), service: service, selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.captureLaunchSelection()
        vm.attachmentTray.add(.clipboard("Original B", appName: nil))
        await vm.attachmentTray.waitUntilRead()
        vm.input = "/edit"
        await vm.submit()
        #expect(await service.lastPrompt?.contains("Edit: Original B") == true)
        #expect(selection.replacements.isEmpty)
        #expect(pasteboard.string == "Rewritten B")
    }

    @Test func cancellingATypedAliasArgumentPreservesItsLaunchChip() async {
        let action = SavedPrompt(alias: "edit", prompt: "For {argument name=\"audience\"}: {selection}")
        let service = MockQuickService()
        let selection = InputSafetySelection("Original A")
        let vm = QuickViewModel(settings: settings(action), service: service, selectedTextService: selection)
        vm.rememberSelectionTarget(selection.target)
        vm.captureLaunchSelection()
        vm.input = "/edit"
        await vm.submit()
        #expect(vm.launchSelection?.text == "Original A")
        #expect(vm.handleEscapeKey())
        #expect(vm.launchSelection?.text == "Original A")
        #expect(await service.sendCallCount == 0)
    }

    @Test func aRootAliasWithoutASourceHasAVisibleArgumentField() async {
        let action = SavedPrompt(alias: "draft", prompt: "Write for {argument name=\"audience\"}")
        let vm = QuickViewModel(settings: settings(action), service: MockQuickService())
        vm.input = "/draft"
        await vm.submit()
        #expect(vm.isQuickAIPresented)
        #expect(vm.isTransformArgumentFieldPresented)
    }

    @Test func savedCaptureNameMatchesItsEncodedImageType() {
        #expect(QuickViewModel.screenshotFileName(now: Date(timeIntervalSince1970: 0), mimeType: "image/jpeg").hasSuffix(".jpeg")
            || QuickViewModel.screenshotFileName(now: Date(timeIntervalSince1970: 0), mimeType: "image/jpeg").hasSuffix(".jpg"))
        #expect(QuickViewModel.screenshotFileName(now: Date(timeIntervalSince1970: 0)).hasSuffix(".png"))
    }

    @Test func textOnlyHasNoWireToolsEvenWhenClarificationIsEnabled() throws {
        var settings = settings()
        settings.quickAIClarifyingQuestionsEnabled = true
        let provider = try #require(settings.providers.first { $0.kind == .openAICompatible })
        let vm = QuickViewModel(settings: settings)
        let plain = try #require(vm.makeService(provider: provider, model: provider.selectedModel, textOnly: true) as? OpenAICompatibleService)
        let request = try plain.buildRequest(prompt: "Rewrite this text")
        let requestData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(body["tools"] == nil)
        let ordinary = try #require(vm.makeService(provider: provider, model: provider.selectedModel) as? OpenAICompatibleService)
        let ordinaryRequest = try ordinary.buildRequest(prompt: "Question")
        let ordinaryData = try #require(ordinaryRequest.httpBody)
        let ordinaryBody = try #require(JSONSerialization.jsonObject(with: ordinaryData) as? [String: Any])
        let tools = ordinaryBody["tools"] as? [[String: Any]] ?? []
        #expect(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "ask_user_question" })
    }
}

@MainActor
private final class InputSafetySelection: SelectedTextServicing {
    var isAccessibilityTrusted = true
    let target = SelectionTarget(processIdentifier: 91001, applicationName: "Fixture editor")
    var text: String
    var replacements: [String] = []
    init(_ text: String) { self.text = text }
    func currentExternalTarget() -> SelectionTarget? { target }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { .init(target: target, text: text) }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { replacements.append(text); return true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}
