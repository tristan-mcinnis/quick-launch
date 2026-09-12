import Foundation
import Testing
@testable import QuickLaunch

@Suite("Local conversion resolver")
struct LocalConversionResolverTests {
    /// Sunday, 23 August 2026 at 10:30 UTC.
    private let fixedNow = Date(timeIntervalSince1970: 1_787_481_000)
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(identifier: "Etc/UTC")!
    private let calendar = Calendar(identifier: .gregorian)

    private func answer(_ input: String) -> String? {
        LocalConversionResolver.answer(
            input,
            now: fixedNow,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }

    // MARK: Length and mass

    @Test func convertsKilometresToMiles() {
        #expect(answer("12 km in miles") == "7.46 mi")
    }

    @Test func convertsKilogramsToPounds() {
        #expect(answer("80 kg to lb") == "176.37 lb")
        #expect(answer("80 KG to LBS") == "176.37 lb")
    }

    @Test func treatsInchesAsAUnitBeforeTheConnector() {
        #expect(answer("12 in in cm") == "30.48 cm")
        #expect(answer("12 inches to cm") == "30.48 cm")
    }

    @Test func acceptsArrowAndEqualsConnectors() {
        #expect(answer("10 mi -> km") == "16.09 km")
        #expect(answer("1 mile = feet") == "5,280 ft")
    }

    @Test func stripsLeadingFillerAndThousandsCommas() {
        #expect(answer("convert 1,000 m to km") == "1 km")
        #expect(answer("What is 5 ft in cm?") == "152.4 cm")
    }

    @Test func convertsStoneAndOunces() {
        #expect(answer("12 st to kg") == "76.2 kg")
        #expect(answer("16 oz in lb") == "1 lb")
    }

    // MARK: Temperature

    @Test func convertsFahrenheitToCelsius() {
        #expect(answer("72f to c") == "22.2 °C")
        #expect(answer("72 °F to °C") == "22.2 °C")
    }

    @Test func convertsCelsiusToFahrenheit() {
        #expect(answer("100 c in f") == "212 °F")
        #expect(answer("-40 fahrenheit to celsius") == "-40 °C")
    }

    @Test func convertsKelvin() {
        #expect(answer("0 k to c") == "-273.2 °C")
    }

    // MARK: Volume, data, speed, area, time

    @Test func convertsVolume() {
        #expect(answer("1 gal in l") == "3.79 L")
        #expect(answer("3 tsp to tbsp") == "1 tbsp")
        #expect(answer("2 cups in ml") == "473.18 mL")
    }

    @Test func convertsDecimalData() {
        #expect(answer("5 gb in mb") == "5,000 MB")
        #expect(answer("1 tb to gb") == "1,000 GB")
    }

    @Test func convertsBinaryData() {
        #expect(answer("1 gib in mib") == "1,024 MiB")
        #expect(answer("1 gb in gib") == "0.93 GiB")
    }

    @Test func convertsSpeed() {
        #expect(answer("100 km/h to mph") == "62.14 mph")
        #expect(answer("10 knots in km/h") == "18.52 km/h")
        #expect(answer("60 mph as m/s") == "26.82 m/s")
    }

    @Test func convertsArea() {
        #expect(answer("1 acre in sqft") == "43,560 sq ft")
        #expect(answer("2 ha to m2") == "20,000 m²")
    }

    @Test func convertsTimeUnits() {
        #expect(answer("90 min in hours") == "1.5 h")
        #expect(answer("2 weeks in days") == "14 days")
        #expect(answer("3600 sec to h") == "1 h")
    }

    @Test func rejectsMismatchedDimensions() {
        #expect(answer("5 kg to km") == nil)
        #expect(answer("3 in 4") == nil)
    }

    // MARK: Date arithmetic

    @Test func addsDaysAndWeeks() {
        #expect(answer("3 days from now") == "Wednesday, 26 August 2026")
        #expect(answer("in 2 weeks") == "Sunday, 6 September 2026")
        #expect(answer("in a week") == "Sunday, 30 August 2026")
    }

    @Test func subtractsDays() {
        #expect(answer("10 days ago") == "Thursday, 13 August 2026")
    }

    @Test func answersTomorrowAndYesterday() {
        #expect(answer("tomorrow") == "Monday, 24 August 2026")
        #expect(answer("yesterday") == "Saturday, 22 August 2026")
        #expect(answer("What day is tomorrow?") == "Monday, 24 August 2026")
    }

    @Test func findsNextAndLastWeekdays() {
        #expect(answer("next friday") == "Friday, 28 August 2026")
        #expect(answer("last monday") == "Monday, 17 August 2026")
        #expect(answer("next sunday") == "Sunday, 30 August 2026")
    }

    @Test func countsDaysUntilADate() {
        #expect(answer("days until 2026-12-25") == "124 days (Friday, 25 December 2026)")
        #expect(answer("how many days until 25 december") == "124 days (Friday, 25 December 2026)")
        #expect(answer("how long until christmas") == nil)
    }

    @Test func countsDaysSinceADate() {
        #expect(answer("days since 2026-01-01") == "234 days (Thursday, 1 January 2026)")
    }

    @Test func countsWeeksUntilADate() {
        #expect(answer("weeks until 2026-12-25") == "17 weeks, 5 days (Friday, 25 December 2026)")
        #expect(answer("days until next friday") == "5 days (Friday, 28 August 2026)")
    }

    // MARK: Time in a city

    @Test func answersTimeInACity() {
        let london = answer("time in london")
        #expect(london?.hasPrefix("11:30 (Sunday)") == true)
        #expect(london?.hasSuffix("UTC+1") == true)

        let tokyo = answer("what time is it in Tokyo?")
        #expect(tokyo?.hasPrefix("19:30 (Sunday)") == true)
        #expect(tokyo?.hasSuffix("UTC+9") == true)
    }

    @Test func handlesMultiWordCitiesAndHalfHourOffsets() {
        let newYork = answer("time in new york")
        #expect(newYork?.hasPrefix("06:30 (Sunday)") == true)
        #expect(newYork?.hasSuffix("UTC−4") == true)

        #expect(answer("mumbai time")?.hasSuffix("UTC+5:30") == true)
        #expect(answer("time in São Paulo")?.hasPrefix("07:30 (Sunday)") == true)
    }

    // MARK: Leaves everything else alone

    @Test func returnsNilForMathQuestionsAndProse() {
        #expect(answer("2 + 2") == nil)
        #expect(answer("12 * 3") == nil)
        #expect(answer("what time is it") == nil)
        #expect(answer("time in narnia") == nil)
        #expect(answer("Explain how time zones work") == nil)
        #expect(answer("Plan a date night") == nil)
        #expect(answer("") == nil)
    }

    // MARK: Feet and inches

    @Test func convertsFeetAndInchMarks() {
        #expect(answer("5'11 in cm") == "180.34 cm")
        #expect(answer("5'11\" to cm") == "180.34 cm")
        #expect(answer("6'2\" in cm") == "187.96 cm")
        #expect(answer("6' in cm") == "182.88 cm")
    }

    @Test func convertsSpelledCompoundLengths() {
        #expect(answer("5 ft 11 in cm") == "180.34 cm")
        #expect(answer("5 feet 11 inches in cm") == "180.34 cm")
        #expect(answer("5 ft 11 in to m") == "1.8 m")
    }

    @Test func rejectsCompoundsThatAreNotTwoOrderedLengths() {
        #expect(answer("5 kg 11 in cm") == nil)
        #expect(answer("5 in 11 ft cm") == nil)
        #expect(answer("whats the plan") == nil)
    }

    // MARK: Bare pairs

    @Test func convertsABarePairWithNoConnector() {
        #expect(answer("12kg lb") == "26.46 lb")
        #expect(answer("12 kg lb") == "26.46 lb")
        #expect(answer("100f c") == "37.8 °C")
    }

    @Test func rejectsBarePairsThatAreNotTwoDistinctUnits() {
        #expect(answer("12 kg kg") == nil)
        #expect(answer("5 things to") == nil)
        #expect(answer("3 in 4") == nil)
    }

    // MARK: Ordinary searches are left alone

    @Test func returnsNilForOrdinarySearchText() {
        for query in [
            "safari", "system preferences", "1password", "notes", "mail", "slack",
            "visual studio code", "final cut pro", "logic pro x", "time machine",
            "kg", "m", "in", "to", "12", "e", "pi", "b", "t", "s",
            "meeting notes", "week in review", "day one", "screen",
            "5 things to do", "top 10 in c", "2 fast 2 furious", "4k video",
            "8 ball pool", "7 zip", "10 things i hate", "3 day weekend plan",
            "open in finder", "go to bed", "add to cart", "move to trash",
            "how to cook", "1 to 1", "5 minute timer", "what is love",
        ] {
            #expect(answer(query) == nil, "\(query) must not answer")
        }
    }
}
