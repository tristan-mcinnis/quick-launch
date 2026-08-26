import Foundation

/// The text shape a picked color is copied in. Stored in settings by raw value.
enum ColorFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case hex
    case rgb
    case hsl
    case hsb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "Hex"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .hsb: "HSB"
        }
    }

    /// Shown beside the title in Settings and in the ⌘K action list.
    var sample: String {
        switch self {
        case .hex: "#4A90D9"
        case .rgb: "rgb(74, 144, 217)"
        case .hsl: "hsl(210, 65%, 57%)"
        case .hsb: "hsb(210, 66%, 85%)"
        }
    }
}

/// One color sampled from the screen, held as sRGB components in 0...1.
/// The struct is pure so every conversion is testable without a screen.
struct PickedColor: Equatable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Accepts `#RGB`, `#RRGGBB`, and `#RRGGBBAA`, with or without the hash.
    init?(hexString: String) {
        var digits = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let scaled: [Double]
        switch digits.count {
        case 3:
            scaled = digits.map { Double(UInt8(String($0), radix: 16)!) / 15 }
        case 6, 8:
            scaled = stride(from: 0, to: digits.count, by: 2).map { offset in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let end = digits.index(start, offsetBy: 2)
                return Double(UInt8(digits[start..<end], radix: 16)!) / 255
            }
        default:
            return nil
        }
        self.init(
            red: scaled[0],
            green: scaled[1],
            blue: scaled[2],
            alpha: scaled.count == 4 ? scaled[3] : 1
        )
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    // MARK: - Components

    var red255: Int { Int((red * 255).rounded()) }
    var green255: Int { Int((green * 255).rounded()) }
    var blue255: Int { Int((blue * 255).rounded()) }
    var isOpaque: Bool { alpha >= 0.999 }

    /// Hue in degrees 0..<360, saturation and lightness in 0...1.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        return (hueDegrees(maximum: maximum, delta: delta), min(saturation, 1), lightness)
    }

    /// Hue in degrees 0..<360, saturation and brightness in 0...1.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let delta = maximum - min(red, green, blue)
        guard delta > 0 else { return (0, 0, maximum) }
        return (hueDegrees(maximum: maximum, delta: delta), delta / maximum, maximum)
    }

    private func hueDegrees(maximum: Double, delta: Double) -> Double {
        let hue: Double
        switch maximum {
        case red: hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = 60 * ((blue - red) / delta + 2)
        default: hue = 60 * ((red - green) / delta + 4)
        }
        return hue < 0 ? hue + 360 : hue
    }

    // MARK: - Text

    /// `#4A90D9`, gaining two more digits when the color carries alpha.
    var hexString: String {
        let base = String(format: "#%02X%02X%02X", red255, green255, blue255)
        guard !isOpaque else { return base }
        return base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    var rgbString: String {
        guard !isOpaque else { return "rgb(\(red255), \(green255), \(blue255))" }
        return "rgba(\(red255), \(green255), \(blue255), \(Self.decimal(alpha)))"
    }

    var hslString: String {
        let (hue, saturation, lightness) = hsl
        let body = "\(Int(hue.rounded())), \(percent(saturation)), \(percent(lightness))"
        guard !isOpaque else { return "hsl(\(body))" }
        return "hsla(\(body), \(Self.decimal(alpha)))"
    }

    var hsbString: String {
        let (hue, saturation, brightness) = hsb
        let body = "\(Int(hue.rounded())), \(percent(saturation)), \(percent(brightness))"
        guard !isOpaque else { return "hsb(\(body))" }
        return "hsba(\(body), \(Self.decimal(alpha)))"
    }

    func string(in format: ColorFormat) -> String {
        switch format {
        case .hex: hexString
        case .rgb: rgbString
        case .hsl: hslString
        case .hsb: hsbString
        }
    }

    /// Every format at once, in menu order, for the ⌘K "Copy As" rows.
    var allStrings: [(ColorFormat, String)] {
        ColorFormat.allCases.map { ($0, string(in: $0)) }
    }

    /// Lower-case hex digits without the hash: the stable id of a color.
    var storageID: String {
        String(format: "%02x%02x%02x%02x", red255, green255, blue255, Int((alpha * 255).rounded()))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.2g", rounded)
    }

    // MARK: - Naming

    /// Closest common color name, so history rows read as words and can be
    /// searched ("blue" finds `#4A90D9`). Distance is weighted for how the
    /// eye judges the channels, which keeps greys off the primaries.
    var name: String {
        var best = Self.namedColors[0]
        var bestDistance = Double.greatestFiniteMagnitude
        for candidate in Self.namedColors {
            let dr = red - candidate.red
            let dg = green - candidate.green
            let db = blue - candidate.blue
            let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best.name
    }

    private struct NamedColor {
        let name: String
        let red: Double
        let green: Double
        let blue: Double

        init(_ name: String, _ red: Int, _ green: Int, _ blue: Int) {
            self.name = name
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
        }
    }

    private static let namedColors: [NamedColor] = [
        NamedColor("Black", 0, 0, 0),
        NamedColor("White", 255, 255, 255),
        NamedColor("Grey", 128, 128, 128),
        NamedColor("Light Grey", 200, 200, 200),
        NamedColor("Dark Grey", 64, 64, 64),
        NamedColor("Red", 255, 0, 0),
        NamedColor("Dark Red", 139, 0, 0),
        NamedColor("Pink", 255, 105, 180),
        NamedColor("Salmon", 250, 128, 114),
        NamedColor("Orange", 255, 165, 0),
        NamedColor("Brown", 139, 69, 19),
        NamedColor("Gold", 255, 215, 0),
        NamedColor("Yellow", 255, 255, 0),
        NamedColor("Olive", 128, 128, 0),
        NamedColor("Lime", 0, 255, 0),
        NamedColor("Green", 0, 128, 0),
        NamedColor("Mint", 152, 255, 152),
        NamedColor("Teal", 0, 128, 128),
        NamedColor("Cyan", 0, 255, 255),
        NamedColor("Sky Blue", 135, 206, 235),
        NamedColor("Blue", 0, 0, 255),
        NamedColor("Steel Blue", 70, 130, 180),
        NamedColor("Navy", 0, 0, 128),
        NamedColor("Indigo", 75, 0, 130),
        NamedColor("Purple", 128, 0, 128),
        NamedColor("Violet", 148, 0, 211),
        NamedColor("Magenta", 255, 0, 255),
        NamedColor("Beige", 245, 245, 220),
        NamedColor("Tan", 210, 180, 140),
    ]
}
