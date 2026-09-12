import Foundation

/// Answers unit conversions, date arithmetic, and "time in <city>" questions offline,
/// without involving an AI provider. Returns nil for anything it does not understand.
enum LocalConversionResolver {

    static func answer(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        let query = normalized(input)
        guard !query.isEmpty else { return nil }
        var calendar = calendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        let context = Context(now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        let tokens = query.split(separator: " ").map(String.init)
        return convertUnits(tokens, context)
            ?? dateArithmetic(tokens, context)
            ?? cityTime(tokens, context)
    }

    private struct Context {
        let now: Date
        let calendar: Calendar
        let locale: Locale
        let timeZone: TimeZone
    }

    // MARK: — Normalisation

    private static let leadingFillers = [
        "convert", "what is", "whats", "what date is", "what day is", "what day will it be",
        "what will the date be", "how many", "how much", "tell me", "please", "the",
    ]

    private static func normalized(_ input: String) -> String {
        var text = expandFeetAndInchMarks(input.lowercased())
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        for (symbol, word) in [("->", " to "), ("→", " to "), ("=", " to ")] {
            text = text.replacingOccurrences(of: symbol, with: word)
        }
        text = stripThousandsCommas(text)
        text = String(text.map { ",?!".contains($0) ? " " : $0 })
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        var stripped = true
        while stripped {
            stripped = false
            for filler in leadingFillers where text == filler || text.hasPrefix(filler + " ") {
                text = String(text.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        if text.hasPrefix("how long ") {
            text = "days " + text.dropFirst("how long ".count)
        }
        return text
    }

    private static let footMarks: Set<Character> = ["'", "’", "′"]
    private static let inchMarks: Set<Character> = ["\"", "”", "″"]

    /// Writes the surveyor's marks as words before apostrophes are stripped for
    /// "what's": 5'11" and 5'11 both become "5 ft 11 in", and 6" becomes "6 in".
    /// A mark only counts with a digit in front of it, so ordinary prose and
    /// quoted text keep their punctuation.
    private static func expandFeetAndInchMarks(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let digitBefore = index > 0 && chars[index - 1].isNumber
            guard digitBefore, footMarks.contains(char) || inchMarks.contains(char) else {
                result.append(char)
                index += 1
                continue
            }
            index += 1
            guard footMarks.contains(char) else { result.append(" in "); continue }
            // A foot mark: the number after it is inches, marked or not.
            result.append(" ft ")
            var inches = ""
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                inches.append(chars[index])
                index += 1
            }
            guard !inches.isEmpty else { continue }
            result.append(inches + " in ")
            if index < chars.count, inchMarks.contains(chars[index]) { index += 1 }
        }
        return result
    }

    /// Removes commas used as thousands separators ("1,000") and leaves every other comma alone.
    private static func stripThousandsCommas(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        for (index, char) in chars.enumerated() {
            guard char == "," else { result.append(char); continue }
            let digitBefore = index > 0 && chars[index - 1].isNumber
            let following = chars[(index + 1)...].prefix(3)
            let threeDigitsAfter = following.count == 3 && following.allSatisfy(\.isNumber)
            if !(digitBefore && threeDigitsAfter) { result.append(char) }
        }
        return result
    }

    private static func number(from token: String) -> Double? {
        switch token {
        case "a", "an", "one": return 1
        default:
            guard let value = Double(token), value.isFinite else { return nil }
            return value
        }
    }

    private static func singular(_ word: String) -> String {
        word.count > 1 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    // MARK: — Unit conversion

    private enum Dimension { case length, mass, temperature, volume, data, speed, area, time }

    private struct Unit {
        let symbol: String
        let plural: String?
        let dimension: Dimension
        /// Multiplier to the dimension's base unit. Unused for temperature.
        let factor: Double
    }

    private static let connectors: Set<String> = ["to", "in", "as", "into"]
    private static let unitFillers: Set<String> = ["degrees", "degree", "deg", "of"]

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ names: [String], _ symbol: String, _ dimension: Dimension, _ factor: Double, plural: String? = nil) {
            let unit = Unit(symbol: symbol, plural: plural, dimension: dimension, factor: factor)
            for name in names { table[name] = unit }
        }
        // Length (metre)
        add(["km", "kilometer", "kilometre"], "km", .length, 1000)
        add(["m", "meter", "metre"], "m", .length, 1)
        add(["cm", "centimeter", "centimetre"], "cm", .length, 0.01)
        add(["mm", "millimeter", "millimetre"], "mm", .length, 0.001)
        add(["mi", "mile"], "mi", .length, 1609.344)
        add(["yd", "yard"], "yd", .length, 0.9144)
        add(["ft", "foot", "feet"], "ft", .length, 0.3048)
        add(["in", "inch", "inches"], "in", .length, 0.0254)
        add(["nmi", "nautical mile"], "nmi", .length, 1852)
        // Mass (kilogram)
        add(["kg", "kilogram", "kilo"], "kg", .mass, 1)
        add(["g", "gram"], "g", .mass, 0.001)
        add(["mg", "milligram"], "mg", .mass, 0.000001)
        add(["t", "tonne", "ton", "metric ton"], "t", .mass, 1000)
        add(["lb", "lbs", "pound"], "lb", .mass, 0.45359237)
        add(["oz", "ounce"], "oz", .mass, 0.028349523125)
        add(["st", "stone"], "st", .mass, 6.35029318)
        // Temperature (converted through Celsius; see convert)
        add(["c", "°c", "celsius", "centigrade"], "°C", .temperature, 1)
        add(["f", "°f", "fahrenheit"], "°F", .temperature, 1)
        add(["k", "kelvin"], "K", .temperature, 1)
        // Volume (litre, US customary for gal/qt/pt/cup/fl oz)
        add(["l", "liter", "litre"], "L", .volume, 1)
        add(["ml", "milliliter", "millilitre"], "mL", .volume, 0.001)
        add(["gal", "gallon"], "gal", .volume, 3.785411784)
        add(["qt", "quart"], "qt", .volume, 0.946352946)
        add(["pt", "pint"], "pt", .volume, 0.473176473)
        add(["cup"], "cup", .volume, 0.2365882365, plural: "cups")
        add(["floz", "fl oz", "fluid ounce"], "fl oz", .volume, 0.0295735295625)
        add(["tbsp", "tablespoon"], "tbsp", .volume, 0.01478676478125)
        add(["tsp", "teaspoon"], "tsp", .volume, 0.00492892159375)
        // Data (byte; decimal and binary prefixes)
        add(["b", "byte"], "B", .data, 1)
        add(["kb", "kilobyte"], "KB", .data, 1e3)
        add(["mb", "megabyte"], "MB", .data, 1e6)
        add(["gb", "gigabyte"], "GB", .data, 1e9)
        add(["tb", "terabyte"], "TB", .data, 1e12)
        add(["kib", "kibibyte"], "KiB", .data, 1024)
        add(["mib", "mebibyte"], "MiB", .data, 1024 * 1024)
        add(["gib", "gibibyte"], "GiB", .data, 1024 * 1024 * 1024)
        add(["tib", "tebibyte"], "TiB", .data, 1024 * 1024 * 1024 * 1024)
        // Speed (metre per second)
        add(["km/h", "kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour"], "km/h", .speed, 1 / 3.6)
        add(["mph", "mi/h", "miles per hour"], "mph", .speed, 0.44704)
        add(["m/s", "mps", "meters per second", "metres per second"], "m/s", .speed, 1)
        add(["knot", "kn", "kt"], "kn", .speed, 0.514444)
        // Area (square metre)
        add(["m2", "m²", "sqm", "sq m", "square meter", "square metre"], "m²", .area, 1)
        add(["km2", "km²", "sq km", "square kilometer", "square kilometre"], "km²", .area, 1e6)
        add(["sqft", "sq ft", "ft2", "ft²", "square foot", "square feet"], "sq ft", .area, 0.09290304)
        add(["acre"], "acre", .area, 4046.8564224, plural: "acres")
        add(["ha", "hectare"], "ha", .area, 10000)
        // Time (second)
        add(["ms", "millisecond"], "ms", .time, 0.001)
        add(["s", "sec", "second"], "s", .time, 1)
        add(["min", "minute"], "min", .time, 60)
        add(["h", "hr", "hour"], "h", .time, 3600)
        add(["d", "day"], "day", .time, 86_400, plural: "days")
        add(["w", "wk", "week"], "week", .time, 604_800, plural: "weeks")
        return table
    }()

    private static func unit(for tokens: ArraySlice<String>) -> Unit? {
        let words = tokens.filter { !unitFillers.contains($0) }
        guard !words.isEmpty else { return nil }
        let name = words.joined(separator: " ")
        if let unit = units[name] { return unit }
        if name.hasSuffix("s"), let unit = units[String(name.dropLast())] { return unit }
        return nil
    }

    /// Splits "72f" into "72" and "f" so attached units parse like spaced ones.
    private static func splitNumbersFromUnits(_ tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            var chars = Array(token)
            var prefix = ""
            if chars.first == "-" { prefix = "-"; chars.removeFirst() }
            let numeric = chars.prefix { $0.isNumber || $0 == "." }
            let rest = String(chars.dropFirst(numeric.count))
            guard numeric.contains(where: \.isNumber), let first = rest.first,
                  first.isLetter || first == "°" else { return [token] }
            return [prefix + String(numeric), rest]
        }
    }

    private static func convertUnits(_ rawTokens: [String], _ context: Context) -> String? {
        let tokens = splitNumbersFromUnits(rawTokens)
        if let compound = convertCompound(tokens, context) { return compound }
        guard tokens.count >= 3, let value = number(from: tokens[0]) else { return nil }
        if tokens.count >= 4 {
            for index in 2..<(tokens.count - 1) where connectors.contains(tokens[index]) {
                guard let source = unit(for: tokens[1..<index]),
                      let target = unit(for: tokens[(index + 1)...]),
                      source.dimension == target.dimension else { continue }
                return formatted(convert(value, from: source, to: target), target: target, context)
            }
        }
        return convertBare(tokens, context)
    }

    /// "5'11 in cm", "6'2\" in cm", "5 ft 11 in cm": a coarse length and a fine
    /// one add up before the connector. Both halves must be lengths and the
    /// first must be the larger unit, so prose cannot reach this shape.
    private static func convertCompound(_ tokens: [String], _ context: Context) -> String? {
        guard tokens.count >= 5,
              let major = number(from: tokens[0]),
              let minor = number(from: tokens[2]),
              let coarse = unit(for: tokens[1..<2]),
              let fine = unit(for: tokens[3..<4]),
              coarse.dimension == .length, fine.dimension == .length,
              coarse.factor > fine.factor
        else { return nil }
        var rest = tokens[4...]
        if let next = rest.first, connectors.contains(next) { rest = rest.dropFirst() }
        guard let target = unit(for: rest), target.dimension == .length else { return nil }
        let base = major * coarse.factor + minor * fine.factor
        return formatted(base / target.factor, target: target, context)
    }

    /// "12kg lb": a bare pair with no connector. It only reads as a conversion
    /// when both words are units of one dimension, which ordinary search text
    /// is not.
    private static func convertBare(_ tokens: [String], _ context: Context) -> String? {
        guard tokens.count == 3, let value = number(from: tokens[0]),
              let source = unit(for: tokens[1..<2]),
              let target = unit(for: tokens[2...]),
              source.dimension == target.dimension,
              source.symbol != target.symbol
        else { return nil }
        return formatted(convert(value, from: source, to: target), target: target, context)
    }

    private static func formatted(_ result: Double, target: Unit, _ context: Context) -> String? {
        guard result.isFinite else { return nil }
        let digits = target.dimension == .temperature ? 1 : (result != 0 && result.magnitude < 0.01 ? 6 : 2)
        let text = formatNumber(result, maximumFractionDigits: digits, locale: context.locale)
        let symbol = text == "1" ? target.symbol : (target.plural ?? target.symbol)
        return "\(text) \(symbol)"
    }

    private static func convert(_ value: Double, from source: Unit, to target: Unit) -> Double {
        guard source.dimension == .temperature else { return value * source.factor / target.factor }
        let celsius: Double
        switch source.symbol {
        case "°F": celsius = (value - 32) * 5 / 9
        case "K": celsius = value - 273.15
        default: celsius = value
        }
        switch target.symbol {
        case "°F": return celsius * 9 / 5 + 32
        case "K": return celsius + 273.15
        default: return celsius
        }
    }

    private static func formatNumber(_ value: Double, maximumFractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%g", value)
    }

    // MARK: — Date arithmetic

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]
    private static let counters: [String: Calendar.Component] = [
        "day": .day, "week": .weekOfYear, "fortnight": .weekOfYear, "month": .month, "year": .year,
    ]

    private static func dateArithmetic(_ tokens: [String], _ context: Context) -> String? {
        if let date = relativeDate(tokens, context) {
            return longDate(date, context)
        }
        return countdown(tokens, context)
    }

    /// "tomorrow", "in 3 days", "2 weeks from now", "10 days ago", "next friday", "last monday".
    private static func relativeDate(_ tokens: [String], _ context: Context) -> Date? {
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        switch tokens {
        case ["today"]: return today
        case ["tomorrow"]: return calendar.date(byAdding: .day, value: 1, to: today)
        case ["yesterday"]: return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }

        if tokens.count == 2, ["next", "this", "last"].contains(tokens[0]),
           let weekday = weekdays.firstIndex(where: { $0 == tokens[1] || ($0.hasPrefix(tokens[1]) && tokens[1].count >= 3) }) {
            let step = tokens[0] == "last" ? -1 : 1
            var date = today
            for _ in 0..<7 {
                guard let next = calendar.date(byAdding: .day, value: step, to: date) else { return nil }
                date = next
                if calendar.component(.weekday, from: date) == weekday + 1 { return date }
            }
            return nil
        }

        let hasIn = tokens.first == "in"
        let words = hasIn ? Array(tokens.dropFirst()) : tokens
        guard words.count >= 2, let amount = number(from: words[0]), amount.magnitude < 100_000,
              let component = counters[singular(words[1])] else { return nil }
        let multiplier = singular(words[1]) == "fortnight" ? 2 : 1
        let suffix = words.dropFirst(2).joined(separator: " ")
        let forward: Set<String> = ["from now", "from today", "later", "ahead", "hence"]
        let backward: Set<String> = ["ago", "back", "earlier"]
        let sign: Int
        if forward.contains(suffix) || (suffix.isEmpty && hasIn) {
            sign = 1
        } else if backward.contains(suffix) {
            sign = -1
        } else {
            return nil
        }
        return calendar.date(byAdding: component, value: sign * multiplier * Int(amount), to: today)
    }

    /// "days until 2026-12-25", "weeks since 1 january", "days until next friday".
    private static func countdown(_ tokens: [String], _ context: Context) -> String? {
        guard tokens.count >= 3 else { return nil }
        let unitName = singular(tokens[0])
        guard unitName == "day" || unitName == "week" else { return nil }
        let direction: Int
        switch tokens[1] {
        case "until", "till", "til", "to", "before": direction = 1
        case "since", "from", "after": direction = -1
        default: return nil
        }
        let rest = Array(tokens[2...])
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        guard let target = absoluteDate(rest, preferFuture: direction == 1, context) ?? relativeDate(rest, context),
              let elapsed = calendar.dateComponents([.day], from: today, to: target).day else { return nil }
        let signed = elapsed * direction
        let count = abs(signed)
        var parts: [String] = []
        if unitName == "week", count >= 7 {
            parts.append(plural(count / 7, "week"))
            if count % 7 != 0 { parts.append(plural(count % 7, "day")) }
        } else {
            parts.append(plural(count, "day"))
        }
        let suffix = signed < 0 ? (direction == 1 ? " ago" : " from now") : ""
        return "\(parts.joined(separator: ", "))\(suffix) (\(longDate(target, context)))"
    }

    private static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    /// "2026-12-25", "25/12/2026", "25 december 2026", "dec 25", "25th of december".
    private static func absoluteDate(_ tokens: [String], preferFuture: Bool, _ context: Context) -> Date? {
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        var day: Int?
        var month: Int?
        var year: Int?
        if tokens.count == 1 {
            let parts = tokens[0].components(separatedBy: CharacterSet(charactersIn: "-/.")).compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            if parts[0] > 31 {
                (year, month, day) = (parts[0], parts[1], parts[2])
            } else {
                (day, month, year) = (parts[0], parts[1], parts[2])
            }
        } else {
            for token in tokens {
                if let index = months.firstIndex(where: { $0 == token || ($0.hasPrefix(token) && token.count >= 3) }) {
                    month = index + 1
                } else if let value = Int(token.trimmingCharacters(in: .letters)) {
                    if value > 31 { year = value } else if day == nil { day = value } else { return nil }
                } else if token != "of" {
                    return nil
                }
            }
        }
        guard let day, let month, (1...31).contains(day), (1...12).contains(month) else { return nil }
        if let year {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        let currentYear = calendar.component(.year, from: today)
        guard let date = calendar.date(from: DateComponents(year: currentYear, month: month, day: day)) else { return nil }
        if preferFuture, date < today {
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
        if !preferFuture, date > today {
            return calendar.date(byAdding: .year, value: -1, to: date)
        }
        return date
    }

    private static func longDate(_ date: Date, _ context: Context) -> String {
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: — Time in a city

    private static let cityTimeZones: [String: String] = [
        "london": "Europe/London", "paris": "Europe/Paris", "berlin": "Europe/Berlin",
        "madrid": "Europe/Madrid", "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam",
        "zurich": "Europe/Zurich", "moscow": "Europe/Moscow", "istanbul": "Europe/Istanbul",
        "dubai": "Asia/Dubai", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "singapore": "Asia/Singapore", "hong kong": "Asia/Hong_Kong", "hongkong": "Asia/Hong_Kong",
        "shanghai": "Asia/Shanghai", "beijing": "Asia/Shanghai", "tokyo": "Asia/Tokyo", "seoul": "Asia/Seoul",
        "bangkok": "Asia/Bangkok", "jakarta": "Asia/Jakarta", "taipei": "Asia/Taipei", "manila": "Asia/Manila",
        "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "auckland": "Pacific/Auckland",
        "honolulu": "Pacific/Honolulu", "los angeles": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "vancouver": "America/Vancouver", "denver": "America/Denver",
        "chicago": "America/Chicago", "new york": "America/New_York", "nyc": "America/New_York",
        "toronto": "America/Toronto", "mexico city": "America/Mexico_City", "sao paulo": "America/Sao_Paulo",
        "buenos aires": "America/Argentina/Buenos_Aires", "johannesburg": "Africa/Johannesburg",
        "cairo": "Africa/Cairo", "lagos": "Africa/Lagos", "utc": "Etc/UTC", "gmt": "Etc/UTC",
    ]

    private static let cityFillers: Set<String> = [
        "what", "whats", "is", "it", "the", "current", "local", "time", "now", "right", "in", "at", "clock",
    ]

    private static func cityTime(_ tokens: [String], _ context: Context) -> String? {
        guard tokens.contains("time") else { return nil }
        let city = tokens.filter { !cityFillers.contains($0) }
            .joined(separator: " ")
            .folding(options: .diacriticInsensitive, locale: nil)
        guard !city.isEmpty, let identifier = cityTimeZones[city],
              let zone = TimeZone(identifier: identifier) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm (EEEE)"
        return "\(formatter.string(from: context.now)), \(zoneLabel(zone, now: context.now))"
    }

    private static func zoneLabel(_ zone: TimeZone, now: Date) -> String {
        let abbreviation = zone.abbreviation(for: now) ?? zone.identifier
        let seconds = zone.secondsFromGMT(for: now)
        let sign = seconds >= 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        let offset = minutes % 60 == 0
            ? "UTC\(sign)\(minutes / 60)"
            : String(format: "UTC%@%d:%02d", sign, minutes / 60, minutes % 60)
        return "\(abbreviation), \(offset)"
    }
}
