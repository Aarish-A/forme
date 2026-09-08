import Foundation
import OSLog

/// The wardrobe as it lives on this device: a JSON index plus one PNG per
/// piece, under Application Support.
///
/// Nothing here leaves the phone. The index is small (a few hundred bytes per
/// piece) so it's rewritten whole on every change — simpler than a database,
/// and fast enough for a wardrobe someone could plausibly own.
actor LocalWardrobeService: WardrobeService {
    private let directory: URL
    private let indexURL: URL
    private let imagesDirectory: URL

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Defaults to Application Support; tests pass a temporary directory.
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Wardrobe")) {
        self.directory = directory
        self.indexURL = directory.appending(path: "index.json")
        self.imagesDirectory = directory.appending(path: "images")
    }

    func loadPieces() async throws -> [Piece] {
        loadIndex().sortedNewestFirst()
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

        try createDirectoriesIfNeeded()
        do {
            try imagePNG.write(to: imageURL(for: piece), options: .atomic)
        } catch {
            Log.app.error("Wardrobe image write failed")
            throw WardrobeError.storageFailed
        }

        var pieces = loadIndex()
        pieces.append(piece)
        try writeIndex(pieces)
        return piece
    }

    func updatePiece(_ piece: Piece) async throws {
        var pieces = loadIndex()
        guard let index = pieces.firstIndex(where: { $0.id == piece.id }) else {
            throw WardrobeError.pieceNotFound
        }
        pieces[index] = piece
        try writeIndex(pieces)
    }

    func removePiece(id: UUID) async throws {
        var pieces = loadIndex()
        guard let index = pieces.firstIndex(where: { $0.id == id }) else {
            throw WardrobeError.pieceNotFound
        }
        let piece = pieces.remove(at: index)
        try writeIndex(pieces)
        // Index first, image second: a leftover file is invisible, a leftover
        // index entry is a broken tile.
        try? FileManager.default.removeItem(at: imageURL(for: piece))
    }

    /// One index rewrite however many pieces go, instead of the default's
    /// rewrite-per-piece. Unknown ids are ignored; file deletes are
    /// best-effort, after the index, for the same reason as `removePiece`.
    func removePieces(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        let pieces = loadIndex()
        let removed = pieces.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }

        try writeIndex(pieces.filter { !ids.contains($0.id) })
        for piece in removed {
            try? FileManager.default.removeItem(at: imageURL(for: piece))
        }
    }

    func imageData(for piece: Piece) async throws -> Data? {
        try? Data(contentsOf: imageURL(for: piece))
    }

    // MARK: - Storage

    private func imageURL(for piece: Piece) -> URL {
        imagesDirectory.appending(path: piece.imageFileName)
    }

    /// A missing or unreadable index means an empty wardrobe, never a crash:
    /// losing the index is bad, but taking the app down with it is worse.
    private func loadIndex() -> [Piece] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            return try decoder.decode([Piece].self, from: data)
        } catch {
            Log.app.error("Wardrobe index unreadable — starting from an empty wardrobe")
            return []
        }
    }

    private func writeIndex(_ pieces: [Piece]) throws {
        do {
            try createDirectoriesIfNeeded()
            try encoder.encode(pieces).write(to: indexURL, options: .atomic)
        } catch {
            Log.app.error("Wardrobe index write failed")
            throw WardrobeError.storageFailed
        }
    }

    private func createDirectoriesIfNeeded() throws {
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            Log.app.error("Wardrobe directory could not be created")
            throw WardrobeError.storageFailed
        }
    }
}
