import Foundation

/// Everything the app needs to keep a wardrobe.
///
/// Views and stores depend on this protocol, never on the file system, so
/// previews and tests run against an in-memory wardrobe and moving storage
/// (device → cloud) never reaches a view.
nonisolated protocol WardrobeService: Sendable {
    /// Newest first.
    func loadPieces() async throws -> [Piece]

    @discardableResult
    func addPiece(
        imagePNG: Data,
        category: Piece.Category,
        sourceAssetID: String?,
        capturedAt: Date?
    ) async throws -> Piece

    func updatePiece(_ piece: Piece) async throws
    func removePiece(id: UUID) async throws
    /// Bulk removal. Unknown ids are ignored — cleanup must not fail because a
    /// piece was already gone.
    func removePieces(ids: Set<UUID>) async throws
    func imageData(for piece: Piece) async throws -> Data?
}

extension WardrobeService {
    /// Default bulk removal: one `removePiece` per id, swallowing "already
    /// gone". Implementations with a cheaper whole-index path override this.
    func removePieces(ids: Set<UUID>) async throws {
        for id in ids {
            do {
                try await removePiece(id: id)
            } catch WardrobeError.pieceNotFound {
                // Already gone is the outcome we wanted.
            }
        }
    }
}

/// Errors surfaced to the UI. Storage-specific failures are mapped into these
/// at the service boundary.
nonisolated enum WardrobeError: Error, Equatable {
    case pieceNotFound
    case storageFailed
}

extension [Piece] {
    /// The order every `WardrobeService` returns pieces in.
    ///
    /// The index tiebreak matters: a scan can add several pieces inside the
    /// same instant, and `sorted(by:)` isn't stable, so without it the grid
    /// would reshuffle between reloads.
    nonisolated func sortedNewestFirst() -> [Piece] {
        enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt == rhs.element.createdAt {
                    return lhs.offset > rhs.offset
                }
                return lhs.element.createdAt > rhs.element.createdAt
            }
            .map(\.element)
    }
}

// MARK: - In-memory implementation

/// A working wardrobe with nothing behind it, for previews and tests.
actor InMemoryWardrobeService: WardrobeService {
    private var pieces: [Piece]
    private var images: [UUID: Data]

    init(pieces: [(Piece, Data?)] = []) {
        self.pieces = pieces.map(\.0)
        var images: [UUID: Data] = [:]
        for (piece, data) in pieces {
            images[piece.id] = data
        }
        self.images = images
    }

    func loadPieces() async throws -> [Piece] {
        pieces.sortedNewestFirst()
    }

    @discardableResult
    func addPiece(
        imagePNG: Data,
        category: Piece.Category,
        sourceAssetID: String?,
        capturedAt: Date?
    ) async throws -> Piece {
        let id = UUID()
        let piece = Piece(
            id: id,
            category: category,
            imageFileName: "\(id.uuidString).png",
            sourceAssetID: sourceAssetID,
            createdAt: Date(),
            capturedAt: capturedAt
        )
        pieces.append(piece)
        images[id] = imagePNG
        return piece
    }

    func updatePiece(_ piece: Piece) async throws {
        guard let index = pieces.firstIndex(where: { $0.id == piece.id }) else {
            throw WardrobeError.pieceNotFound
        }
        pieces[index] = piece
    }

    func removePiece(id: UUID) async throws {
        guard let index = pieces.firstIndex(where: { $0.id == id }) else {
            throw WardrobeError.pieceNotFound
        }
        pieces.remove(at: index)
        images[id] = nil
    }

    func imageData(for piece: Piece) async throws -> Data? {
        images[piece.id]
    }

    /// Four pieces across categories with distinct solid-colour images, so the
    /// wardrobe grid previews with something in it.
    nonisolated static func previewSeeded() -> InMemoryWardrobeService {
        let categories: [Piece.Category] = [.top, .bottom, .outerwear, .shoes]
        let now = Date()

        let seeded: [(Piece, Data?)] = categories.enumerated().map { index, category in
            let id = UUID()
            let piece = Piece(
                id: id,
                category: category,
                imageFileName: "\(id.uuidString).png",
                sourceAssetID: nil,
                createdAt: now.addingTimeInterval(TimeInterval(-index * 3600))
            )
            return (piece, TestImageFactory.png(color: TestImageFactory.Color.palette(index)))
        }

        return InMemoryWardrobeService(pieces: seeded)
    }
}
