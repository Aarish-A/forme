import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import OSLog
import Vision

/// Vision + Core ML face identity: detect faces, align them to the ArcFace
/// template, and embed them with the bundled SFace model.
///
/// The model is loaded dynamically from the compiled `SFace.mlmodelc` in the
/// app bundle — no generated model class, so the app compiles and runs even
/// when the artifact is missing (identity simply reports unavailable).
/// Nothing about a face is ever logged.
///
/// A class rather than a struct because the lazily loaded `MLModel` is shared
/// state. `@unchecked Sendable` is justified: `state` is only touched under
/// `lock`, and `MLModel` prediction is documented thread-safe.
final nonisolated class VisionFaceIdentityService: FaceIdentityService, @unchecked Sendable {
    /// SFace's expected input is a 112×112 aligned face crop.
    private static let cropSide = 112

    /// The ArcFace 112×112 alignment template (top-left origin, pixels):
    /// left eye, right eye, nose tip, left mouth corner, right mouth corner.
    /// "Left" means image-left; detected landmarks are ordered to match.
    private static let template = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]

    private enum ModelState {
        case notLoaded
        case loaded(MLModel)
        case unavailable
    }

    private let modelURL: URL?
    private let lock = NSLock()
    private var state: ModelState = .notLoaded

    init(modelURL: URL? = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    /// Before the first scan this is a cheap artifact-presence check — the
    /// real `MLModel` load happens lazily on the first `faces(in:)` call, off
    /// the main actor. After a failed load it reports false.
    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .loaded: return true
        case .unavailable: return false
        case .notLoaded: return modelURL != nil
        }
    }

    /// `@concurrent` because face detection, alignment rendering, and Core ML
    /// inference are heavy and the callers are main-actor stores.
    @concurrent
    func detectFaces(in image: CGImage) async throws -> FaceDetection {
        guard let model = loadedModel() else { return .none }

        let rectangles = try await DetectFaceRectanglesRequest().perform(on: image)
        guard !rectangles.isEmpty else { return .none }

        var landmarksRequest = DetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = rectangles
        let observations = try await landmarksRequest.perform(on: image)

        // Capture quality only ranks faces for seed selection, so its failure
        // (routine on the Simulator) never vetoes detection.
        var qualityRequest = DetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = rectangles
        let scored = await (try? qualityRequest.perform(on: image)) ?? []

        let imageSize = CGSize(width: image.width, height: image.height)
        var faces: [DetectedFace] = []
        var detectedSides: [CGFloat] = []
        var rejections: [FaceRejection] = []
        for observation in observations {
            let pixelBox = observation.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
            let side = min(pixelBox.width, pixelBox.height)
            // Recorded before the floor rejects it: a face Vision could see but
            // we couldn't embed is the single most useful measurement here.
            detectedSides.append(side)
            guard side >= FaceIdentityLimits.minimumFacePixels else {
                rejections.append(.tooSmall)
                continue
            }
            // Each guard reports separately. Chained into one `else { continue }`
            // these are indistinguishable, and a fifth of all detected faces were
            // disappearing through them with nothing to say which.
            guard let points = Self.alignmentPoints(for: observation, imageSize: imageSize) else {
                rejections.append(.noLandmarks)
                continue
            }
            // Landmark alignment when the landmarks are real, a plain box crop
            // when they are not. Vision reports "landmarks unavailable" as a
            // fully-populated set of *coincident* points rather than as nil, so
            // the only way to tell is to measure their spread — and 136 of 232
            // rejected faces were exactly this, silently, because the degenerate
            // set flows through every non-nil check and only dies at the
            // zero-variance guard inside the transform.
            let transform = Self.similarityTransform(from: points, to: Self.template)
                ?? Self.boxTransform(for: pixelBox)
            let embedded = embed(image: image, transform: transform, model: model)
            guard case let .success(embedding) = embedded else {
                if case let .failure(reason) = embedded {
                    rejections.append(reason)
                }
                continue
            }

            let normalizedBox = CGRect(
                x: pixelBox.minX / imageSize.width,
                y: pixelBox.minY / imageSize.height,
                width: pixelBox.width / imageSize.width,
                height: pixelBox.height / imageSize.height
            )
            faces.append(DetectedFace(
                boundingBox: normalizedBox,
                embedding: embedding,
                captureQuality: Self.quality(for: observation, among: scored)
            ))
        }
        return FaceDetection(faces: faces, detectedSidesPx: detectedSides, rejections: rejections)
    }

    // MARK: - Model

    private func loadedModel() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case let .loaded(model):
            return model
        case .unavailable:
            return nil
        case .notLoaded:
            guard let modelURL, let model = try? MLModel(contentsOf: modelURL) else {
                state = .unavailable
                Log.feature.warning("Face embedding model failed to load — identity filtering disabled")
                return nil
            }
            state = .loaded(model)
            return model
        }
    }

    /// Returns the reason on failure rather than a bare nil: three quite
    /// different things happen in here — a Core Graphics render, a Core ML
    /// prediction, and a norm check — and they need telling apart.
    private func embed(
        image: CGImage,
        transform: CGAffineTransform,
        model: MLModel
    ) -> Result<FaceEmbedding, FaceRejection> {
        guard let buffer = Self.renderAlignedFace(from: image, transform: transform) else {
            return .failure(.renderFailed)
        }
        guard
            let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]
            ),
            let output = try? model.prediction(from: provider),
            let array = output.featureValue(for: "embedding")?.multiArrayValue
        else { return .failure(.inferenceFailed) }

        let raw = (0 ..< array.count).map { array[$0].floatValue }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > .ulpOfOne else { return .failure(.degenerateEmbedding) }
        return .success(FaceEmbedding(vector: raw.map { $0 / norm }))
    }

    /// Maps a face box onto the model's input square when landmarks are unusable.
    ///
    /// Cruder than landmark alignment: no roll correction, and the crop is only
    /// as well-centred as Vision's box. But an unrotated, correctly-scaled face
    /// still embeds far closer to its own identity than to anyone else's, and
    /// the alternative is discarding the face entirely — which is what was
    /// happening to 59% of every face this pipeline rejected.
    ///
    /// The 1.35 expansion approximates the ArcFace template's framing, where the
    /// eye line sits at 46% of the crop height and the mouth at 82%: Vision's box
    /// is tighter than that, so a bare box-to-square map would crop a face the
    /// model expects to see with margin.
    private static func boxTransform(for pixelBox: CGRect) -> CGAffineTransform {
        let side = CGFloat(cropSide)
        let source = max(pixelBox.width, pixelBox.height) * 1.35
        guard source > .ulpOfOne else { return .identity }
        let scale = side / source
        return CGAffineTransform(translationX: side / 2, y: side / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -pixelBox.midX, y: -pixelBox.midY)
    }

    // MARK: - Alignment

    /// The five alignment points in image pixels, top-left origin, ordered to
    /// match the template. Vision landmarks are normalized to the face box
    /// with a bottom-left origin — `pointsInImageCoordinates(_:origin:)` does
    /// that double conversion, which is the classic alignment bug when done
    /// by hand.
    private static func alignmentPoints(for observation: FaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let landmarks = observation.landmarks else { return nil }

        func points(of region: FaceObservation.Landmarks2D.Region?) -> [CGPoint] {
            region?.pointsInImageCoordinates(imageSize, origin: .upperLeft) ?? []
        }
        func mean(of region: FaceObservation.Landmarks2D.Region?) -> CGPoint? {
            let pts = points(of: region)
            guard !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }

        // Pupils when present, eye-outline centroids otherwise.
        guard
            let pupilA = mean(of: landmarks.leftPupil) ?? mean(of: landmarks.leftEye),
            let pupilB = mean(of: landmarks.rightPupil) ?? mean(of: landmarks.rightEye)
        else { return nil }

        // Nose tip: the lowest point of the crest (top-left origin, so max y);
        // the nose-outline centroid is the fallback.
        let crest = points(of: landmarks.noseCrest)
        guard let nose = crest.max(by: { $0.y < $1.y }) ?? mean(of: landmarks.nose) else { return nil }

        // Mouth corners: the extreme-x points of the outer lip outline.
        let lips = points(of: landmarks.outerLips)
        guard
            lips.count >= 2,
            let mouthLeft = lips.min(by: { $0.x < $1.x }),
            let mouthRight = lips.max(by: { $0.x < $1.x })
        else { return nil }

        // Order eyes by x so the mapping to the template never depends on
        // whether Vision's "left" means the subject's left or the image's.
        // Assumes a roughly upright face, which library photos are.
        let (eyeLeft, eyeRight) = pupilA.x <= pupilB.x ? (pupilA, pupilB) : (pupilB, pupilA)
        return [eyeLeft, eyeRight, nose, mouthLeft, mouthRight]
    }

    /// Least-squares similarity transform (Umeyama, 4 DOF: scale, rotation,
    /// translation) mapping `source` onto `target`, both top-left origin.
    /// Parametrized as x' = ax − by + tx, y' = bx + ay + ty, which is linear
    /// in (a, b, tx, ty) and so has a closed-form solution over the centered
    /// points. Nil when the points are degenerate (coincident or collinear
    /// enough that the scale collapses).
    private static func similarityTransform(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let count = CGFloat(source.count)
        let meanSource = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let meanTarget = target.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let sourceCenter = CGPoint(x: meanSource.x / count, y: meanSource.y / count)
        let targetCenter = CGPoint(x: meanTarget.x / count, y: meanTarget.y / count)

        var dotAligned: CGFloat = 0
        var dotRotated: CGFloat = 0
        var sourceVariance: CGFloat = 0
        for (point, image) in zip(source, target) {
            let srcX = point.x - sourceCenter.x
            let srcY = point.y - sourceCenter.y
            let dstX = image.x - targetCenter.x
            let dstY = image.y - targetCenter.y
            dotAligned += srcX * dstX + srcY * dstY
            dotRotated += srcX * dstY - srcY * dstX
            sourceVariance += srcX * srcX + srcY * srcY
        }
        guard sourceVariance > .ulpOfOne else { return nil }

        // The scaled cosine/sine of the rotation — the "a" and "b" of the
        // x' = ax − by + tx parametrization above.
        let cosScaled = dotAligned / sourceVariance
        let sinScaled = dotRotated / sourceVariance
        guard cosScaled * cosScaled + sinScaled * sinScaled > .ulpOfOne else { return nil }

        let shiftX = targetCenter.x - (cosScaled * sourceCenter.x - sinScaled * sourceCenter.y)
        let shiftY = targetCenter.y - (sinScaled * sourceCenter.x + cosScaled * sourceCenter.y)
        return CGAffineTransform(a: cosScaled, b: sinScaled, c: -sinScaled, d: cosScaled, tx: shiftX, ty: shiftY)
    }

    /// Renders the aligned 112×112 face crop straight into a BGRA pixel
    /// buffer for Core ML. `transform` maps source pixels to template pixels
    /// in top-left coordinates; Core Graphics draws bottom-left, so it is
    /// sandwiched between a source flip and a target flip.
    private static func renderAlignedFace(from image: CGImage, transform: CGAffineTransform) -> CVPixelBuffer? {
        let side = Self.cropSide
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            side,
            side,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let buffer = created else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }

        // Deterministic black outside the warped source, matching how SFace
        // crops are padded in OpenCV.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(image.height))
        let targetFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        context.interpolationQuality = .high
        context.concatenate(sourceFlip.concatenating(transform).concatenating(targetFlip))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    // MARK: - Capture quality

    /// The quality score for `observation`, matched by nearest face-box
    /// center — chained requests should preserve order, but that isn't
    /// documented, and a wrong pairing would silently rank seeds badly.
    private static func quality(for observation: FaceObservation, among scored: [FaceObservation]) -> Float? {
        let box = observation.boundingBox.cgRect
        let center = CGPoint(x: box.midX, y: box.midY)
        let nearest = scored.min { lhs, rhs in
            distance(from: center, toCenterOf: lhs) < distance(from: center, toCenterOf: rhs)
        }
        return nearest?.captureQuality?.score
    }

    private static func distance(from point: CGPoint, toCenterOf observation: FaceObservation) -> CGFloat {
        let box = observation.boundingBox.cgRect
        return hypot(box.midX - point.x, box.midY - point.y)
    }
}
