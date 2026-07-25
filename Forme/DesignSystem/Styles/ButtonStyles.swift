import SwiftUI

/// The app's main action on a screen.
///
/// Today this delegates to the platform, which on iOS 26 means the button
/// inherits Liquid Glass treatment, correct pressed and disabled states, and
/// every accessibility affordance for free. That is deliberate: the brand pass
/// restyles *this file*, and because call sites only ever say `.formePrimary`,
/// none of them change.
struct FormePrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}

/// A supporting action, subordinate to the primary one on the same screen.
struct FormeSecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .controlSize(.large)
    }
}

extension PrimitiveButtonStyle where Self == FormePrimaryButtonStyle {
    static var formePrimary: FormePrimaryButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == FormeSecondaryButtonStyle {
    static var formeSecondary: FormeSecondaryButtonStyle { .init() }
}
