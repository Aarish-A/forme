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
    ///
    /// Note we never pass a `RoundedCornerStyle`. Every rounded-rect API in this
    /// SDK already defaults to `.continuous` — the squircle, where curvature
    /// ramps into the straight edge instead of meeting it at a quarter-circle's
    /// abrupt tangent. It's what the hardware corners, app icons and system
    /// cards use, and it's most of why a circular-cornered card looks subtly
    /// wrong beside native UI. Restating the default at every call site would
    /// be noise; knowing it's there is the point.
    ///
    /// For a shape nested inside another — an image inside a card — prefer
    /// `ConcentricRectangle` with `containerShape(_:)` over picking `sm` by eye.
    /// Concentric corners share a centre with the corner enclosing them, so the
    /// inner radius is the outer one minus the inset: derived, not chosen, and
    /// automatically right when the brand moves these numbers.
    enum Radius {
        /// Nested shapes, where concentricity can't derive one.
        static let sm: CGFloat = 8
        /// Buttons and controls. Apple's inset grouped rows sit near this.
        static let md: CGFloat = 12
        /// Cards and garment tiles.
        ///
        /// Tight rather than soft: past about 18 the corners start reading
        /// friendly-playful, which is the opposite of what the brand is doing.
        static let card: CGFloat = 16
    }

    /// How the app moves.
    ///
    /// Three of these vary on one axis — how far the thing travels — because
    /// bigger movements taking longer is most of what makes motion read as
    /// physical. `track` is a different kind of motion, not a different size.
    ///
    /// All are bounce-free springs, matching SwiftUI's own default of
    /// `spring(response: 0.55, dampingFraction: 1)`. Springs rather than eased
    /// curves because they're interruptible: a retargeted spring carries its
    /// existing velocity, where `.easeInOut` restarts from zero and visibly
    /// stutters. Someone changing their mind mid-gesture is the normal case.
    ///
    /// Bounce is seasoning for a single call site (`extraBounce:`), never a
    /// system default — hence no bouncy token.
    enum Motion {
        /// One small element changing in place: selection, toggle, icon swap.
        static let tap = Animation.smooth(duration: 0.3)
        /// Content arriving or rearranging: list insert, card reflow, filtering.
        static let settle = Animation.smooth(duration: 0.45)
        /// A whole surface moving: a custom overlay, an onboarding step.
        static let surface = Animation.smooth(duration: 0.6)
        /// A value following a finger. Hand off to `settle` on release and
        /// SwiftUI carries the velocity across.
        static let track = Animation.interactiveSpring
    }
}
