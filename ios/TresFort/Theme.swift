import SwiftUI

// Visual language: the Ink palette (`BrandPalette`), following the system
// light or dark appearance, with a single dusty-navy accent and a muted green
// for "done". One type system: SF Pro (system text styles, so Dynamic Type
// applies) for every label and heading; Bebas Neue display type only for
// workout and exercise names and big numbers; JetBrains Mono only for big
// numbers. Primary actions use `WorkoutPrimaryButtonStyle`.
enum Theme {
    static let bgTop = BrandPalette.bgTop
    static let bg = BrandPalette.bg
    static let surface = BrandPalette.surface
    static let surface2 = BrandPalette.surface2
    static let text = BrandPalette.text
    static let muted = BrandPalette.muted
    static let dim = BrandPalette.dim
    static let accent = BrandPalette.accent
    /// Text and icons on an accent fill.
    static let onAccent = BrandPalette.onAccent
    static let done = BrandPalette.done
    static let danger = BrandPalette.danger

    static var background: some View {
        RadialGradient(colors: [bgTop, bg],
                       center: .top, startRadius: 0, endRadius: 600)
            .ignoresSafeArea()
    }

    /// Bebas Neue: condensed all-caps display, only for workout and
    /// exercise names and big numbers (timers, weights, stats).
    static func display(_ size: CGFloat) -> Font {
        .custom("BebasNeue-Regular", size: size)
    }
    /// Small labels and captions: SF Pro at the nearest text style (so they
    /// follow Dynamic Type) with tabular digits, so numbers in a label still
    /// line up. Formerly JetBrains Mono; mono type is now only for `number`.
    static func mono(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font {
        Font.system(textStyle(for: size), weight: w).monospacedDigit()
    }
    /// The text style closest to a point size, never much larger.
    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12: .caption2
        case ..<13: .caption
        case ..<15: .footnote
        case ..<16: .subheadline
        case ..<17: .callout
        case ..<20: .body
        case ..<22: .title3
        case ..<28: .title2
        case ..<34: .title
        default: .largeTitle
        }
    }
    /// Big tabular number (stepper values, countdowns).
    static func number(_ size: CGFloat) -> Font {
        .custom("JetBrainsMono-Bold", size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
