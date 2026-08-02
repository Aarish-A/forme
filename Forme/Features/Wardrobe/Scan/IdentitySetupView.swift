import CoreGraphics
import Foundation
import PhotosUI
import SwiftUI

/// "Is this you?" — the step that turns a scan of everyone's clothes into a
/// scan of yours.
///
/// Deliberately driven by plain values rather than the store: the three states
/// this screen has (still searching, a face to confirm, nothing found) are the
/// whole design, and passing them in means each one previews on its own without
/// scripting a scan to produce it.
///
/// The consent line is not a legal footnote bolted on at the end — it's the
/// answer to the question anyone sensible asks when an app shows them their own
/// face, so it sits with the buttons that act on it.
struct IdentitySetupView: View {
    /// Still looking through the Selfies album.
    let isSearching: Bool
    /// The face Forme thinks is the user's, if it found one.
    let proposedFaceCrop: CGImage?
    /// Anything the scan wants to say about the last attempt — most often "no
    /// face in that photo". Without it, picking an unusable photo would look
    /// like the button did nothing.
    var errorMessage: String?
    let onConfirm: () -> Void
    let onUseSeedPhoto: (Data) -> Void
    let onSkip: () -> Void

    @State private var isPickingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var isOpeningPickedPhoto = false
    @State private var pickerErrorMessage: String?

    /// Grows with Dynamic Type: at accessibility sizes a fixed-size face beside
    /// doubled text reads as an afterthought, and this is the thing being asked
    /// about.
    @ScaledMetric(relativeTo: .largeTitle) private var faceSize: CGFloat = 160

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                switch step {
                case .searching: searchingContent
                case .proposal: proposalContent
                case .noProposal: noProposalContent
                }

                // The picker's own failure wins: it's the more recent thing
                // the user did, and the scan's message may be about the
                // selfie search they've already moved past.
                if let message = pickerErrorMessage ?? errorMessage {
                    StatusLabel(.warning, message)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.xl)
            .animation(Theme.Motion.settle, value: isSearching)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { actions }
        // The out-of-process picker: the user hands over one photo and nothing
        // else, so this screen works even with photo access denied.
        .photosPicker(isPresented: $isPickingPhoto, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in openSeedPhoto(item) }
    }

    // MARK: - States

    /// Named `Step` rather than `State`: a nested type called `State` shadows
    /// SwiftUI's property wrapper for the whole view.
    private enum Step {
        case searching
        case proposal
        case noProposal
    }

    private var step: Step {
        if isSearching {
            .searching
        } else if proposedFaceCrop == nil {
            .noProposal
        } else {
            .proposal
        }
    }

    private var searchingContent: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()

            VStack(spacing: Theme.Spacing.sm) {
                Text("Finding you in your selfies…")
                    .formeText(.sectionTitle)
                    .multilineTextAlignment(.center)

                Text(
                    """
                    Forme is looking for the face that turns up most, so it can tell your clothes \
                    from everyone else's.
                    """
                )
                .formeText(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var proposalContent: some View {
        if let proposedFaceCrop {
            VStack(spacing: Theme.Spacing.lg) {
                Image(decorative: proposedFaceCrop, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: faceSize, height: faceSize)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(Theme.Colors.outline))
                    // The picture *is* the question, so it can't be decorative
                    // to VoiceOver even though it carries no readable content.
                    .accessibilityElement()
                    .accessibilityLabel("The face that turns up most in your recent selfies")

                VStack(spacing: Theme.Spacing.sm) {
                    Text("Is this you?")
                        .formeText(.sectionTitle)
                        .multilineTextAlignment(.center)

                    Text("Forme will then pick out clothes from photos of you, and leave everyone else's alone.")
                        .formeText(.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var noProposalContent: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .formeText(.screenTitle)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Which face is yours?")
                    .formeText(.sectionTitle)
                    .multilineTextAlignment(.center)

                Text("Pick a photo of yourself so Forme knows whose clothes to look for.")
                    .formeText(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Actions

    /// Pinned to the bottom, with the prose scrolling above: at accessibility
    /// text sizes a single VStack pushes the buttons off-screen, and skipping
    /// has to stay reachable — this step is optional by design.
    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            switch step {
            case .searching:
                Button("Skip for Now", action: onSkip)
                    .buttonStyle(.formeSecondary)

            case .proposal:
                Button("Yes, That's Me", action: onConfirm)
                    .buttonStyle(.formePrimary)

                choosePhotoButton(style: .formeSecondary)

                Button("Skip for Now", action: onSkip)
                    .buttonStyle(.formeSecondary)

            case .noProposal:
                choosePhotoButton(style: .formePrimary)

                Button("Skip for Now", action: onSkip)
                    .buttonStyle(.formeSecondary)
            }

            Text(
                """
                Face matching happens entirely on your iPhone. Nothing about your face leaves your device, \
                nothing is used for training, and you can reset this anytime.
                """
            )
            .formeText(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.top, Theme.Spacing.xs)
        }
        .disabled(isOpeningPickedPhoto)
        .frame(maxWidth: .infinity)
        .formeScreenPadding()
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.surface)
    }

    /// Generic over the style so the same button can lead on the screen with no
    /// proposal and support "Yes, That's Me" on the one that has it.
    private func choosePhotoButton(style: some PrimitiveButtonStyle) -> some View {
        Button(isOpeningPickedPhoto ? "Opening Your Photo…" : "Choose a Photo of Me") {
            pickerErrorMessage = nil
            isPickingPhoto = true
        }
        .buttonStyle(style)
    }

    /// The picker hands back an item, not bytes; the store wants bytes. This is
    /// the only work this screen does, and it's one photo, so it stays here
    /// rather than becoming a service.
    private func openSeedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }

        isOpeningPickedPhoto = true
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            isOpeningPickedPhoto = false
            // Cleared so picking the same photo twice still registers as a
            // change — and so a failure can be retried.
            pickedItem = nil

            guard let data else {
                pickerErrorMessage = "That photo wouldn't open. Try picking another one."
                return
            }
            onUseSeedPhoto(data)
        }
    }
}

#Preview("Searching") {
    IdentitySetupView(
        isSearching: true,
        proposedFaceCrop: nil,
        onConfirm: {},
        onUseSeedPhoto: { _ in },
        onSkip: {}
    )
}

#Preview("Proposal") {
    IdentitySetupView(
        isSearching: false,
        proposedFaceCrop: TestImageFactory.image(color: .brown, size: 256),
        onConfirm: {},
        onUseSeedPhoto: { _ in },
        onSkip: {}
    )
}

#Preview("Nothing found") {
    IdentitySetupView(
        isSearching: false,
        proposedFaceCrop: nil,
        onConfirm: {},
        onUseSeedPhoto: { _ in },
        onSkip: {}
    )
}

#Preview("Photo didn't work") {
    IdentitySetupView(
        isSearching: false,
        proposedFaceCrop: nil,
        errorMessage: "Forme couldn't find a face in that photo. Try one where you're facing the camera.",
        onConfirm: {},
        onUseSeedPhoto: { _ in },
        onSkip: {}
    )
}
