import SwiftUI

extension View {
    /// Animate a change using a `Theme.Motion` value, respecting Reduce Motion.
    ///
    /// Use this instead of `.animation(_:value:)`. Someone who gets motion sick
    /// from a sliding card shouldn't have to rely on us remembering to check the
    /// setting at each call site, so the check lives here and the plain modifier
    /// is the one we avoid.
    ///
    /// With Reduce Motion on the change is applied instantly. A view that wants
    /// a cross-fade instead should say so with `.transition(.opacity)`, which
    /// Reduce Motion leaves alone.
    func formeAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(FormeAnimationModifier(animation: animation, value: value))
    }
}

private struct FormeAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
