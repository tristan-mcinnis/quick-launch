import Foundation
import Testing
@testable import QuickLaunch

private actor FakePageReader: WebPageReading {
    let content: String
    private(set) var lastURL: URL?

    init(content: String) {
        self.content = content
    }

    func read(_ url: URL) async throws -> String {
        lastURL = url
        return content
    }
}

@Suite("Page reading workflow", .serialized)
@MainActor
struct WebPageWorkflowTests {
    @Test func promptWithURLFetchesThePageAndAnswersFromIt() async {
        let reader = FakePageReader(content: "Canberra is the capital of Australia.")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "It is Canberra.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, pageReader: reader)
        vm.input = "what is the capital? https://example.com/canberra"

        await vm.submit()

        #expect(await reader.lastURL?.absoluteString == "https://example.com/canberra")
        let prompt = await ai.lastPrompt ?? ""
        #expect(prompt.contains("https://example.com/canberra"))
        #expect(prompt.contains("Canberra is the capital of Australia."))
        #expect(prompt.contains("untrusted_web_content"))
        // History keeps what the user typed, not the augmented prompt.
        #expect(vm.currentConversation?.messages.first?.content
            == "what is the capital? https://example.com/canberra")
        #expect(vm.output == "It is Canberra.")
    }

    @Test func failedReadStillSubmitsWithANote() async {
        struct BrokenReader: WebPageReading {
            func read(_ url: URL) async throws -> String {
                throw PageReadError.timedOut
            }
        }
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Cannot tell.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, pageReader: BrokenReader())
        vm.input = "summarize https://example.com/slow"

        await vm.submit()

        let prompt = await ai.lastPrompt ?? ""
        #expect(prompt.contains("Could not read this page"))
        #expect(vm.output == "Cannot tell.")
    }

    @Test func promptsWithoutURLsSkipTheReader() async {
        let reader = FakePageReader(content: "unused")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Plain answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, pageReader: reader)
        vm.input = "plain question, no links"

        await vm.submit()

        #expect(await reader.lastURL == nil)
        #expect(await ai.lastPrompt?.contains("untrusted_web_content") != true)
    }
}
