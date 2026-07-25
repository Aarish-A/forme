import SwiftUI

/// Not `nonisolated`, unlike the rest of the design system: Xcode's generated
/// asset symbols are main-actor isolated, so anything reading them has to be too.
/// Colour is only ever needed while drawing, so this costs nothing.
extension Theme {
    /// Every colour the app is allowed to name.
    ///
    /// The values live in `Assets.xcassets/Colors`, not here, because a colorset
    /// carries its own light, dark and increased-contrast variants and the system
    /// picks between them for free. This layer exists for naming and gatekeeping:
    /// the asset symbols are compile-checked, so renaming a colorset breaks the
    /// build rather than silently rendering black.
    ///
    /// Deliberately absent: `danger`, `warning`, `success`. Status is only
    /// reachable through ``SemanticStatus``, which forces an icon and a label
    /// alongside the colour — see the accessibility note there.
    enum Colors {
        /// The app's tint. Drives system controls via `AccentColor` too.
        static let accent = Color.accent
        /// The base layer: screen backgrounds. Content sits here so the iOS 26
        /// glass navigation layer above it reads as floating.
        static let surface = Color.surface
        /// Raised content: cards, grouped rows, wells.
        static let surfaceSecondary = Color.surfaceSecondary
        /// Hairlines, dividers, and card borders. Decorative — never the only
        /// thing separating two pieces of meaning.
        static let outline = Color.outline

        /// Primary reading text.
        ///
        /// A warm near-black rather than the system label: pure black on a bone
        /// surface reads colder than the brand wants, and the eye notices even
        /// at this distance from neutral.
        static let textPrimary = Color.textPrimary

        /// Supporting text: captions, secondary lines, placeholders.
        ///
        /// Ours rather than the system's, deliberately. iOS `secondaryLabel`
        /// lands around 3.3:1 on white — under the 4.5:1 that body-sized text
        /// needs. Our secondary text carries real content, so it gets a colour
        /// that passes, and `ContrastTests` keeps it that way through a rebrand.
        static let textSecondary = Color.textSecondary
    }
}
