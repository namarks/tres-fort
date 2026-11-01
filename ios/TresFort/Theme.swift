import SwiftUI

// Visual language: dark scoreboard, amber accent, lime "done". One type
// system: SF Pro (system text styles, so Dynamic Type applies) for every
// label and heading; Bebas Neue display type only for workout and exercise
// names and big numbers; JetBrains Mono only for big numbers. Primary
// actions use `WorkoutPrimaryButtonStyle`.
enum Theme {
    static let bgTop = Color(hex: 0x1A1A1F)
    static let bg = Color(hex: 0x0A0A0B)
    static let surface = Color(hex: 0x141417)
    static let surface2 = Color(hex: 0x1C1C21)
    static let text = Color(hex: 0xF4F4F5)
    static let muted = Color(hex: 0xA1A1AA)
    static let dim = Color(hex: 0x4A4A52)
    static let accent = Color(hex: 0xF59E0B)
    static let done = Color(hex: 0x84CC16)
    static let danger = Color(hex: 0xEF4444)

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
