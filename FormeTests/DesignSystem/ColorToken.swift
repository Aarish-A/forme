import SwiftUI
@testable import Forme

/// The design system's colours, named rather than resolved.
///
/// `@Test(arguments:)` evaluates its arguments outside the main actor, and the
/// generated asset symbols behind `Theme.Colors` are main-actor isolated. So
/// the tests are parameterised over these identifiers and reach for the actual
/// `Color` inside the test body, where the main actor is available.
nonisolated enum ColorToken: String, CaseIterable {
    case accent
    case surface
    case surfaceSecondary
    case outline
    case textPrimary
    case textSecondary
    case statusError
    case statusWarning
    case statusSuccess
    /// Background and label of the primary action. Not on `Theme.Colors` —
    /// reached through `FormePrimaryButtonStyle` — so the test reaches for the
    /// generated symbols directly.
    case accentFill
    case onAccentFill

    /// Colours that must look different in dark mode.
    ///
    /// `accentFill` and `onAccentFill` are deliberately absent: they're
    /// appearance-independent by design, because a primary button that goes
    /// pastel in the dark is the problem they exist to solve. That's the
    /// documented exception `ColorAssetTests` asks for, not an oversight.
    static let brandDefined: [ColorToken] = [
        .surface, .surfaceSecondary, .outline, .textPrimary, .textSecondary,
        .accent, .statusError, .statusWarning, .statusSuccess
    ]

    /// Anything the app draws text or glyphs in.
    static let foregrounds: [ColorToken] = [
        .textPrimary, .textSecondary, .accent,
        .statusError, .statusWarning, .statusSuccess
    ]

    /// Anything a foreground gets drawn on top of.
    static let surfaces: [ColorToken] = [.surface, .surfaceSecondary]
}

// Default (main-actor) isolation, so it can read the generated asset symbols.
extension ColorToken {
    var color: Color {
        switch self {
        case .accent: Theme.Colors.accent
        case .surface: Theme.Colors.surface
        case .surfaceSecondary: Theme.Colors.surfaceSecondary
        case .outline: Theme.Colors.outline
        case .textPrimary: Theme.Colors.textPrimary
        case .textSecondary: Theme.Colors.textSecondary
        case .statusError: SemanticStatus.error.color
        case .statusWarning: SemanticStatus.warning.color
        case .statusSuccess: SemanticStatus.success.color
        // Not exposed on Theme.Colors by design, so the test reads the
        // generated symbols directly.
        case .accentFill: Color.accentFill
        case .onAccentFill: Color.onAccentFill
        }
    }
}
