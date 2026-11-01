import SwiftUI
import UIKit

// The Ink palette, shared by the app and its widgets. One hue (OKLCH 255) set
// as a tonal scale, with neutrals tinted toward it; one accent (ink 700 in
// light mode, ink 400 in dark). Each color resolves for the current light or
// dark appearance. Text colors meet WCAG AA (4.5:1) on every surface in both
// modes; ThemeAccessibilityTests checks that. The website uses the same
// values (website/styles.mjs).
enum BrandPalette {
    static let bgTop = dynamic(light: 0xFDFDFE, dark: 0x1A1E25)
    static let bg = dynamic(light: 0xF5F8FB, dark: 0x101419)
    static let surface = dynamic(light: 0xFDFDFE, dark: 0x191D23)
    static let surface2 = dynamic(light: 0xE9EBEF, dark: 0x242930)
    static let text = dynamic(light: 0x16191C, dark: 0xF5F8FB)
    static let muted = dynamic(light: 0x565B62, dark: 0xACB2B9)
    static let dim = dynamic(light: 0x9EA2A7, dark: 0x595E64)
    static let accent = dynamic(light: 0x37577F, dark: 0x83A4CE)
    /// Text and icons on an accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0E1927)
    static let done = dynamic(light: 0x31693F, dark: 0x82C38F)
    static let danger = dynamic(light: 0xAF3C3A, dark: 0xEB827B)

    /// Live Activities and the Dynamic Island always sit on a dark
    /// background, so they use the dark-mode values directly.
    static let liveBackground = Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x19 / 255)
    static let liveAccent = Color(red: 0x83 / 255, green: 0xA4 / 255, blue: 0xCE / 255)

    /// Six categorical colors for telling things apart (group members,
    /// activity kinds), never for emphasis. Same OKLCH lightness and chroma at
    /// evenly spread hues, so none shouts louder than another; each passes
    /// 4.5:1 as text on every surface.
    static let categorical: [Color] = [
        dynamic(light: 0x984742, dark: 0xF69B94),  // clay, hue 25
        dynamic(light: 0x676803, dark: 0xBBBE67),  // olive, hue 110
        dynamic(light: 0x2B7440, dark: 0x82CB92),  // green, hue 150
        dynamic(light: 0x057176, dark: 0x4ECCD3),  // teal, hue 200
        dynamic(light: 0x6D5398, dark: 0xC2A7F4),  // violet, hue 300
        dynamic(light: 0x8E4771, dark: 0xEA9BC7),  // plum, hue 345
    ]

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
