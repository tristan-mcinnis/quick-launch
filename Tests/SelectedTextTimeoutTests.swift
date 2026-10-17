import Testing
@testable import QuickLaunch

@Suite("Selection capture timeout")
struct SelectedTextTimeoutTests {
    @Test("An unresponsive app delays the panel by at most 150 ms")
    func axTimeoutIsShort() {
        #expect(SelectedTextService.axMessagingTimeout == 0.15)
    }
}
