import SwiftUI

nonisolated extension Theme {
    /// What a piece of text *is*, not what it looks like.
    ///
    /// Views name a role; the spec table below decides how it renders. That
    /// indirection is the whole point: a new typeface changes the table and
    /// nothing else.
    enum TextRole: String, CaseIterable {
        case screenTitle
        case sectionTitle
        case body
        case bodyEmphasis
        case caption
    }

    /// How one role renders.
    ///
    /// `size` is the design size at the default Dynamic Type setting. For a
    /// system face SwiftUI derives the size from `relativeTo` and ignores it;
    /// it still drives line spacing, and a custom face uses it directly.
    struct TextSpec {
        enum Face {
            case system(Font.Design)
            case custom(String)
        }

        let face: Face
        let size: CGFloat
        let weight: Font.Weight
        /// The Dynamic Type style this scales with. Every role has one, so
        /// accessibility sizes work by construction rather than by review.
        let relativeTo: Font.TextStyle
        let tracking: CGFloat
        /// Extra leading, as a multiple of `size`. Scaled with Dynamic Type at
        /// the point of use.
        let lineSpacingFactor: CGFloat

        /// `tracking` and `lineSpacingFactor` default to zero so the spec table
        /// below stays one readable line per role, and only the roles that
        /// actually tune them say so.
        init(
            face: Face,
            size: CGFloat,
            weight: Font.Weight,
            relativeTo: Font.TextStyle,
            tracking: CGFloat = 0,
            lineSpacingFactor: CGFloat = 0
        ) {
            self.face = face
            self.size = size
            self.weight = weight
            self.relativeTo = relativeTo
            self.tracking = tracking
            self.lineSpacingFactor = lineSpacingFactor
        }

        var font: Font {
            switch face {
            case let .system(design):
                .system(relativeTo, design: design, weight: weight)
            case let .custom(name):
                .custom(name, size: size, relativeTo: relativeTo).weight(weight)
            }
        }
    }

    // MARK: - The type swap seam

    /// The brand's type scale. **This table is the seam** — adopting a new
    /// typeface or scale means editing here, dropping any font files into
    /// `Resources/Fonts/`, and declaring `UIAppFonts` in `Config/Info.plist`.
    /// No view changes.
    ///
    /// **Deferred decision: the display face.** Every role is currently SF, which
    /// is free, harmonises with Liquid Glass, and scales without help. A custom
    /// face for `screenTitle` and `sectionTitle` is on the table and would be a
    /// two-line change here.
    ///
    /// The palette is chosen with that in view. Display faces are typically
    /// lighter in the stem than SF at the same weight, so text that sits exactly
    /// on the 4.5:1 line today would read thinner and worse after the swap. The
    /// colours therefore carry contrast headroom rather than scraping the
    /// minimum — see `ContrastTests`.
    static func spec(for role: TextRole) -> TextSpec {
        switch role {
        case .screenTitle:
            TextSpec(face: .system(.default), size: 34, weight: .semibold, relativeTo: .largeTitle)
        case .sectionTitle:
            TextSpec(face: .system(.default), size: 20, weight: .semibold, relativeTo: .title3)
        case .body:
            TextSpec(face: .system(.default), size: 17, weight: .regular, relativeTo: .body, lineSpacingFactor: 0.1)
        case .bodyEmphasis:
            TextSpec(face: .system(.default), size: 17, weight: .semibold, relativeTo: .body, lineSpacingFactor: 0.1)
        case .caption:
            TextSpec(face: .system(.default), size: 13, weight: .regular, relativeTo: .footnote)
        }
    }
}

extension View {
    /// Apply a text role.
    ///
    /// A modifier rather than a `Font` constant because SwiftUI's `Font` can't
    /// carry tracking or leading — the three have to be applied together or the
    /// brand only half-arrives.
    func formeText(_ role: Theme.TextRole) -> some View {
        modifier(FormeTextModifier(spec: Theme.spec(for: role)))
    }
}

private struct FormeTextModifier: ViewModifier {
    let spec: Theme.TextSpec

    /// Leading has to scale with the text it separates, and `lineSpacing` takes
    /// raw points — `@ScaledMetric` is what bridges the two.
    @ScaledMetric private var lineSpacing: CGFloat

    init(spec: Theme.TextSpec) {
        self.spec = spec
        _lineSpacing = ScaledMetric(
            wrappedValue: spec.size * spec.lineSpacingFactor,
            relativeTo: spec.relativeTo
        )
    }

    func body(content: Content) -> some View {
        content
            .font(spec.font)
            .tracking(spec.tracking)
            .lineSpacing(lineSpacing)
    }
}
