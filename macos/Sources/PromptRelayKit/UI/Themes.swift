import SwiftUI

/// Island themes: the same semantic roles, different values. Views use only
/// the roles in `Island` (never a hex value). The camera band and the
/// resting island stay black in every theme.
public enum IslandTheme: String, CaseIterable, Identifiable, Sendable {
    /// Built around Relay: warm graphite cards, caramel accent and main
    /// button, sand for materials. The default for new installs.
    case warmCocoa
    /// Phase 6: graphite with one teal accent (kept to compare and to go back to).
    case classic
    /// Lavender interactive accent, mint for success, amber, coral and lilac
    /// for waiting, errors and materials; slightly violet graphite surfaces.
    case softSpectrum
    /// Restrained tonal roles after Material 3's dark scheme (primary,
    /// surface containers), adapted to the island; not Android components.
    case materialCalm

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .warmCocoa: return "Warm Cocoa"
        case .classic: return "Classic"
        case .softSpectrum: return "Soft Spectrum"
        case .materialCalm: return "Material Calm"
        }
    }

    public var palette: IslandPalette {
        switch self {
        case .warmCocoa: return .warmCocoa
        case .classic: return .classic
        case .softSpectrum: return .softSpectrum
        case .materialCalm: return .materialCalm
        }
    }
}

/// An sRGB color by its components, so contrast can be checked in tests.
public struct RGB: Equatable, Sendable {
    public let r: Double, g: Double, b: Double
    public init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// WCAG 2 relative luminance and contrast ratio.
    var luminance: Double {
        func c(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

/// The semantic roles of one theme.
public struct IslandPalette: Equatable, Sendable {
    // Text
    let primary: RGB, secondary: RGB, tertiary: RGB
    // Surfaces: card, interactive card, code block, control
    let card: RGB, cardRaised: RGB, code: RGB, control: RGB
    // States
    /// Interactive accent: selection, new answer, active session.
    let accent: RGB
    /// A copy that worked, a command that completed.
    let success: RGB
    /// Waiting, working, warnings.
    let warning: RGB
    /// A failed command, an API error.
    let error: RGB
    /// Mockups, attachments, extra materials.
    let review: RGB
    /// The main button (Copy Answer): fill and its text.
    let prominent: RGB, onProminent: RGB
    /// Card captions take their role's color (Review: accent, Attachments: review).
    var tintedCaptions = false

    static let warmCocoa = IslandPalette(
        primary: RGB(0xF4EEE5), secondary: RGB(0xC9BEB0), tertiary: RGB(0xA59A8C),
        card: RGB(0x292725), cardRaised: RGB(0x34312D), code: RGB(0x1D1B19), control: RGB(0x3B3733),
        accent: RGB(0xC59468), success: RGB(0x93C79F), warning: RGB(0xE8C077), error: RGB(0xEC968E), review: RGB(0xE9D7BC),
        prominent: RGB(0xC59468), onProminent: RGB(0x1E140B), tintedCaptions: true)

    static let classic = IslandPalette(
        primary: RGB(0xF2F4F7), secondary: RGB(0xB5BAC4), tertiary: RGB(0x8D95A0),
        card: RGB(0x1A1C20), cardRaised: RGB(0x26292E), code: RGB(0x111215), control: RGB(0x2E3137),
        accent: RGB(0x61CCD1), success: RGB(0x78D191), warning: RGB(0xFABD66), error: RGB(0xF27A75), review: RGB(0xBAA6FF),
        prominent: RGB(0xFFFFFF), onProminent: RGB(0x000000))

    static let softSpectrum = IslandPalette(
        primary: RGB(0xF3F3F8), secondary: RGB(0xBDBDD0), tertiary: RGB(0x8E8EA6),
        card: RGB(0x18181F), cardRaised: RGB(0x22222C), code: RGB(0x111117), control: RGB(0x2A2A37),
        accent: RGB(0xA5B4FC), success: RGB(0x76D7C4), warning: RGB(0xF3CD83), error: RGB(0xF3A8A6), review: RGB(0xC4B5FD),
        prominent: RGB(0xA5B4FC), onProminent: RGB(0x14152B), tintedCaptions: true)

    static let materialCalm = IslandPalette(
        primary: RGB(0xE3E2E6), secondary: RGB(0xC4C6D0), tertiary: RGB(0x8E9099),
        card: RGB(0x1D1E21), cardRaised: RGB(0x28292D), code: RGB(0x141518), control: RGB(0x333438),
        accent: RGB(0xA8C7FA), success: RGB(0x7DD3A0), warning: RGB(0xF2C46D), error: RGB(0xF2B8B5), review: RGB(0xD7BDE4),
        prominent: RGB(0xA8C7FA), onProminent: RGB(0x0A1E3D))
}
