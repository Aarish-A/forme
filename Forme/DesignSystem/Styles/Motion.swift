import SwiftUI

extension View {
    /// Apply a transition that moves, degrading to a cross-fade for anyone who
    /// has asked for one.
    ///
    /// Reduce Motion does not mean "no animation". Apple's guidance is to
    /// replace movement in x, y and z with fades and to flatten springs — not
    /// to make changes instant. An instant swap severs the link between a tap
    /// and its result, and an app meant to reduce self-doubt is the last place
    /// to make someone wonder whether they pressed the button.
    ///
    /// So the animation is never removed: `Theme.Motion` is bounce-free
    /// already, leaving nothing to flatten. The transition is the only part
    /// that has to change, which is why this wraps `transition` and there is no
    /// matching wrapper for `animation`.
    ///
    /// There is a newer, slightly more precise key for this —
    /// `accessibilityPrefersCrossFadeTransitions` — but it needs iOS 26.4 and
    /// our floor is 26.0. Branching on availability isn't worth it: the two
    /// differ only for someone who set Prefer Cross-Fade without Reduce Motion,
    /// and both want the same thing from us. Switch when the floor moves.
    func formeTransition(_ movement: AnyTransition) -> some View {
        modifier(FormeTransitionModifier(movement: movement))
    }
}

private struct FormeTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let movement: AnyTransition

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : movement)
    }
}
