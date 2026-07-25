import SwiftUI

/// The app's main action on a screen.
///
/// The fill is `accentFill`, which is deliberately the same oxblood in both
/// appearances. `Theme.Colors.accent` can't do this job: it also has to be
/// legible as *text* on a near-black surface, which forces it to a pale rose in
/// dark mode — and a pale pink primary button is not what this brand is.
/// Splitting the two lets each satisfy its own contrast requirement.
///
/// The fill colours are read here and nowhere else. They're absent from
/// `Theme.Colors` on purpose, so no view can pick up a background colour and
/// use it as a foreground, which is the one way this split could go wrong.
struct FormePrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .foregroundStyle(Color.onAccentFill)
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
    static var formePrimary: FormePrimaryButtonStyle {
        .init()
    }
}

extension PrimitiveButtonStyle where Self == FormeSecondaryButtonStyle {
    static var formeSecondary: FormeSecondaryButtonStyle {
        .init()
    }
}
