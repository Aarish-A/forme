import Accessibility
import SwiftUI
import UIKit

/// The last word on what the scan found.
///
/// Everything starts selected, so the fast path is one tap. Deselecting is the
/// exception, not the chore — nobody should have to confirm forty photos one at
/// a time to get a wardrobe.
///
/// The grid shows *groups*, not photos: twenty frames of one photoshoot are one
/// decision, and the best of them is already picked. The "+N" opens the rest for
/// anyone who disagrees, which is what makes the grouping safe to do at all.
struct ScanReviewView: View {
    let store: ScanStore
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var isConfirmingDiscard = false
    /// Groups the user has opened up. Local to the screen: which bursts someone
    /// unfolded while deciding is not something the scan needs to know.
    @State private var expandedGroupIDs: Set<Int> = []

    init(store: ScanStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]
    }

    /// One cell of the grid: a group's representative, or one of the members
    /// showing because that group is open.
    private struct Tile: Identifiable {
        let candidate: ScanStore.Candidate
        /// How many similar photos this tile stands in for. Zero on members and
        /// on groups of one.
        let similarCount: Int
        let groupID: Int
        /// Precomputed at flatten time, where the group structure still exists:
        /// representatives are numbered over groups (so expanding one never
        /// renumbers the tiles a VoiceOver user has already heard), and members
        /// say their place inside the group — flat adjacency is the only other
        /// signal of where a group ends, and it's invisible.
        let accessibilityLabel: String

        var id: String {
            candidate.id
        }
    }

    /// Expansion happens in place — a group's members follow its representative
    /// in the same grid, so nothing jumps to a different screen or shifts the
    /// tiles above it.
    private func tiles(for groups: [ScanStore.CandidateGroup]) -> [Tile] {
        groups.enumerated().flatMap { groupIndex, group -> [Tile] in
            let representative = Tile(
                candidate: group.representative,
                similarCount: group.others.count,
                groupID: group.id,
                accessibilityLabel: Self.representativeLabel(group, index: groupIndex, total: groups.count)
            )
            guard expandedGroupIDs.contains(group.id) else { return [representative] }
            return [representative] + group.others.enumerated().map { offset, member in
                Tile(
                    candidate: member,
                    similarCount: 0,
                    groupID: group.id,
                    accessibilityLabel: Self.memberLabel(member, index: offset, total: group.others.count)
                )
            }
        }
    }

    var body: some View {
        if store.candidates.isEmpty {
            emptyState
        } else {
            reviewContent
        }
    }

    /// An empty review has four distinct causes, and telling the user the
    /// wrong one blames photos Forme never saw: limited access with nothing
    /// shared means nothing was scanned at all, an older scan past the last
    /// photo means the library is simply finished, an emptied-out rescan means
    /// they're up to date, and only the last case means the scan genuinely
    /// found nothing.
    @ViewBuilder
    private var emptyState: some View {
        if store.authorization == .limited, store.totalCount == 0 {
            ContentUnavailableView {
                Label("No photos shared", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(
                    """
                    Forme can only see the photos you've shared, and there was nothing new to scan. \
                    You can share more, or allow full access in Settings.
                    """
                )
            } actions: {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.formePrimary)
                Button("Done", action: onClose)
                    .buttonStyle(.formeSecondary)
            }
        } else if store.isOlderScan, store.totalCount == 0, store.alreadyImportedCount == 0 {
            // "Scan Older Photos" past the last photo: nothing was looked at,
            // so blaming the photos would be wrong — the library is finished.
            ContentUnavailableView {
                Label("That's everything", systemImage: "checkmark.circle")
            } description: {
                Text("Forme has scanned all the way back through your photo library — there are no older photos left.")
            } actions: {
                Button("Done", action: onClose)
                    .buttonStyle(.formePrimary)
            }
        } else if store.totalCount == 0, store.alreadyImportedCount > 0 {
            ContentUnavailableView {
                Label("You're up to date", systemImage: "checkmark.circle")
            } description: {
                Text("The clothes in your \(scannedPhotosNoun) are already in your wardrobe.")
            } actions: {
                Button("Done", action: onClose)
                    .buttonStyle(.formePrimary)
            }
        } else {
            ContentUnavailableView {
                Label("No clothes spotted", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(
                    "We didn't spot clothes in your \(scannedPhotosNoun) — "
                        + "you can add pieces from your library instead."
                )
            } actions: {
                Button("Done", action: onClose)
                    .buttonStyle(.formePrimary)
            }
        }
    }

    /// Which photos this scan actually looked at, so the empty states never
    /// say "recent" about a scan that only went backwards.
    private var scannedPhotosNoun: String {
        store.isOlderScan ? "older photos" : "recent photos"
    }

    /// Header and grid scroll together and the actions pin to the bottom, like
    /// the primer and denied screens: at accessibility text sizes the header
    /// alone can outgrow the screen, and in a fixed VStack the grid — the one
    /// flexible child — would absorb all of that loss and vanish.
    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                gridContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            actions
                .formeScreenPadding()
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.surface)
        }
        .confirmationDialog(
            "Discard the \(store.candidates.count) photos Forme found?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'd need to scan your photos again to see them.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Keep the photos that show your clothes")
                .formeText(.sectionTitle)

            ScanCoverageFootnote(scannedThroughDate: store.scannedThroughDate)

            if store.authorization == .limited {
                Text("Forme can only see the photos you've shared. You can allow full access in Settings.")
                    .formeText(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

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
    private var gridContent: some View {
        // Built once per redraw rather than per tile: sectioning rebuilds the
        // whole grouping from the candidate pool, which is cheap, but not cheap
        // enough to do inside a loop.
        let sections = store.groupsByConfidence

        if sections.isEmpty {
            Text("Everything Forme found looks like other people. Tap Show above to take a look.")
                .formeText(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xl)
        } else {
            // One section needs no heading — with identity off there is only
            // ever one, and labelling it "Looks like you" would claim knowledge
            // the scan doesn't have.
            let showsHeadings = sections.count > 1
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(sections, id: \.confidence) { section in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if showsHeadings {
                            ScanReviewSectionHeader(
                                confidence: section.confidence,
                                groups: section.groups,
                                onKeepAll: {
                                    store.keepAll(inGroups: Set(section.groups.map(\.id)))
                                }
                            )
                        }
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                            ForEach(tiles(for: section.groups)) { tile in
                                tileCell(tile)
                            }
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button("Add \(store.selectedCount) to Wardrobe") {
                Task { await store.confirmSelection() }
            }
            .buttonStyle(.formePrimary)
            .disabled(store.selectedCount == 0)

            // Named for what it does, and confirmed: everything on this
            // screen is in memory only, and "Not Now" would promise the
            // minutes of scanning behind it are still there later.
            Button("Discard These") { isConfirmingDiscard = true }
                .buttonStyle(.formeSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tiles

    /// Two sibling controls rather than a button inside a button: the badge has
    /// its own job (open the group) and nesting it in the selection button would
    /// make one tap mean two things.
    private func tileCell(_ tile: Tile) -> some View {
        ZStack(alignment: .bottomTrailing) {
            selectionButton(tile)

            if tile.similarCount > 0 {
                expandButton(tile)
            }
        }
    }

    private func selectionButton(_ tile: Tile) -> some View {
        Button {
            store.toggleSelection(tile.candidate.id)
        } label: {
            ScanThumbnail(image: tile.candidate.thumbnail, isDimmed: !tile.candidate.isSelected)
                .overlay(alignment: .topTrailing) {
                    // Three signals for one bit of state: the mark, its shape,
                    // and the tile dimming. Someone who can't tell the colours
                    // apart still sees which photos are staying.
                    Image(systemName: tile.candidate.isSelected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.Colors.surface, Theme.Colors.accent)
                        .padding(Theme.Spacing.xs)
                }
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.tap, value: tile.candidate.isSelected)
        // Position plus guess, because the photo itself is only pixels: a
        // VoiceOver user deciding keep-or-discard per tile needs a way to tell
        // twenty "Top"s apart and to find their place again. The "+N" is a
        // visual badge, so it has to be said here or it doesn't exist.
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityAddTraits(tile.candidate.isSelected ? [.isSelected] : [])
        .accessibilityHint("Keeps or discards this photo.")
    }

    private func expandButton(_ tile: Tile) -> some View {
        let isExpanded = expandedGroupIDs.contains(tile.groupID)

        return Button {
            toggleExpansion(tile.groupID, similarCount: tile.similarCount)
        } label: {
            ScanSimilarBadge(count: tile.similarCount, isInteractive: true, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded
                ? "Hide the \(tile.similarCount) similar photos"
                : "Show \(tile.similarCount) similar photos"
        )
    }

    private static func representativeLabel(_ group: ScanStore.CandidateGroup, index: Int, total: Int) -> String {
        let category = group.representative.suggestedCategory.displayName.lowercased()
        let base = "Photo \(index + 1) of \(total), looks like a \(category)"
        guard !group.others.isEmpty else { return base }
        return "\(base), and \(group.others.count) similar photos"
    }

    private static func memberLabel(_ candidate: ScanStore.Candidate, index: Int, total: Int) -> String {
        let category = candidate.suggestedCategory.displayName.lowercased()
        return "Similar photo \(index + 1) of \(total) in this group, looks like a \(category)"
    }

    private func toggleExpansion(_ groupID: Int, similarCount: Int) {
        withAnimation(Theme.Motion.settle) {
            if expandedGroupIDs.contains(groupID) {
                expandedGroupIDs.remove(groupID)
            } else {
                expandedGroupIDs.insert(groupID)
            }
        }
        // The badge's own label flips, but what the toggle revealed is pure
        // layout — without an announcement a VoiceOver user hears nothing
        // happen at all.
        let revealed = expandedGroupIDs.contains(groupID)
        AccessibilityNotification.Announcement(
            revealed
                ? "Showing \(similarCount) similar photos after this one"
                : "Hid \(similarCount) similar photos"
        ).post()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

/// Says what the identity filter took out, and hands back the undo.
///
/// Filtering by face is the one part of the scan that can be wrong in a way the
/// user can't see, so it is never silent: the count is stated, and one tap puts
/// the photos back on screen.
struct ScanHiddenOthersBanner: View {
    let count: Int
    let isShowing: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Label(message, systemImage: "person.2.slash")
                .formeText(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(isShowing ? "Hide" : "Show", action: onToggle)
                .buttonStyle(.plain)
                .formeText(.caption)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHint("Shows or hides the photos Forme thinks are of other people.")
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Colors.surfaceSecondary, in: .rect(cornerRadius: Theme.Radius.md))
    }

    private var message: String {
        // The count is photos, not groups — `ScanStore.hiddenOtherCount` sums
        // the members of hidden groups, so this number is the honest one.
        let photos = count == 1 ? "1 photo that looks" : "\(count) photos that look"
        return isShowing
            ? "Showing \(photos) like other people"
            : "Hid \(photos) like other people"
    }
}

#Preview("Found clothes") {
    let store = ScanStore.previewScan()

    ScanReviewView(store: store, onClose: {})
        .task { await store.beginScan() }
}

#Preview("A burst of near-identical photos") {
    let store = ScanStore.previewGroupedScan()

    ScanReviewView(store: store, onClose: {})
        .task { await store.beginScan() }
}

#Preview("Nothing found") {
    ScanReviewView(store: .previewScan(assetCount: 0), onClose: {})
}

#Preview("Hidden others") {
    VStack(spacing: Theme.Spacing.md) {
        ScanHiddenOthersBanner(count: 3, isShowing: false, onToggle: {})
        ScanHiddenOthersBanner(count: 3, isShowing: true, onToggle: {})
        ScanHiddenOthersBanner(count: 1, isShowing: false, onToggle: {})
    }
    .formeScreenPadding()
}
