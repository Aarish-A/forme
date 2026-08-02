import SwiftUI

/// The screen before the permission prompt.
///
/// iOS only ever asks once, so the ask has to arrive already understood. This
/// screen exists to say the one thing that decides the answer — the photos stay
/// on the phone — before the system dialog appears and it's too late to explain.
struct ScanPrimerView: View {
    /// Whether Forme already knows which face is the user's. Drives the one
    /// line on this screen that says so, and the way back out of it.
    var seedIsSet = false
    let onScan: () -> Void
    let onSkip: () -> Void
    /// Forgets the stored face. Never called when `seedIsSet` is false.
    var onResetIdentity: () -> Void = {}

    /// The prose scrolls and the actions pin to the bottom: at accessibility
    /// text sizes a fixed VStack truncates the privacy sentence this screen
    /// exists to deliver, with no way to read the rest.
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "lock.iphone")
                    .formeText(.screenTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.sm) {
                    Text("Find your clothes in your photos")
                        .formeText(.sectionTitle)
                        .multilineTextAlignment(.center)

                    Text(
                        """
                        Forme looks through your photos for clothes you own — right here on your iPhone. \
                        Nothing is uploaded, and you choose what makes it into your wardrobe.
                        """
                    )
                    .formeText(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.sm) {
                Button("Scan My Photos", action: onScan)
                    .buttonStyle(.formePrimary)

                Button("Not Now", action: onSkip)
                    .buttonStyle(.formeSecondary)

                if seedIsSet {
                    identityFootnote
                }
            }
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.surface)
        }
    }

    /// Says what Forme is about to do with the face it remembers, and offers the
    /// undo in the same breath — a stored face someone can't get rid of is the
    /// version of this feature that would deserve suspicion.
    ///
    /// `ViewThatFits` because the middot reads as one line and only fits like
    /// one: at accessibility text sizes the two halves stack instead of
    /// squeezing the button into an ellipsis.
    private var identityFootnote: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                footnoteLabel
                Text("·")
                resetButton
            }

            VStack(spacing: Theme.Spacing.xs) {
                footnoteLabel
                resetButton
            }
        }
        .formeText(.caption)
        .foregroundStyle(Theme.Colors.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Spacing.xs)
    }

    private var footnoteLabel: some View {
        Label("Looking for your clothes only", systemImage: "person.crop.circle.badge.checkmark")
    }

    private var resetButton: some View {
        Button("Not you?", action: onResetIdentity)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.accent)
            .accessibilityLabel("Not you?")
            .accessibilityHint("Forgets the face Forme looks for, so it can learn a new one.")
    }
}

#Preview("First scan") {
    ScanPrimerView(onScan: {}, onSkip: {})
}

#Preview("Face remembered") {
    ScanPrimerView(seedIsSet: true, onScan: {}, onSkip: {}, onResetIdentity: {})
}
