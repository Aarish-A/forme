import Foundation
import SwiftUI
import Testing
@testable import Forme

/// The one design-system test that earns its keep.
///
/// Asserting `Spacing.md == 16` tests a constant against itself. This doesn't:
/// it resolves the real tokens in both appearances and computes the WCAG
/// contrast between the pairs the app actually renders. On brand day, a palette
/// that looks beautiful and reads badly fails `make ci` instead of shipping.
@Suite("Colour contrast")
struct ContrastTests {
    /// WCAG 2.1 AA for text below 18pt (or 14pt bold), which is every text role
    /// we have.
    static let minimumRatio = 4.5

    /// A foreground the app draws on a background it actually draws it on.
    ///
    /// `outline` appears in neither list on purpose: it's a hairline, not text,
    /// and WCAG holds non-text UI to 3:1. Including it would force a divider
    /// dark enough to shout.
    nonisolated struct Pairing: CustomStringConvertible {
        let foreground: ColorToken
        let background: ColorToken

        var description: String {
            "\(foreground.rawValue) on \(background.rawValue)"
        }
    }

    /// `nonisolated` because `@Test(arguments:)` reads it off the main actor.
    nonisolated static let pairings: [Pairing] = ColorToken.surfaces.flatMap { surface in
        ColorToken.foregrounds.map { Pairing(foreground: $0, background: surface) }
    } + [
        // The primary button's label on its own fill. Not covered by the loop
        // above because the fill is a background the app draws deliberately,
        // not one of the two page surfaces.
        Pairing(foreground: .onAccentFill, background: .accentFill)
    ]

    @Test(
        "Every text colour meets WCAG AA on every surface",
        arguments: ContrastTests.pairings, [ColorScheme.light, .dark]
    )
    func pairingMeetsAA(pairing: Pairing, scheme: ColorScheme) {
        let ratio = contrastRatio(
            pairing.foreground.color,
            on: pairing.background.color,
            in: scheme
        )

        #expect(
            ratio >= Self.minimumRatio,
            """
            \(pairing) in \(scheme) mode is \(String(format: "%.2f", ratio)):1, below the \
            \(Self.minimumRatio):1 WCAG AA minimum. Adjust the colorset, not this test.
            """
        )
    }

    private func contrastRatio(_ foreground: Color, on background: Color, in scheme: ColorScheme) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme

        let backdrop = background.resolve(in: environment)
        // A translucent foreground is only ever seen over its backdrop, so
        // measure what the eye gets rather than the token in isolation.
        let text = foreground.resolve(in: environment).composited(over: backdrop)

        let lighter = max(text.relativeLuminance, backdrop.relativeLuminance)
        let darker = min(text.relativeLuminance, backdrop.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

// MARK: - WCAG maths

private nonisolated extension Color.Resolved {
    /// Source-over compositing in sRGB space, which is where the compositor
    /// blends and what the WCAG reference implementation assumes.
    func composited(over backdrop: Color.Resolved) -> Color.Resolved {
        guard opacity < 1 else { return self }
        let alpha = opacity
        return Color.Resolved(
            red: red * alpha + backdrop.red * (1 - alpha),
            green: green * alpha + backdrop.green * (1 - alpha),
            blue: blue * alpha + backdrop.blue * (1 - alpha)
        )
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        0.2126 * linearised(red) + 0.7152 * linearised(green) + 0.0722 * linearised(blue)
    }

    /// The sRGB electro-optical transfer function.
    func linearised(_ component: Float) -> Double {
        let value = Double(min(max(component, 0), 1))
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
