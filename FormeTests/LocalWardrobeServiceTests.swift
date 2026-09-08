import Foundation
import Testing
@testable import Forme

@Suite("Local wardrobe service")
struct LocalWardrobeServiceTests {
    /// A fresh directory per test, torn down by the caller's `defer`.
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wardrobe-tests-\(UUID().uuidString)")
    }

    private func samplePNG(_ index: Int = 0) throws -> Data {
        try #require(TestImageFactory.png(color: TestImageFactory.Color.palette(index), size: 8))
    }

    private func imageURL(in directory: URL, for piece: Piece) -> URL {
        directory.appending(path: "images").appending(path: piece.imageFileName)
    }

    @Test("Added pieces come back newest first")
    func addAndLoadNewestFirst() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)

        let first = try await service.addPiece(
            imagePNG: samplePNG(0),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )
        let second = try await service.addPiece(
            imagePNG: samplePNG(1),
            category: .shoes,
            sourceAssetID: "ASSET-2",
            capturedAt: nil
        )

        let pieces = try await service.loadPieces()

        #expect(pieces.map(\.id) == [second.id, first.id])
        #expect(pieces.first?.category == .shoes)
        #expect(pieces.first?.sourceAssetID == "ASSET-2")
    }

    @Test("An image round trips through disk")
    func imageDataRoundTrips() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let png = try samplePNG()

        let piece = try await service.addPiece(imagePNG: png, category: .top, sourceAssetID: nil, capturedAt: nil)

        #expect(try await service.imageData(for: piece) == png)
    }

    @Test("Updating a piece persists the change")
    func updatePersists() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        var piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .other,
            sourceAssetID: nil,
            capturedAt: nil
        )

        piece.category = .outerwear
        try await service.updatePiece(piece)

        let reloaded = try #require(try await service.loadPieces().first)
        #expect(reloaded.category == .outerwear)
        #expect(reloaded.id == piece.id)
    }

    @Test("Updating a piece that isn't there reports it rather than inventing one")
    func updateMissingPieceThrows() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let ghost = Piece(
            id: UUID(),
            category: .top,
            imageFileName: "missing.png",
            sourceAssetID: nil,
            createdAt: Date()
        )

        await #expect(throws: WardrobeError.pieceNotFound) {
            try await service.updatePiece(ghost)
        }
    }

    @Test("Removing a piece deletes its image file too")
    func removeDeletesImageFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )
        let url = imageURL(in: directory, for: piece)
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await service.removePiece(id: piece.id)

        #expect(try await service.loadPieces().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A missing image file reads as no image, not a failure")
    func missingImageReadsAsNil() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try FileManager.default.removeItem(at: imageURL(in: directory, for: piece))

        #expect(try await service.imageData(for: piece) == nil)
    }

    @Test("A corrupt index starts an empty wardrobe instead of throwing")
    func corruptIndexRecoversToEmpty() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        try await service.addPiece(imagePNG: samplePNG(), category: .top, sourceAssetID: nil, capturedAt: nil)

        try Data("not json".utf8).write(to: directory.appending(path: "index.json"))

        #expect(try await service.loadPieces().isEmpty)
    }

    @Test("capturedAt is stored and read back")
    func capturedAtPersists() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let taken = Date(timeIntervalSince1970: 1_650_000_000)

        try await service.addPiece(
            imagePNG: samplePNG(),
            category: .dress,
            sourceAssetID: "ASSET-4",
            capturedAt: taken
        )

        let reloaded = try #require(try await LocalWardrobeService(directory: directory).loadPieces().first)
        #expect(reloaded.capturedAt == taken)
    }

    @Test("Bulk removal takes several pieces out in one go, files included")
    func removePiecesRemovesAllRequested() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let doomed1 = try await service.addPiece(
            imagePNG: samplePNG(0),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )
        let doomed2 = try await service.addPiece(
            imagePNG: samplePNG(1),
            category: .shoes,
            sourceAssetID: nil,
            capturedAt: nil
        )
        let survivor = try await service.addPiece(
            imagePNG: samplePNG(2),
            category: .dress,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try await service.removePieces(ids: [doomed1.id, doomed2.id])

        let remaining = try await service.loadPieces()
        #expect(remaining.map(\.id) == [survivor.id])
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, for: doomed1).path))
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, for: doomed2).path))
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, for: survivor).path))
    }

    @Test("Bulk removal ignores ids that are already gone")
    func removePiecesIgnoresUnknownIDs() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try await service.removePieces(ids: [piece.id, UUID(), UUID()])

        #expect(try await service.loadPieces().isEmpty)
    }

    @Test("Bulk removal of nothing but unknown ids is a no-op, not a failure")
    func removePiecesAllUnknownSucceeds() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalWardrobeService(directory: directory)
        let piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try await service.removePieces(ids: [UUID()])
        try await service.removePieces(ids: [])

        #expect(try await service.loadPieces().map(\.id) == [piece.id])
    }

    @Test("A second instance over the same directory sees what was saved")
    func persistsAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LocalWardrobeService(directory: directory)
        let png = try samplePNG()
        let piece = try await first.addPiece(
            imagePNG: png,
            category: .dress,
            sourceAssetID: "ASSET-9",
            capturedAt: nil
        )

        let second = LocalWardrobeService(directory: directory)
        let pieces = try await second.loadPieces()

        #expect(pieces.map(\.id) == [piece.id])
        #expect(pieces.first?.category == .dress)
        #expect(pieces.first?.sourceAssetID == "ASSET-9")
        #expect(try await second.imageData(for: piece) == png)
    }
}

/// The protocol-extension default for `removePieces`, exercised through the
/// in-memory service — the one implementation that doesn't override it.
@Suite("WardrobeService bulk-removal default")
struct WardrobeServiceRemovePiecesDefaultTests {
    private func samplePNG() throws -> Data {
        try #require(TestImageFactory.png(color: .blue, size: 8))
    }

    @Test("Removes every requested piece")
    func removesRequestedPieces() async throws {
        let service = InMemoryWardrobeService()
        let doomed = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )
        let survivor = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .shoes,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try await service.removePieces(ids: [doomed.id])

        #expect(try await service.loadPieces().map(\.id) == [survivor.id])
    }

    @Test("Swallows pieceNotFound so cleanup never fails on an already-gone piece")
    func ignoresUnknownIDs() async throws {
        let service = InMemoryWardrobeService()
        let piece = try await service.addPiece(
            imagePNG: samplePNG(),
            category: .top,
            sourceAssetID: nil,
            capturedAt: nil
        )

        try await service.removePieces(ids: [piece.id, UUID()])

        #expect(try await service.loadPieces().isEmpty)
    }
}
