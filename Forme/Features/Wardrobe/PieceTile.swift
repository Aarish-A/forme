import CoreGraphics
import SwiftUI

/// One garment in the wardrobe grid.
///
/// Every tile is the same shape and sits on the same surface, whatever the
/// photo behind it looked like. That uniformity is the point: a grid of
/// consistent cutouts reads as a considered wardrobe, where a grid of raw
/// camera-roll crops reads as a folder of photos.
struct PieceTile: View {
    /// Whether this tile is taking part in select mode, and how.
    ///
    /// Three states rather than a Bool: "not selecting" and "selected: no" look
    /// nothing alike, because in select mode every tile carries a mark — an
    /// unselected tile has to be something you can see, not an absence you have
    /// to notice against thirty others.
    nonisolated enum Selection {
        case inactive
        case unselected
        case selected

        init(isSelecting: Bool, isSelected: Bool) {
            guard isSelecting else {
                self = .inactive
                return
            }
            self = isSelected ? .selected : .unselected
        }
    }

    let piece: Piece
    let image: CGImage?
    var selection: Selection = .inactive

    /// Portrait, because clothes photograph tall and a square tile crops the
    /// hem off most of them.
    private static let aspectRatio: CGFloat = 3.0 / 4.0

    var body: some View {
        ZStack {
            Theme.Colors.surfaceSecondary

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.sm)
            } else {
                Image(systemName: piece.category.symbolName)
                    .formeText(.screenTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Theme.Radius.md))
        // Dim before the overlay, so the mark itself stays at full strength on
        // a tile that's been passed over.
        .opacity(selection == .unselected ? 0.5 : 1)
        .overlay(alignment: .topTrailing) { selectionMark }
        .animation(Theme.Motion.tap, value: selection)
        .accessibilityElement(children: .ignore)
        // The date is the only non-visual detail that tells thirty tops apart;
        // a category alone reads as the same tile thirty times over.
        .accessibilityLabel(
            "\(piece.category.displayName), added \(piece.createdAt.formatted(date: .abbreviated, time: .omitted))"
        )
    }

    /// The same mark the scan's review grid uses, for the same reason: three
    /// signals for one bit of state — the tick, its shape, and the dimming
    /// behind it — so colour is never carrying the selection on its own.
    @ViewBuilder
    private var selectionMark: some View {
        if selection != .inactive {
            Image(systemName: selection == .selected ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.Colors.surface, Theme.Colors.accent)
                .padding(Theme.Spacing.xs)
        }
    }
}

#Preview {
    let now = Date()
    let withImage = Piece(
        id: UUID(),
        category: .top,
        imageFileName: "preview-top.png",
        sourceAssetID: nil,
        createdAt: now
    )
    let withoutImage = Piece(
        id: UUID(),
        category: .shoes,
        imageFileName: "preview-shoes.png",
        sourceAssetID: nil,
        createdAt: now
    )

    VStack(spacing: Theme.Spacing.md) {
        HStack(spacing: Theme.Spacing.md) {
            PieceTile(piece: withImage, image: TestImageFactory.image(color: .teal))
            PieceTile(piece: withoutImage, image: nil)
        }

        HStack(spacing: Theme.Spacing.md) {
            PieceTile(piece: withImage, image: TestImageFactory.image(color: .teal), selection: .selected)
            PieceTile(piece: withImage, image: TestImageFactory.image(color: .brown), selection: .unselected)
        }
    }
    .formeScreenPadding()
}
