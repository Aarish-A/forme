import CoreGraphics
import Foundation
import Testing
@testable import Forme

@Suite("Face identity")
struct FaceIdentityTests {
    /// Embeddings don't need 128 dimensions for the math under test — short
    /// unit vectors make the expected similarities readable.
    private func face(_ vector: [Float], quality: Float? = nil) -> DetectedFace {
        DetectedFace(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            embedding: FaceEmbedding(vector: vector),
            captureQuality: quality
        )
    }

    private func seed(_ vectors: [Float]...) -> FaceSeed {
        FaceSeed(embeddings: vectors.map { FaceEmbedding(vector: $0) }, createdAt: Date())
    }

    // MARK: - FaceEmbedding.similarity

    @Test("Identical unit vectors are perfectly similar")
    func similarityOfIdenticalVectors() {
        let embedding = FaceEmbedding(vector: [0.6, 0.8])
        #expect(abs(embedding.similarity(to: embedding) - 1) < 0.0001)
    }

    @Test("Orthogonal vectors have zero similarity")
    func similarityOfOrthogonalVectors() {
        let one = FaceEmbedding(vector: [1, 0])
        let other = FaceEmbedding(vector: [0, 1])
        #expect(abs(one.similarity(to: other)) < 0.0001)
    }

    @Test("Opposite vectors are maximally dissimilar")
    func similarityOfOppositeVectors() {
        let one = FaceEmbedding(vector: [1, 0])
        let other = FaceEmbedding(vector: [-1, 0])
        #expect(abs(one.similarity(to: other) + 1) < 0.0001)
    }

    // MARK: - FaceMatcher

    @Test("A face above the threshold makes the photo the owner's")
    func ownerAboveThreshold() {
        // Similarity to the seed is exactly 0.5 — comfortably above 0.363.
        let owner = seed([1, 0])
        #expect(FaceMatcher.isOwner(faces: [face([0.5, 0.866])], seed: owner))
    }

    @Test("A face below the threshold does not match")
    func notOwnerBelowThreshold() {
        // Similarity 0.2 — below 0.363.
        let owner = seed([1, 0])
        #expect(!FaceMatcher.isOwner(faces: [face([0.2, 0.98])], seed: owner))
    }

    @Test("A similarity exactly at the threshold counts as a match")
    func ownerAtThresholdBoundary() {
        let owner = seed([1, 0])
        let boundary = face([FaceMatcher.similarityThreshold, 0.9])
        #expect(FaceMatcher.isOwner(faces: [boundary], seed: owner))
    }

    @Test("No faces means no owner")
    func noFacesIsNotOwner() {
        #expect(!FaceMatcher.isOwner(faces: [], seed: seed([1, 0])))
        #expect(FaceMatcher.bestMatch(faces: [], seed: seed([1, 0])) == nil)
    }

    @Test("Matching any one of several seed embeddings is enough")
    func anySeedEmbeddingMatches() {
        // The face is orthogonal to the first seed embedding but identical to
        // the second — multiple references exist exactly for this.
        let owner = seed([1, 0], [0, 1])
        #expect(FaceMatcher.isOwner(faces: [face([0, 1])], seed: owner))
    }

    @Test("Best match picks the most similar face, not the first")
    func bestMatchPicksHighestSimilarity() {
        let owner = seed([1, 0])
        let close = face([0.9, 0.436], quality: 0.2)
        let closer = face([0.99, 0.141], quality: 0.9)
        let stranger = face([-1, 0])

        let best = FaceMatcher.bestMatch(faces: [stranger, close, closer], seed: owner)

        #expect(best == closer)
    }

    @Test("Best match is nil when every face is below the threshold")
    func bestMatchNilWhenAllBelowThreshold() {
        let owner = seed([1, 0])
        #expect(FaceMatcher.bestMatch(faces: [face([0.1, 0.995]), face([0, 1])], seed: owner) == nil)
    }

    // MARK: - Seed persistence

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "face-seed-tests-\(UUID().uuidString)")
    }

    @Test("A saved seed round trips through disk")
    func localSeedRoundTrips() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalFaceSeedService(directory: directory)
        let stored = seed([0.6, 0.8], [0, 1])

        await service.save(stored)

        #expect(await service.load() == stored)
    }

    @Test("A fresh directory has no seed")
    func localSeedStartsEmpty() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalFaceSeedService(directory: directory)

        #expect(await service.load() == nil)
    }

    @Test("A second instance over the same directory sees the saved seed")
    func localSeedPersistsAcrossInstances() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = seed([1, 0])
        await LocalFaceSeedService(directory: directory).save(stored)

        #expect(await LocalFaceSeedService(directory: directory).load() == stored)
    }

    @Test("Clearing deletes the seed file")
    func localSeedClearDeletesFile() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalFaceSeedService(directory: directory)
        await service.save(seed([1, 0]))

        await service.clear()

        #expect(await service.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "FaceSeed.json").path))
    }

    @Test("The in-memory service round trips and clears")
    func inMemorySeedRoundTrips() async {
        let stored = seed([1, 0])
        let service = InMemoryFaceSeedService()
        #expect(await service.load() == nil)

        await service.save(stored)
        #expect(await service.load() == stored)

        await service.clear()
        #expect(await service.load() == nil)
    }

    @Test("A seeded in-memory service starts with its seed")
    func inMemorySeedInitialValue() async {
        let stored = seed([0, 1])
        #expect(await InMemoryFaceSeedService(seed: stored).load() == stored)
    }

    // MARK: - Stub

    @Test("The stub defaults are inert: available, seeing no faces")
    func stubDefaultsAreInert() async throws {
        let stub = StubFaceIdentityService()
        #expect(stub.isAvailable)

        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try #require(context?.makeImage())
        #expect(try await stub.faces(in: image).isEmpty)
    }
}
