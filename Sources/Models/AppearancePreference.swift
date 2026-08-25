import AppKit
import Foundation
import SwiftUI

/// User-selectable appearance for the overlay and settings window.
enum AppearancePreference: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    /// `nil` means "follow the system appearance"; SwiftUI interprets a nil
    /// `preferredColorScheme` as "do not override".
    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Window-level appearance, so the title bar matches the forced content
    /// scheme instead of staying on the system look (a white title bar over
    /// a dark settings pane). `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var displayName: String {
        switch self {
        case .system: return "Follow system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
