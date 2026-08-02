import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The photo-library scan, start to finish, presented as a sheet.
///
/// This view owns the flow and nothing else: it switches on `store.phase` and
/// hands each phase to a view that knows only about that step. The short states
/// — waiting on permission, saving, done — live here rather than in files of
/// their own, because each is a sentence and a spinner.
struct ScanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// `@State` because the flow owns the store for as long as the sheet is up:
    /// the parent rebuilds this view on every redraw, and the scan in progress
    /// must survive that.
    @State private var store: ScanStore

    init(store: ScanStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            phaseContent
                .formeTransition(.opacity.combined(with: .move(edge: .trailing)))
                .animation(Theme.Motion.surface, value: store.phase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.surface)
                .navigationTitle("Scan Photos")
                .navigationBarTitleDisplayMode(.inline)
        }
        // A swipe-down mid-save would strand the pieces the user just approved
        // (the save runs on, but the wardrobe has already re-read), and in
        // review it would silently discard a whole scan — those exits go
        // through the buttons instead.
        .interactiveDismissDisabled(
            store.phase == .saving || (store.phase == .review && !store.candidates.isEmpty)
        )
        // Coming back from Settings with access granted must not strand the
        // user on a stale "access is off" screen.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, store.phase == .denied else { return }
            Task { await store.beginScan() }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .primer:
            ScanPrimerView(
                seedIsSet: store.seedIsSet,
                onScan: { Task { await store.beginScan() } },
                onSkip: { dismiss() },
                onResetIdentity: { Task { await store.resetIdentity() } }
            )
        case .requestingAccess:
            ScanWaitingView(message: "Checking photo access…")
        case .denied:
            deniedContent
        case .identitySetup:
            IdentitySetupView(
                isSearching: store.isSearchingSelfies,
                proposedFaceCrop: store.proposedFaceCrop,
                errorMessage: store.errorMessage,
                onConfirm: { Task { await store.confirmProposedFace() } },
                onUseSeedPhoto: { data in Task { await store.useSeedPhoto(data) } },
                onSkip: { Task { await store.skipIdentityThisScan() } }
            )
        case .scanning:
            ScanProgressView(store: store, onCancel: { dismiss() })
        case .review:
            ScanReviewView(store: store, onClose: { dismiss() })
        case .saving:
            ScanWaitingView(message: savingMessage)
        case let .finished(addedCount):
            finishedContent(addedCount: addedCount)
        }
    }

    /// Determinate on purpose: saving thirty photos is tens of seconds, and an
    /// anonymous spinner that long reads as "stuck".
    private var savingMessage: String {
        let current = min(store.savedCount + 1, store.savingTotal)
        return "Adding \(current) of \(store.savingTotal) to your wardrobe…"
    }

    /// Prose scrolls and the actions pin to the bottom, here and in the primer:
    /// at accessibility text sizes a fixed VStack truncates the one sentence
    /// each screen exists to deliver, with no way to read the rest.
    private var deniedContent: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "lock.iphone")
                    .formeText(.screenTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.sm) {
                    Text("Forme can't see your photos")
                        .formeText(.sectionTitle)
                        .multilineTextAlignment(.center)

                    StatusLabel(
                        .warning,
                        """
                        Photo access is off, so there's nothing to scan. You can turn it on in Settings — \
                        photos still never leave your iPhone.
                        """
                    )
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
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.formePrimary)

                // The scene-phase re-check misses the (usual) case where iOS
                // relaunched us, but also the ones where it didn't — this is
                // the explicit way forward after flipping access on.
                Button("Try Again") {
                    Task { await store.beginScan() }
                }
                .buttonStyle(.formeSecondary)

                Button("Not Now") { dismiss() }
                    .buttonStyle(.formeSecondary)
            }
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.surface)
        }
    }

    private func finishedContent(addedCount: Int) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                StatusLabel(addedCount == 0 ? .warning : .success, Self.addedMessage(addedCount))
                    .multilineTextAlignment(.center)

                if let errorMessage = store.errorMessage {
                    StatusLabel(.error, errorMessage)
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
                Button("Done") { dismiss() }
                    .buttonStyle(.formePrimary)

                #if DEBUG
                    if let report = store.lastReport {
                        ScanDiagnosticsButton(report: report)
                    }
                #endif
            }
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.surface)
        }
    }

    /// Spelled out per count rather than "1 piece(s)": the sentence someone
    /// reads at the end of their first scan is worth getting right.
    private static func addedMessage(_ count: Int) -> String {
        switch count {
        case 0: "Nothing added — you can scan again any time."
        case 1: "Added 1 piece to your wardrobe."
        default: "Added \(count) pieces to your wardrobe."
        }
    }
}

/// A quiet holding screen for the two moments the app is busy on the user's
/// behalf and there is nothing to decide.
struct ScanWaitingView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text(message)
                .formeText(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .formeScreenPadding()
    }
}

/// How far back the scan has reached, in the only unit anyone thinks in.
///
/// A scan looks at the newest few thousand photos, which is an arbitrary line
/// unless the app says where it fell. "Scanned back to March 2025" turns a cap
/// into a fact the user can act on — and it's the same sentence the "Scan Older
/// Photos" entry point uses, so the two read as one idea.
struct ScanCoverageFootnote: View {
    let scannedThroughDate: Date?

    var body: some View {
        if let scannedThroughDate {
            Text("Scanned back to \(scannedThroughDate.formatted(.dateTime.month(.wide).year()))")
                .formeText(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}

/// One scanned photo as a square tile.
///
/// Shared by the live scan grid and the review grid so a photo doesn't visibly
/// change shape between the two — the same picture in the same place is most of
/// what makes the review feel like a continuation rather than a new screen.
struct ScanThumbnail: View {
    let image: CGImage
    var isDimmed = false

    var body: some View {
        Theme.Colors.surfaceSecondary
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.md))
            .opacity(isDimmed ? 0.45 : 1)
    }
}

/// The "+3" on a tile that stands in for a burst of near-identical photos.
///
/// Purely a label while the scan runs and a control in review, but the same
/// shape in both, so the badge someone watched appear is the one they tap.
struct ScanSimilarBadge: View {
    let count: Int
    /// Whether tapping it does anything. Drives the chevron, which is the only
    /// honest way to say "there's more here" without a gesture to discover.
    var isInteractive = false
    var isExpanded = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("+\(count)")
            if isInteractive {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
        }
        .formeText(.caption)
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        // Nearly opaque rather than a material: it sits on a photo, and the
        // count has to stay readable over whatever colour is under it.
        .background(Theme.Colors.surface.opacity(0.92), in: .capsule)
        .padding(Theme.Spacing.xs)
    }
}

// MARK: - Previews

extension ScanStore {
    /// A store wired to seeded in-memory services, so the whole scan flow
    /// previews offline. Mirrors `InMemoryWardrobeService.previewSeeded()`.
    ///
    /// Identity is off by default: an unavailable face model is what the
    /// Simulator does anyway, and it keeps a preview of the scan about the scan.
    /// Pass `identityAvailable: true` to land on the identity step instead.
    static func previewScan(assetCount: Int = 6, identityAvailable: Bool = false) -> ScanStore {
        ScanStore(
            photoLibrary: InMemoryPhotoLibraryService.previewSeeded(count: assetCount),
            detector: StubGarmentDetector(),
            wardrobe: InMemoryWardrobeService(),
            history: InMemoryScanHistoryService(),
            faceIdentity: StubFaceIdentityService(isAvailable: identityAvailable),
            faceSeed: InMemoryFaceSeedService()
        )
    }

    /// A store whose photos all land in one group, so the grouped review — the
    /// representative tile and its "+N" — previews with something to expand.
    static func previewGroupedScan(assetCount: Int = 6) -> ScanStore {
        var assets: [PhotoAsset] = []
        var images: [String: CGImage] = [:]

        for index in 0 ..< assetCount {
            let id = "preview-burst-\(index)"
            // A minute apart: inside the grouping window, unlike the day-apart
            // photos the standard seed uses.
            assets.append(PhotoAsset(id: id, creationDate: Date(timeIntervalSinceNow: TimeInterval(-index * 60))))
            if let image = TestImageFactory.image(color: TestImageFactory.Color.palette(index)) {
                images[id] = image
            }
        }

        // One fingerprint for every photo, so the distance between any two is
        // zero and the whole burst folds into a single tile.
        var detector = StubGarmentDetector()
        detector.fingerprintResult = { _ in ImageFingerprint(vector: [0, 0, 0]) }

        return ScanStore(
            photoLibrary: InMemoryPhotoLibraryService(authorization: .full, assets: assets, images: images),
            detector: detector,
            wardrobe: InMemoryWardrobeService(),
            history: InMemoryScanHistoryService(),
            faceIdentity: StubFaceIdentityService(isAvailable: false),
            faceSeed: InMemoryFaceSeedService()
        )
    }
}

#Preview("Thumbnail") {
    if let image = TestImageFactory.image(color: .teal, size: 128) {
        HStack(spacing: Theme.Spacing.md) {
            ScanThumbnail(image: image)
                .overlay(alignment: .bottomTrailing) { ScanSimilarBadge(count: 4) }

            ScanThumbnail(image: image, isDimmed: true)
                .overlay(alignment: .bottomTrailing) {
                    ScanSimilarBadge(count: 4, isInteractive: true, isExpanded: true)
                }
        }
        .frame(width: 240)
    }
}

#Preview("Flow") {
    ScanFlowView(store: .previewScan())
}

// Tapping "Scan My Photos" here lands on the identity step: the stub face
// service is available but finds no faces, which is the "pick a photo of
// yourself" variant.
#Preview("Flow with identity") {
    ScanFlowView(store: .previewScan(identityAvailable: true))
}

#Preview("Waiting") {
    ScanWaitingView(message: "Adding to your wardrobe…")
}

#Preview("Coverage") {
    ScanCoverageFootnote(scannedThroughDate: Date(timeIntervalSinceNow: -60 * 60 * 24 * 400))
}
