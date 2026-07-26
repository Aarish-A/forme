import SwiftUI

/// The Forme mark: three ribbons that resolve into an F.
///
/// The asset is a template image, so it takes whatever foreground style is in
/// scope rather than carrying colour of its own. That's what gives it light and
/// dark for free — the default is ``Theme/Colors/accent``, which is oxblood on
/// bone and dusty rose on near-black, and `ContrastTests` holds both above 4.5:1
/// on every surface the app draws. A rebrand moves the mark with it.
///
/// **It needs room.** The gaps between the three ribbons are thin relative to
/// the mark's height, so below roughly 44pt they close up and it reads as a
/// blot rather than a letter. This is a brand moment — launch, empty states,
/// about — not a toolbar glyph. ``minimumLegibleHeight`` names that floor;
/// reach for an SF Symbol where you need something smaller.
struct FormeMark: View {
    /// Below this the negative space closes and the F stops being legible.
    static let minimumLegibleHeight: CGFloat = 44

    /// Height in points. Width follows from the mark's own proportions.
    var height: CGFloat = 96

    /// What the template is filled with. A parameter rather than an inherited
    /// foreground style so that forgetting doesn't quietly render the brand in
    /// the system label colour — and so the knocked-out treatment on the accent
    /// fill stays a one-liner.
    var tint: Color = Theme.Colors.accent

    var body: some View {
        Image(.formeMark)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(tint)
            // The mark stands for the app's name, so it reads as "Forme" rather
            // than going unannounced. Pair it with `.accessibilityHidden(true)`
            // where the word already sits next to it.
            .accessibilityLabel("Forme")
    }
}

#Preview("On surface") {
    VStack(spacing: Theme.Spacing.xl) {
        FormeMark()
        FormeMark(height: FormeMark.minimumLegibleHeight)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Colors.surface)
}

#Preview("Knocked out of the accent fill") {
    FormeMark(tint: Color.onAccentFill)
        .padding(Theme.Spacing.xl)
        .background(Color.accentFill, in: .rect(cornerRadius: Theme.Radius.card))
}
