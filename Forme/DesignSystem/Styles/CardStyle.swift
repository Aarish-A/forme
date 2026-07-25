import SwiftUI

extension View {
    /// The standard card treatment for garments, outfits, and suggestions.
    ///
    /// Backed by `Theme.Colors.surfaceSecondary` rather than a material: on
    /// iOS 26 the glass layer belongs to navigation chrome, and content sitting
    /// at the base layer is what makes that chrome read as floating.
    func formeCard() -> some View {
        padding(Theme.Spacing.md)
            .background(Theme.Colors.surfaceSecondary, in: .rect(cornerRadius: Theme.Radius.card))
    }

    /// Horizontal insets for full-width screen content.
    func formeScreenPadding() -> some View {
        padding(.horizontal, Theme.Spacing.md)
    }
}
