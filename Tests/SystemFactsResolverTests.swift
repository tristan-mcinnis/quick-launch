import Foundation
import Testing
@testable import apfel_quick

@Suite("System facts resolver")
struct SystemFactsResolverTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_787_298_300)
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func answersDateAndTime() {
        let answer = SystemFactsResolver.answer(
            "What's the current date and time?",
            now: fixedDate,
            locale: locale,
            timeZone: timeZone
        )
        #expect(answer?.contains("2026") == true)
        #expect(answer?.contains("UTC+8") == true)
    }

    @Test func recognisesCommonTimeQuestions() {
        #expect(SystemFactsResolver.classify("What time is it?") == .time)
        #expect(SystemFactsResolver.classify("current time") == .time)
        #expect(SystemFactsResolver.classify("time now please") == .time)
    }

    @Test func recognisesDateDayAndTimeZoneQuestions() {
        #expect(SystemFactsResolver.classify("today's date") == .date)
        #expect(SystemFactsResolver.classify("what day is it?") == .day)
        #expect(SystemFactsResolver.classify("what timezone am I in?") == .timeZone)
    }

    @Test func leavesNormalPromptsForTheModel() {
        #expect(SystemFactsResolver.answer("Explain how time zones work") == nil)
        #expect(SystemFactsResolver.answer("Plan a date night") == nil)
        #expect(SystemFactsResolver.answer("Write a current affairs summary") == nil)
    }
}
