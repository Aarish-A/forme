import CoreGraphics
import Foundation
import ImageIO

/// Seed setup: turning the Selfies album, or a photo the user picks, into the
/// reference embeddings the scan matches against.
///
/// Split from the scan pipeline proper because it runs once, before a scan,
/// and answers a different question — "who is the user?" rather than "is this
/// photo worth keeping?". Keeping them in one type made that type the largest
/// in the project and hid the fact that they share almost nothing.
nonisolated extension ScanPipeline {
    /// Reads up to `selfieSeedLimit` Selfies-album photos, embeds every face,
    /// and proposes the dominant one: the face that matches the most other
    /// faces (greedy count), shown via its best-quality crop. Best-effort at
    /// every step — an empty proposal just means the UI offers pick-a-photo.
    @concurrent
    static func proposeSeed(
        photoLibrary: any PhotoLibraryService,
        faceIdentity: any FaceIdentityService
    ) async -> SeedProposal {
        let none = SeedProposal(faceCrop: nil, embeddings: [])
        guard faceIdentity.isAvailable else { return none }

        let selfies = await photoLibrary.selfieAssets(limit: selfieSeedLimit)
        var entries: [(face: DetectedFace, source: CGImage)] = []
        for asset in selfies {
            guard !Task.isCancelled else { return none }
            guard
                let image = try? await photoLibrary.loadImage(
                    assetID: asset.id,
                    maxPixelSize: analysisPixelSize
                ) else { continue }
            for face in await (try? faceIdentity.faces(in: image)) ?? [] {
                entries.append((face: face, source: image))
            }
        }

        guard let dominantIndex = dominantFaceIndex(in: entries) else { return none }
        let dominant = entries[dominantIndex].face.embedding
        var cluster = entries.filter {
            $0.face.embedding.similarity(to: dominant) >= FaceMatcher.similarityThreshold
        }
        cluster.sort { ($0.face.captureQuality ?? -1) > ($1.face.captureQuality ?? -1) }
        guard let best = cluster.first else { return none }

        return SeedProposal(
            faceCrop: faceCrop(from: best.source, box: best.face.boundingBox),
            embeddings: cluster.prefix(seedEmbeddingLimit).map(\.face.embedding)
        )
    }

    /// The seed for a user-picked photo: its largest face's embedding.
    @concurrent
    static func seedEmbedding(fromPhoto data: Data, faceIdentity: any FaceIdentityService) async -> FaceEmbedding? {
        guard
            faceIdentity.isAvailable,
            let image = decodeImage(data, maxPixelSize: analysisPixelSize)
        else { return nil }

        let faces = await (try? faceIdentity.faces(in: image)) ?? []
        let largest = faces.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        return largest?.embedding
    }

    /// Index of the face with the most greedy matches across all entries.
    private static func dominantFaceIndex(in entries: [(face: DetectedFace, source: CGImage)]) -> Int? {
        guard !entries.isEmpty else { return nil }
        var bestIndex = 0
        var bestCount = -1
        for candidateIndex in entries.indices {
            let embedding = entries[candidateIndex].face.embedding
            let count = entries.indices.count { otherIndex in
                otherIndex != candidateIndex
                    && embedding.similarity(to: entries[otherIndex].face.embedding)
                    >= FaceMatcher.similarityThreshold
            }
            if count > bestCount {
                bestCount = count
                bestIndex = candidateIndex
            }
        }
        return bestIndex
    }

    /// A padded pixel crop of a normalized (top-left origin) face box.
    private static func faceCrop(from image: CGImage, box: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let padded = box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3)
        let pixels = CGRect(
            x: padded.origin.x * width,
            y: padded.origin.y * height,
            width: padded.width * width,
            height: padded.height * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }
}
