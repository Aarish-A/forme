import CoreGraphics
import Foundation

/// A face's identity vector. L2-normalized, 128 dimensions for SFace.
///
/// Embeddings are biometric data: they live in memory for the length of a
/// scan and are never logged. Only the seed (the user's own reference
/// embeddings) is ever persisted, locally, and it's deletable in one tap.
nonisolated struct FaceEmbedding: Codable, Sendable, Equatable {
    var vector: [Float]

    /// Cosine similarity. Both vectors are L2-normalized, so the dot product
    /// is the cosine of the angle between them: 1 = same face pose-for-pose,
    /// 0 = unrelated, negative = actively dissimilar.
    func similarity(to other: FaceEmbedding) -> Float {
        zip(vector, other.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// One face found in an image, ready for matching.
nonisolated struct DetectedFace: Sendable, Equatable {
    /// Normalized (0–1, top-left origin) face box in the source image.
    var boundingBox: CGRect
    var embedding: FaceEmbedding
    /// Vision's holistic capture-quality score (0–1); nil when the quality
    /// request failed or wasn't run.
    var captureQuality: Float?
}

/// Size limits shared by the detector and the diagnostics that measure it.
nonisolated enum FaceIdentityLimits {
    /// Faces smaller than this (pixels, either side) carry too little signal
    /// for a usable embedding and are skipped.
    ///
    /// Raising the *image* resolution is the way to get past this; lowering the
    /// floor is not. A 24px face upscaled to the model's 112×112 input is a
    /// low-information vector, and low-information vectors against a cosine
    /// threshold produce confident matches on strangers — the same failure the
    /// floor exists to prevent, wearing a different hat.
    static let minimumFacePixels: CGFloat = 48
}

/// Every face found in an image, and how big they were.
///
/// The sizes matter separately from the faces. A photo where Vision saw three
/// faces and embedded none is a resolution problem; a photo where it saw none
/// is a framing problem. Returning only the survivors makes those two
/// indistinguishable, which is exactly how a 48px floor applied to a 512px
/// image stayed invisible while it silently disabled identity on every
/// full-length photo.
nonisolated struct FaceDetection: Sendable, Equatable {
    /// Faces large enough to embed, ready for matching.
    var faces: [DetectedFace] = []
    /// Shortest side in pixels of every face detected, including those too
    /// small to embed.
    var detectedSidesPx: [CGFloat] = []
    /// Why each detected face produced no embedding, in detection order.
    var rejections: [FaceRejection] = []

    static let none = FaceDetection()
}

/// Why a face Vision could see produced no usable embedding.
///
/// The embedding path is four guards deep and they used to collapse into one
/// silent `continue`, which turned "identity loses a fifth of its targets" into
/// a question nothing could answer. Five separate explanations were proposed and
/// disproved before anyone could see which guard was actually firing.
nonisolated enum FaceRejection: String, Error, Codable, Sendable, Equatable, CaseIterable {
    case tooSmall
    case noLandmarks
    case noAlignmentTransform
    case renderFailed
    case inferenceFailed
    case degenerateEmbedding
}

/// Detects faces and produces identity embeddings, entirely on-device.
nonisolated protocol FaceIdentityService: Sendable {
    /// False when the embedding model failed to load (missing artifact,
    /// Simulator issues). Callers skip identity entirely when false.
    var isAvailable: Bool { get }
    func detectFaces(in image: CGImage) async throws -> FaceDetection
}

extension FaceIdentityService {
    /// The usable faces alone, for callers that don't need the measurements.
    func faces(in image: CGImage) async throws -> [DetectedFace] {
        try await detectFaces(in: image).faces
    }
}

/// Decides whether a photo contains the seed's person.
nonisolated enum FaceMatcher {
    /// SFace's published cosine-similarity threshold (OpenCV).
    static let similarityThreshold: Float = 0.363

    static func isOwner(faces: [DetectedFace], seed: FaceSeed) -> Bool {
        bestMatch(faces: faces, seed: seed) != nil
    }

    /// The strongest similarity to the seed across `faces`, whatever the
    /// threshold thinks of it. Nil when there were no faces.
    ///
    /// Diagnostics need the raw score precisely when it *fails* the gate — the
    /// distribution of near-misses is what says whether 0.363 is the right
    /// number for real photos, and a bool can't say that.
    static func bestSimilarity(faces: [DetectedFace], seed: FaceSeed) -> Float? {
        faces
            .compactMap { face in seed.embeddings.map { face.embedding.similarity(to: $0) }.max() }
            .max()
    }

    /// Best face in `faces` matching the seed (for cutout focus). Nil if none.
    static func bestMatch(faces: [DetectedFace], seed: FaceSeed) -> DetectedFace? {
        var best: (face: DetectedFace, similarity: Float)?
        for face in faces {
            // A seed holds up to five reference embeddings (angles, lighting);
            // matching any one of them is enough, so score against the max.
            let similarity = seed.embeddings
                .map { face.embedding.similarity(to: $0) }
                .max() ?? -1
            guard similarity >= Self.similarityThreshold else { continue }
            if let current = best, current.similarity >= similarity {
                continue
            }
            best = (face, similarity)
        }
        return best?.face
    }
}

// MARK: - Stub implementation

/// A scripted face service. Defaults are inert — available but seeing no
/// faces — so existing scan tests and previews behave as if identity were
/// simply finding nothing; tests script the closure per axis.
nonisolated struct StubFaceIdentityService: FaceIdentityService {
    var isAvailable = true
    var facesResult: @Sendable (CGImage) -> [DetectedFace] = { _ in [] }
    /// Sizes of faces seen but *not* embedded. Empty by default, so a stub
    /// returning no faces reads as "nothing in frame" rather than "everything
    /// was too small" — tests that care about the high-resolution retry script
    /// this explicitly.
    var detectedSidesResult: @Sendable (CGImage) -> [CGFloat] = { _ in [] }

    func detectFaces(in image: CGImage) async throws -> FaceDetection {
        let faces = facesResult(image)
        return FaceDetection(
            faces: faces,
            detectedSidesPx: detectedSidesResult(image)
                + faces.map { min($0.boundingBox.width, $0.boundingBox.height) * CGFloat(image.width) }
        )
    }
}
