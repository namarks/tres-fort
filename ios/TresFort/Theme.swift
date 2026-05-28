import SwiftUI

// Visual language from the reference artifact: dark scoreboard, amber
// accent, lime "done", heavy display type + mono numerics. Fonts use
// system (SF Pro Heavy / SF Mono) as the native translation; swapping in
// bundled Bebas Neue + JetBrains Mono is a drop-in polish step later.
enum Theme {
    static let bgTop = Color(hex: 0x1A1A1F)
    static let bg = Color(hex: 0x0A0A0B)
    static let surface = Color(hex: 0x141417)
    static let surface2 = Color(hex: 0x1C1C21)
    static let text = Color(hex: 0xF4F4F5)
    static let muted = Color(hex: 0x8A8A93)
    static let dim = Color(hex: 0x4A4A52)
    static let accent = Color(hex: 0xF59E0B)
    static let done = Color(hex: 0x84CC16)
    static let danger = Color(hex: 0xEF4444)

    static var background: some View {
        RadialGradient(colors: [bgTop, bg],
                       center: .top, startRadius: 0, endRadius: 600)
            .ignoresSafeArea()
    }

    /// Bebas Neue — condensed all-caps display (titles, buttons, big timer).
    static func display(_ size: CGFloat) -> Font {
        .custom("BebasNeue-Regular", size: size)
    }
    /// JetBrains Mono — true monospace for labels + numerics (uniform digits).
    static func mono(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font {
        let face: String
        switch w {
        case .bold, .heavy, .black, .semibold: face = "JetBrainsMono-Bold"
        case .medium: face = "JetBrainsMono-Medium"
        default: face = "JetBrainsMono-Regular"
        }
        return .custom(face, size: size)
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
