import SwiftUI

/// Design tokens for Forme.
///
/// Views should reach for these instead of literal numbers. Confidence comes
/// partly from an interface that feels considered, and consistent rhythm is
/// most of that. When a value here changes, the whole app moves with it.
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

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        /// Cards showing garments and outfits.
        static let card: CGFloat = 20
    }

    /// Semantic type styles built on Dynamic Type, so the app stays legible at
    /// every accessibility size without per-view special-casing.
    enum Typography {
        static let screenTitle = Font.largeTitle.weight(.semibold)
        static let sectionTitle = Font.title3.weight(.semibold)
        static let body = Font.body
        static let caption = Font.footnote
    }
}

// MARK: - Reusable view styles

extension View {
    /// The standard card treatment for garments, outfits, and suggestions.
    func formeCard() -> some View {
        padding(Theme.Spacing.md)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.card))
    }

    /// Horizontal insets for full-width screen content.
    func formeScreenPadding() -> some View {
        padding(.horizontal, Theme.Spacing.md)
    }
}
