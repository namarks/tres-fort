import SwiftUI
import UIKit
import XCTest
@testable import TresFort

@MainActor
final class ThemeAccessibilityTests: XCTestCase {
    private let styles: [UIUserInterfaceStyle] = [.light, .dark]

    // The gradient interpolates between bg and bgTop. All component channels
    // lie within these surfaces, so testing each bounds the text contrast.
    // The native iOS 26.2 contrast audit reports false positives over this
    // gradient. This policy checks the resolved colors themselves, in both
    // light and dark mode; decorative dim and intentionally disabled text
    // have a different purpose.
    func testEnabledTextContrastAcrossSurfaces() {
        let foregrounds = [Theme.text, Theme.muted, Theme.accent, Theme.done, Theme.danger]
            + BrandPalette.categorical
        for style in styles {
            for foreground in foregrounds {
                for background in [Theme.bg, Theme.bgTop, Theme.surface, Theme.surface2] {
                    XCTAssertGreaterThanOrEqual(contrast(foreground, background, style), 4.5,
                                                "Enabled text must retain WCAG AA contrast (\(style == .dark ? "dark" : "light"))")
                }
            }
        }
    }

    func testPrimaryActionTextContrast() {
        for style in styles {
            XCTAssertGreaterThanOrEqual(contrast(Theme.onAccent, Theme.accent, style), 4.5)
            // Older call sites label accent fills with the page background.
            XCTAssertGreaterThanOrEqual(contrast(Theme.bg, Theme.accent, style), 4.5)
        }
    }

    func testLightAndDarkResolveDifferently() {
        XCTAssertNotEqual(luminance(Theme.bg, .light), luminance(Theme.bg, .dark))
        XCTAssertNotEqual(luminance(Theme.accent, .light), luminance(Theme.accent, .dark))
    }

    private func contrast(_ a: Color, _ b: Color, _ style: UIUserInterfaceStyle) -> Double {
        let x = luminance(a, style), y = luminance(b, style)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(alpha, 1)
        let linear = [red, green, blue].map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
