import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Observable state for everything the user owns.
///
/// One store for the whole app, not one per screen: the grid, the detail sheet
/// and the scan flow all have to agree about what's in the wardrobe, and the
/// cheapest way to guarantee that is for there to be a single copy.
///
/// Nothing here throws. A wardrobe that refuses to open because one image is
/// unreadable would be worse than useless on a rushed morning, so failures
/// degrade — a missing cutout falls back to the original photo, a missing
/// suggestion falls back to `.other` — and only the ones that lose data reach
/// the user as `errorMessage`.
@Observable
final class WardrobeStore {
    /// Newest first, matching what every `WardrobeService` returns.
    private(set) var pieces: [Piece] = []

    /// Decoded cutouts keyed by piece id. Kept beside `pieces` rather than on
    /// `Piece` so the model stays a small codable value and the index can be
    /// loaded without the images.
    private(set) var images: [UUID: CGImage] = [:]

    /// Starts `true`: the first frame renders before `refresh()` has run, and a
    /// user with a full wardrobe must never be flashed "your wardrobe is empty"
    /// while it loads. The first real load settles it either way.
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    private let wardrobe: any WardrobeService
    private let detector: any GarmentDetector

    init(wardrobe: any WardrobeService, detector: any GarmentDetector) {
        self.wardrobe = wardrobe
        self.detector = detector
    }

    /// Reloads the index and its images. Safe to call repeatedly — the wardrobe
    /// screen calls it on appear and after any sheet that might have added to it.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        await load()
    }

    /// Manual add from the system photo picker.
    ///
    /// Each photo is lifted off its background if Vision can manage it, and
    /// categorised from the classifier's labels if it has an opinion. Both are
    /// improvements, not requirements: a piece is created either way.
    func addFromPickedImages(_ imageDatas: [Data]) async {
        guard !imageDatas.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        var failed = 0
        for data in imageDatas {
            do {
                try await addPiece(from: data)
            } catch {
                failed += 1
                Log.feature.error("Adding a picked photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        await load()

        // After `load()`, which clears the message on a successful reload.
        if failed > 0 {
            errorMessage = Copy.addFailed(count: failed)
        }
        Log.feature.info("Added \(imageDatas.count - failed, privacy: .public) pieces from the photo picker")
    }

    /// Corrects the category the classifier guessed. A no-op if it's unchanged.
    func updateCategory(_ category: Piece.Category, for piece: Piece) async {
        // Read the current value rather than trusting the caller's copy: a
        // detail sheet holds the piece it was opened with, which goes stale the
        // first time the user changes their mind.
        let current = pieces.first { $0.id == piece.id } ?? piece
        guard current.category != category else { return }

        var updated = current
        updated.category = category

        do {
            try await wardrobe.updatePiece(updated)
            if let index = pieces.firstIndex(where: { $0.id == updated.id }) {
                pieces[index] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = Copy.updateFailed
            Log.feature.error("Updating a piece failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ piece: Piece) async {
        do {
            try await wardrobe.removePiece(id: piece.id)
            pieces.removeAll { $0.id == piece.id }
            images[piece.id] = nil
            errorMessage = nil
        } catch {
            errorMessage = Copy.removeFailed
            Log.feature.error("Removing a piece failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bulk removal, from the wardrobe's select mode.
    ///
    /// One service call rather than a loop of `remove(_:)`, so clearing out a
    /// bad scan is a single index rewrite instead of a hundred — and so a
    /// partial failure can't leave the grid disagreeing with what's on disk.
    /// Ids that are already gone are the service's problem to ignore.
    func remove(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        do {
            try await wardrobe.removePieces(ids: ids)
            pieces.removeAll { ids.contains($0.id) }
            for id in ids {
                images[id] = nil
            }
            errorMessage = nil
            Log.feature.info("Removed \(ids.count, privacy: .public) pieces")
        } catch {
            errorMessage = ids.count == 1 ? Copy.removeFailed : Copy.removeManyFailed
            Log.feature.error("Removing pieces failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private func load() async {
        do {
            let loaded = try await wardrobe.loadPieces()

            var encoded: [(id: UUID, data: Data)] = []
            for piece in loaded {
                if let data = try await wardrobe.imageData(for: piece) {
                    encoded.append((piece.id, data))
                }
            }

            pieces = loaded
            images = await PieceImage.decodeAll(encoded)
            errorMessage = nil
        } catch {
            errorMessage = Copy.loadFailed
            Log.feature.error("Loading the wardrobe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addPiece(from data: Data) async throws {
        // Decode straight to the size the scan path stores. The picker hands
        // over original bytes, and a 12MP photo kept at full resolution would
        // be tens of megabytes of PNG on disk and in the image cache — an
        // order of magnitude more than the identical piece added by a scan.
        guard let source = await PieceImage.decode(data, maxPixelSize: ScanPipeline.cutoutPixelSize) else {
            throw PickedPhotoError.unreadable
        }

        let lifted = await cutout(from: source)
        let category = await suggestedCategory(for: source)

        guard let png = await PieceImage.png(lifted ?? source) else { throw PickedPhotoError.unencodable }
        // No `capturedAt`: the picker hands over bytes, not an asset, so the
        // only date we could claim is the one we'd be guessing at. A piece with
        // an unknown capture date sorts by when it was added, which is honest.
        try await wardrobe.addPiece(imagePNG: png, category: category, sourceAssetID: nil, capturedAt: nil)
    }

    /// Vision fails routinely on the Simulator and on photos with no clear
    /// subject. A failed lift means we keep the whole photo, not that we lose it.
    private func cutout(from image: CGImage) async -> CGImage? {
        do {
            return try await detector.cutout(from: image, focus: nil)
        } catch {
            return nil
        }
    }

    private func suggestedCategory(for image: CGImage) async -> Piece.Category {
        do {
            let observation = try await detector.analyze(image)
            guard observation.isClothingCandidate else { return .other }
            return GarmentLabelMap.category(for: observation.labels)
        } catch {
            return .other
        }
    }

    /// What the user reads when something fails. `WardrobeError` isn't a
    /// `LocalizedError`, and even if it were, "the operation couldn't be
    /// completed" isn't a sentence to put in front of someone getting dressed.
    private enum Copy {
        static let loadFailed = "We couldn't open your wardrobe. Please try again."
        static let updateFailed = "That change didn't save. Please try again."
        static let removeFailed = "We couldn't remove that piece. Please try again."
        static let removeManyFailed = "We couldn't remove those pieces. Please try again."

        static func addFailed(count: Int) -> String {
            count == 1
                ? "One photo couldn't be added. Please try again."
                : "\(count) photos couldn't be added. Please try again."
        }
    }
}

/// Why one picked photo didn't become a piece. Never shown as-is — the user
/// sees a count, because which of five photos failed isn't actionable.
private nonisolated enum PickedPhotoError: Error {
    case unreadable
    case unencodable
}

/// PNG bytes ↔ `CGImage`.
///
/// The async members are `@concurrent` so this work actually leaves the main
/// actor: under `NonisolatedNonsendingByDefault` a plain `nonisolated` async
/// function runs on its *caller's* actor, and every caller here is the
/// main-actor store. A wardrobe of a few hundred pieces is a few hundred PNG
/// decodes, and doing that while SwiftUI is drawing is exactly how a grid
/// drops frames on first appearance.
private nonisolated enum PieceImage {
    /// Decodes at most `maxPixelSize` on the longest edge, baking in EXIF
    /// orientation — one ImageIO call that never materialises the full bitmap.
    @concurrent
    static func decode(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent
    static func decodeAll(_ items: [(id: UUID, data: Data)]) async -> [UUID: CGImage] {
        var decoded: [UUID: CGImage] = [:]
        for item in items {
            guard
                let source = CGImageSourceCreateWithData(item.data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                continue
            }
            decoded[item.id] = image
        }
        return decoded
    }

    /// Alpha-preserving PNG encoding. Delegated rather than reimplemented so
    /// the app has exactly one encoder — `TestImageFactory` is misnamed for a
    /// plain ImageIO helper, but a second copy of it would be worse.
    @concurrent
    static func png(_ image: CGImage) async -> Data? {
        TestImageFactory.png(image)
    }
}
