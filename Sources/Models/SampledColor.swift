import AppKit

/// One colour picked off the screen, kept as three 8-bit sRGB channels.
///
/// A picked colour is a value the user copies, not a colour this app draws,
/// so it never goes through the design tokens: it is the user's pixel.
struct SampledColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The sRGB form of an AppKit colour, or nil for a colour that has no
    /// sRGB value (a pattern, or a catalog colour with none).
    ///
    /// The sampler answers in the display's own colour space, so converting
    /// first is what makes the same pixel give the same hex on a wide-gamut
    /// display and a plain one.
    init?(color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Self.channel(srgb.redComponent),
            green: Self.channel(srgb.greenComponent),
            blue: Self.channel(srgb.blueComponent)
        )
    }

    /// `#RRGGBB`, upper case: the form a style sheet, a design tool and a
    /// colour field all accept.
    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// A 0...1 component as a byte, rounded, so one half is 128 and never 127.
    private static func channel(_ component: CGFloat) -> UInt8 {
        let clamped = min(max(component, 0), 1)
        return UInt8((clamped * 255).rounded())
    }
}
