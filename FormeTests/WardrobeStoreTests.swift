import Foundation
import Testing
@testable import Forme

@Suite("Wardrobe store")
struct WardrobeStoreTests {
    private func png(_ index: Int = 0) throws -> Data {
        try #require(TestImageFactory.png(color: TestImageFactory.Color.palette(index), size: 8))
    }

    private func makeStore(
        wardrobe: any WardrobeService = InMemoryWardrobeService(),
        detector: any GarmentDetector = StubGarmentDetector()
    ) -> WardrobeStore {
        WardrobeStore(wardrobe: wardrobe, detector: detector)
    }

    @Test("Refreshing loads the wardrobe newest first, with its images decoded")
    func refreshLoadsPiecesAndImages() async throws {
        let store = makeStore(wardrobe: InMemoryWardrobeService.previewSeeded())

        await store.refresh()

        #expect(store.pieces.count == 4)
        #expect(store.images.count == 4)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)

        let created = store.pieces.map(\.createdAt)
        #expect(created == created.sorted(by: >))

        let newest = try #require(store.pieces.first)
        #expect(store.images[newest.id] != nil)
    }

    @Test("An empty wardrobe loads without complaining")
    func refreshWithNothingStored() async {
        let store = makeStore()

        await store.refresh()

        #expect(store.pieces.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test("Picked photos become pieces")
    func addFromPickedImagesCreatesPieces() async throws {
        let store = makeStore()
        let picked = try [png(0), png(1)]

        await store.addFromPickedImages(picked)

        #expect(store.pieces.count == 2)
        #expect(store.images.count == 2)
        #expect(store.errorMessage == nil)
    }

    @Test("A photo with no liftable subject still becomes a piece")
    func addFallsBackToTheOriginalWhenThereIsNoCutout() async throws {
        let store = makeStore(detector: StubGarmentDetector(cutoutResult: { _, _ in nil }))
        let picked = try [png()]

        await store.addFromPickedImages(picked)

        let piece = try #require(store.pieces.first)
        #expect(store.images[piece.id] != nil)
        #expect(store.errorMessage == nil)
    }

    @Test("The classifier's labels choose the category")
    func addUsesTheSuggestedCategory() async throws {
        let detector = StubGarmentDetector(
            analyzeResult: { _ in GarmentObservation(isClothingCandidate: true, confidence: 0.9, labels: ["sneaker"]) }
        )
        let store = makeStore(detector: detector)
        let picked = try [png()]

        await store.addFromPickedImages(picked)

        #expect(store.pieces.first?.category == .shoes)
    }

    @Test("A photo the detector doesn't call clothing lands in Other rather than being guessed at")
    func addFallsBackToOtherWhenNotAGarment() async throws {
        let detector = StubGarmentDetector(
            analyzeResult: { _ in GarmentObservation(isClothingCandidate: false, confidence: 0.1, labels: ["sneaker"]) }
        )
        let store = makeStore(detector: detector)
        let picked = try [png()]

        await store.addFromPickedImages(picked)

        #expect(store.pieces.first?.category == .other)
    }

    @Test("Data that isn't an image is reported, not silently dropped")
    func addReportsUnreadablePhotos() async throws {
        let store = makeStore()
        let picked = try [Data("not a photo".utf8), png()]

        await store.addFromPickedImages(picked)

        #expect(store.pieces.count == 1)
        #expect(store.errorMessage != nil)
    }

    @Test("Correcting a category updates the grid and the wardrobe behind it")
    func updateCategoryPersists() async throws {
        let wardrobe = InMemoryWardrobeService()
        let store = makeStore(wardrobe: wardrobe)
        try await store.addFromPickedImages([png()])
        let piece = try #require(store.pieces.first)

        await store.updateCategory(.dress, for: piece)

        #expect(store.pieces.first?.category == .dress)
        #expect(try await wardrobe.loadPieces().first?.category == .dress)
        #expect(store.errorMessage == nil)
    }

    @Test("Correcting twice reads the current category, not the one the sheet opened with")
    func updateCategoryIgnoresAStalePiece() async throws {
        let store = makeStore()
        try await store.addFromPickedImages([png()])
        let opened = try #require(store.pieces.first)

        await store.updateCategory(.dress, for: opened)
        await store.updateCategory(opened.category, for: opened)

        #expect(store.pieces.first?.category == opened.category)
    }

    @Test("Removing a piece drops it and its image")
    func removeDropsThePieceAndItsImage() async throws {
        let wardrobe = InMemoryWardrobeService()
        let store = makeStore(wardrobe: wardrobe)
        try await store.addFromPickedImages([png()])
        let piece = try #require(store.pieces.first)

        await store.remove(piece)

        #expect(store.pieces.isEmpty)
        #expect(store.images[piece.id] == nil)
        #expect(try await wardrobe.loadPieces().isEmpty)
    }

    @Test("Removing a selection drops every chosen piece and its image, and keeps the rest")
    func removeIDsDropsTheSelection() async throws {
        let wardrobe = InMemoryWardrobeService()
        let store = makeStore(wardrobe: wardrobe)
        try await store.addFromPickedImages([png(0), png(1), png(2)])
        let removed = Set(store.pieces.prefix(2).map(\.id))
        let kept = try #require(store.pieces.last)

        await store.remove(ids: removed)

        #expect(store.pieces.map(\.id) == [kept.id])
        #expect(removed.allSatisfy { store.images[$0] == nil })
        #expect(store.images[kept.id] != nil)
        #expect(store.errorMessage == nil)
        #expect(try await wardrobe.loadPieces().count == 1)
    }

    @Test("A piece that's already gone doesn't sink the rest of the removal")
    func removeIDsIgnoresUnknownIDs() async throws {
        let store = makeStore()
        try await store.addFromPickedImages([png()])
        let piece = try #require(store.pieces.first)

        await store.remove(ids: [piece.id, UUID()])

        #expect(store.pieces.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test("Removing nothing leaves the wardrobe alone")
    func removeIDsWithAnEmptySelectionIsANoOp() async {
        let store = makeStore(wardrobe: InMemoryWardrobeService.previewSeeded())
        await store.refresh()

        await store.remove(ids: [])

        #expect(store.pieces.count == 4)
        #expect(store.errorMessage == nil)
    }

    @Test("A bulk removal that fails keeps the pieces and says so")
    func removeIDsFailureSurfacesAMessage() async throws {
        let store = makeStore(wardrobe: UndeletableWardrobeService())
        try await store.addFromPickedImages([png(0), png(1)])
        let ids = Set(store.pieces.map(\.id))

        await store.remove(ids: ids)

        #expect(store.pieces.count == 2)
        #expect(store.images.count == 2)
        #expect(store.errorMessage != nil)
    }

    @Test("A wardrobe that can't be read surfaces a message instead of throwing")
    func loadFailureSurfacesAMessage() async {
        let store = makeStore(wardrobe: FailingWardrobeService())

        await store.refresh()

        #expect(store.pieces.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(!store.isLoading)
    }

    @Test("A wardrobe that can't be written surfaces a message instead of throwing")
    func addFailureSurfacesAMessage() async throws {
        let store = makeStore(wardrobe: FailingWardrobeService())

        try await store.addFromPickedImages([png()])

        #expect(store.pieces.isEmpty)
        #expect(store.errorMessage != nil)
    }
}

/// A wardrobe where every operation fails, for the paths the in-memory one is
/// too well behaved to reach.
private nonisolated struct FailingWardrobeService: WardrobeService {
    func loadPieces() async throws -> [Piece] {
        throw WardrobeError.storageFailed
    }

    func addPiece(
        imagePNG _: Data,
        category _: Piece.Category,
        sourceAssetID _: String?,
        capturedAt _: Date?
    ) async throws -> Piece {
        throw WardrobeError.storageFailed
    }

    func updatePiece(_: Piece) async throws {
        throw WardrobeError.storageFailed
    }

    func removePiece(id _: UUID) async throws {
        throw WardrobeError.storageFailed
    }

    func imageData(for _: Piece) async throws -> Data? {
        throw WardrobeError.storageFailed
    }
}

/// A wardrobe that stores happily and refuses to delete, so the bulk-removal
/// failure path can be reached with real pieces in the grid.
private nonisolated struct UndeletableWardrobeService: WardrobeService {
    private let backing = InMemoryWardrobeService()

    func loadPieces() async throws -> [Piece] {
        try await backing.loadPieces()
    }

    @discardableResult
    func addPiece(
        imagePNG: Data,
        category: Piece.Category,
        sourceAssetID: String?,
        capturedAt: Date?
    ) async throws -> Piece {
        try await backing.addPiece(
            imagePNG: imagePNG,
            category: category,
            sourceAssetID: sourceAssetID,
            capturedAt: capturedAt
        )
    }

    func updatePiece(_ piece: Piece) async throws {
        try await backing.updatePiece(piece)
    }

    func removePiece(id _: UUID) async throws {
        throw WardrobeError.storageFailed
    }

    func imageData(for piece: Piece) async throws -> Data? {
        try await backing.imageData(for: piece)
    }
}
