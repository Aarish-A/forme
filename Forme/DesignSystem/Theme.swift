import SwiftUI

/// The design system's namespace, and its metric half.
///
/// Views should reach for these instead of literal numbers. Confidence comes
/// partly from an interface that feels considered, and consistent rhythm is
/// most of that. When a value here changes, the whole app moves with it.
///
/// Colour lives in `Theme+Colors.swift`, type in `Theme+Typography.swift`.
/// Between those three files sits the entire brand: changing them re-skins the
/// app without a single view being edited.
nonisolated enum Theme {
    /// An 8-point spacing scale. If a layout needs something off-scale, that's
    /// usually a sign the layout is wrong, not that the scale is missing a value.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    /// Corner radii. Part of the brand swap seam — a softer or sharper brand
    /// moves these and nothing else.
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        /// Cards showing garments and outfits.
        static let card: CGFloat = 20
    }

    /// How the app moves. Defined before anything animates so that Reduce Motion
    /// is handled by construction rather than audited later — see
    /// `View.formeAnimation(_:value:)`.
    enum Motion {
        /// Immediate feedback: taps, selections, toggles.
        static let snappy = Animation.snappy(duration: 0.2)
        /// Content arriving or rearranging.
        static let settle = Animation.smooth(duration: 0.35)
    }
}
