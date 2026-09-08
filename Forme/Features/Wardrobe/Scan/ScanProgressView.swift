import SwiftUI

/// The scan while it runs.
///
/// Tiles appear as photos are found rather than at the end, which is the whole
/// point: waiting on a progress bar with nothing to show reads as "is this
/// working?", and a grid filling up reads as "it's finding my clothes".
///
/// It shows groups, not photos, for the same reason review does: twenty tiles
/// of one photoshoot arriving in a row looks like a bug, and the grid the user
/// watches fill up should be the grid they end up deciding on.
struct ScanProgressView: View {
    let store: ScanStore
    let onCancel: () -> Void

    /// Computed rather than stored: a `private` stored property would drag the
    /// memberwise initialiser down to `private` with it.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]
    }

    /// Header and grid scroll together and the actions pin to the bottom, like
    /// the review screen: at accessibility text sizes a fixed VStack truncates
    /// the header and starves the grid.
    var body: some View {
        // Hoisted once per redraw: `store.groups` rebuilds the whole grouping
        // from the candidate pool, and this screen redraws on every scan event
        // — recomputing it per tile would make rendering quadratic-ish.
        let groups = store.groups

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                foundGrid(groups)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            actions(foundCount: groups.count)
                .formeScreenPadding()
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.surface)
        }
        // Covers every way out — the user cancelling, the sheet being swiped
        // away, the flow moving on — so no photo is left decoding for a screen
        // that has gone.
        .onDisappear { store.cancelScanning() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Looking through your photos")
                .formeText(.sectionTitle)

            ProgressView(value: Double(store.scannedCount), total: Double(max(store.totalCount, 1))) {
                Text("Scanned \(store.scannedCount) of \(store.totalCount)")
                    .formeText(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .tint(Theme.Colors.accent)

            ScanCoverageFootnote(scannedThroughDate: store.scannedThroughDate)

            if store.authorization == .limited {
                Text("Forme can only see the photos you've shared. You can allow full access in Settings.")
                    .formeText(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            // The identity filter is never silent, even mid-scan: without
            // this, a scan whose finds are all being set aside reads as a
            // scan finding nothing, with Cancel the only visible way out.
            if store.hiddenOtherCount > 0 {
                ScanHiddenOthersBanner(
                    count: store.hiddenOtherCount,
                    isShowing: store.showOthers,
                    onToggle: { store.toggleShowOthers() }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func foundGrid(_ groups: [ScanStore.CandidateGroup]) -> some View {
        if groups.isEmpty {
            Text("Nothing yet — clothes will appear here as Forme finds them.")
                .formeText(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xl)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    groupTile(group, index: index, total: groups.count)
                }
            }
            .animation(Theme.Motion.settle, value: groups.count)
        }
    }

    private func groupTile(_ group: ScanStore.CandidateGroup, index: Int, total: Int) -> some View {
        ScanThumbnail(image: group.representative.thumbnail)
            .overlay(alignment: .bottomTrailing) {
                if !group.others.isEmpty {
                    ScanSimilarBadge(count: group.others.count)
                }
            }
            // The image itself is decorative, so the tile needs to become an
            // element before it can carry a label. The position is the only
            // non-visual way to tell one "Top" from the next twenty of them,
            // and the badge only exists visually until it's said out loud.
            .accessibilityElement()
            .accessibilityLabel(Self.tileLabel(group, index: index, total: total))
    }

    private static func tileLabel(_ group: ScanStore.CandidateGroup, index: Int, total: Int) -> String {
        let category = group.representative.suggestedCategory.displayName.lowercased()
        let base = "Photo \(index + 1) of \(total), looks like a \(category)"
        guard !group.others.isEmpty else { return base }
        return "\(base), and \(group.others.count) similar photos"
    }

    private func actions(foundCount: Int) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            // Gated on candidates rather than visible groups: when the
            // identity filter has set everything aside so far, review is
            // still where the banner's "Show" leads, and it must be reachable
            // without waiting out the whole scan.
            Button("Review \(foundCount) Found") {
                store.stopAndReview()
            }
            .buttonStyle(.formePrimary)
            .disabled(store.candidates.isEmpty)

            Button("Cancel", action: onCancel)
                .buttonStyle(.formeSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Scanning") {
    let store = ScanStore.previewScan()

    ScanProgressView(store: store, onCancel: {})
        .task { await store.beginScan() }
}

#Preview("Burst") {
    let store = ScanStore.previewGroupedScan()

    ScanProgressView(store: store, onCancel: {})
        .task { await store.beginScan() }
}
