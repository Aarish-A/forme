import SwiftUI

/// A status the app can communicate, bundled with everything needed to show it
/// accessibly.
///
/// This type exists to make a rule structural instead of aspirational. "Colour
/// is never the only signal" is easy to agree with and easy to forget at 2am,
/// so the status colours are not exposed on ``Theme/Colors`` at all — the only
/// way to reach red is through a case here, and every case carries a symbol.
/// Someone who can't distinguish the colour still sees a different icon.
/// Main-actor isolated rather than `nonisolated`, because `color` reads a
/// generated asset symbol — see the note in `Theme+Colors.swift`.
enum SemanticStatus: CaseIterable {
    case error
    case warning
    case success

    var color: Color {
        switch self {
        case .error: Color.statusError
        case .warning: Color.statusWarning
        case .success: Color.statusSuccess
        }
    }

    /// SF Symbols are chosen for distinct silhouettes, not just distinct colours:
    /// an octagon, a triangle and a circle read apart at a glance and in greyscale.
    var symbol: String {
        switch self {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    /// Prefixed to the message for VoiceOver, so the status isn't carried by the
    /// icon alone for someone who never sees it.
    var accessibilityPrefix: LocalizedStringKey {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .success: "Success"
        }
    }
}

/// The sanctioned way to show a status. Colour, icon and text arrive together
/// because they are not separable without losing someone.
struct StatusLabel: View {
    let status: SemanticStatus
    let message: String

    init(_ status: SemanticStatus, _ message: String) {
        self.status = status
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: status.symbol)
        }
        .formeText(.caption)
        .foregroundStyle(status.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(status.accessibilityPrefix) + Text(": \(message)"))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        StatusLabel(.error, "That email and password don't match.")
        StatusLabel(.warning, "Two items are missing photos.")
        StatusLabel(.success, "Outfit saved.")
    }
    .formeScreenPadding()
}
