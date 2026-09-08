import Foundation

/// A single item of clothing the user owns.
///
/// The image itself lives on disk, not in this type: a `Piece` is small enough
/// to keep an index of thousands in memory, and the `WardrobeService` is the
/// only thing that knows where `imageFileName` resolves to.
nonisolated struct Piece: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum Category: String, Codable, CaseIterable, Sendable {
        case top
        case bottom
        case dress
        case outerwear
        case shoes
        case accessory
        case other
    }

    let id: UUID
    var category: Category
    /// File name of the stored cutout PNG, resolved by the WardrobeService.
    var imageFileName: String
    /// PHAsset.localIdentifier of the source photo, when known. Used to skip
    /// already-imported photos on rescan, and later for cloud cleanup/sync.
    var sourceAssetID: String?
    var createdAt: Date
    /// When the source photo was taken. Nil for manual adds / unknown.
    /// Codable-optional so old on-disk indexes keep decoding.
    var capturedAt: Date?

    /// Hand-written for the `capturedAt` default: a bare optional property
    /// gets no memberwise default, and `= nil` on the property itself is
    /// stripped by the formatter.
    init(
        id: UUID,
        category: Category,
        imageFileName: String,
        sourceAssetID: String?,
        createdAt: Date,
        capturedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.imageFileName = imageFileName
        self.sourceAssetID = sourceAssetID
        self.createdAt = createdAt
        self.capturedAt = capturedAt
    }
}

extension Piece.Category {
    var displayName: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .dress: "Dress"
        case .outerwear: "Outerwear"
        case .shoes: "Shoes"
        case .accessory: "Accessory"
        case .other: "Other"
        }
    }

    /// SF Symbol shown when a piece has no image yet, and next to the category
    /// name. SF Symbols has no trousers glyph, so `.bottom` shares the generic
    /// hanger with `.other` — the label beside it is what distinguishes them.
    var symbolName: String {
        switch self {
        case .top: "tshirt"
        case .bottom: "hanger"
        case .dress: "figure.stand.dress"
        case .outerwear: "coat"
        case .shoes: "shoe.2"
        case .accessory: "sunglasses"
        case .other: "hanger"
        }
    }
}
