import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Vision-backed image understanding for the scan and manual-add flows.
///
/// Built on the modern struct-request Vision API (`try await
/// request.perform(on:)`). Requests routinely fail on the Simulator, so errors
/// propagate rather than crash — every caller already degrades by skipping the
/// asset or falling back to the original image. Nothing here is logged:
/// classification labels describe what someone wears.
nonisolated struct VisionGarmentDetector: GarmentDetector {
    /// Vision classification identifiers that mean "this photo prominently
    /// shows clothing". Matched case-insensitively against the taxonomy's
    /// lowercase identifiers.
    /// Not private so a test can check these against Vision's actual taxonomy.
    /// They are hand-written strings matched against an identifier list we don't
    /// control, which is a category of bug no amount of code review catches.
    static let clothingLabels: Set = [
        "garment", "clothing", "apparel", "outfit",
        "dress", "dresses", "gown", "gowns", "sundress", "wedding_dress", "evening_dress", "jumpsuit",
        "jacket", "jackets", "blazer", "coat", "coats", "overcoat", "trench_coat", "raincoat",
        "parka", "cloak", "cape", "poncho",
        "jeans", "denim", "pants", "trousers", "leggings", "shorts", "skirt", "skirts", "kilt", "sarong",
        "blouse", "hoodie", "sweatshirt", "sweater", "jumper", "cardigan", "vest", "suit", "tuxedo",
        "shirt", "shirts", "tshirt", "t-shirt", "t_shirt", "polo", "tank_top", "swimsuit", "bikini",
        "shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "sandal", "sandals",
        "high_heel", "high_heels", "footwear", "moccasin", "loafer", "slipper",
        "hat", "hats", "cap", "beanie", "scarf", "necktie", "tie", "bow_tie"
    ]

    /// Below this a clothing label is noise rather than a near miss, and the
    /// photo is dismissed without spending the aesthetics and person requests
    /// on it.
    ///
    /// Deliberately far below ``ScanPolicy/minClothingConfidence`` so the policy
    /// stays the only real gate: everything in the range where the threshold
    /// actually discriminates reaches it, and reaches the diagnostics, so its
    /// near-misses are measurable instead of invisible.
    private static let labelNoiseFloor: Float = 0.1

    /// Confidence a label needs before it's allowed to suggest a category.
    /// Independent of the policy floor because it answers a different question —
    /// "which garment is this?" rather than "is this a garment photo?" — and a
    /// wrong suggestion the user has to correct is worse than none.
    private static let categoryLabelFloor: Float = 0.4

    /// Confidence a pose joint needs before it counts as visible. Vision reports
    /// occluded and inferred joints with low confidence rather than omitting
    /// them, so without a floor every pose looks complete.
    private static let jointConfidenceFloor: Float = 0.3

    /// Both methods are `@concurrent`: under `NonisolatedNonsendingByDefault`
    /// a plain `nonisolated` async method runs on its caller's actor, and the
    /// callers here are main-actor stores. The synchronous halves — mask
    /// rendering, the CoreImage render, filtering — are real CPU work that
    /// must never land on the main thread, whoever calls in.
    @concurrent
    func analyze(_ image: CGImage) async throws -> GarmentObservation {
        // Person detection runs FIRST and unconditionally. It used to sit behind
        // an early return from classification, so a photo whose garments Vision
        // has no word for — most of a real wardrobe — was never even checked for
        // whether somebody was in it. That coupling put 1,602 of 2,500 photos
        // beyond reach of every gate downstream of it.
        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let people = await (try? humans.perform(on: image)) ?? []

        // Pose is what replaced clothing classification as the outfit signal.
        // Best-effort like the rest: no pose reads as "no torso visible", which
        // is the conservative answer.
        let poses = await (try? DetectHumanBodyPoseRequest().perform(on: image)) ?? []

        // Screenshots, receipts and catalogue pages.
        let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image)

        // Labels are now a category hint, never a gate — so a classification
        // failure costs a suggestion, not the photo.
        let observations = await (try? ClassifyImageRequest().perform(on: image)) ?? []
        let matches = observations.filter { observation in
            observation.confidence >= Self.labelNoiseFloor
                && Self.clothingLabels.contains(observation.identifier.lowercased())
        }

        return GarmentObservation(
            isClothingCandidate: !matches.isEmpty,
            confidence: matches.map(\.confidence).max() ?? 0,
            labels: matches
                .filter { $0.confidence >= Self.categoryLabelFloor }
                .map(\.identifier),
            // Vision boxes are bottom-left normalized; everything downstream
            // (focus points, ScanPolicy docs) speaks top-left.
            people: people.map { $0.boundingBox.verticallyFlipped().cgRect },
            aestheticsScore: aesthetics?.overallScore,
            isUtility: aesthetics?.isUtility == true,
            framing: Self.framing(from: poses)
        )
    }

    /// The most complete body in frame, as joint groups.
    ///
    /// Takes the best pose rather than merging: one person fully in shot is what
    /// makes a photo catalogueable, and averaging them with a half-cropped
    /// bystander would lose exactly that.
    private static func framing(from poses: [HumanBodyPoseObservation]) -> BodyFraming {
        var best = BodyFraming.none
        for pose in poses {
            let joints = pose.allJoints()
            func has(_ names: [HumanBodyPoseObservation.PoseJointName]) -> Bool {
                names.contains { (joints[$0]?.confidence ?? 0) >= Self.jointConfidenceFloor }
            }
            let framing = BodyFraming(
                hasShoulders: has([.leftShoulder, .rightShoulder]),
                hasHips: has([.leftHip, .rightHip]),
                hasKnees: has([.leftKnee, .rightKnee])
            )
            if framing.showsTorso, !best.showsTorso {
                best = framing
            } else if framing.showsTorso, framing.hasKnees {
                best = framing
            } else if !best.showsTorso, framing.hasShoulders {
                best = framing
            }
        }
        return best
    }

    /// Best-effort by contract: a nil fingerprint means "can't group this
    /// photo", which the scan treats as its own group.
    @concurrent
    func fingerprint(_ image: CGImage) async throws -> ImageFingerprint? {
        guard let observation = try? await GenerateImageFeaturePrintRequest().perform(on: image) else {
            return nil
        }
        let vector: [Float]
        switch observation.elementType {
        case .float:
            vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            vector = observation.data.withUnsafeBytes { buffer in
                buffer.bindMemory(to: Double.self).map(Float.init)
            }
        @unknown default:
            return nil
        }
        guard vector.count == observation.elementCount, !vector.isEmpty else { return nil }
        return ImageFingerprint(vector: vector)
    }

    @concurrent
    func cutout(from image: CGImage, focus: CGPoint?) async throws -> CGImage? {
        guard
            let observation = try await GenerateForegroundInstanceMaskRequest().perform(on: image),
            !observation.allInstances.isEmpty
        else {
            return nil
        }

        // A focus point targets the instance under it — the person whose
        // clothes we want, not the falcon/food bowl/stranger sharing the
        // frame. Background (index 0) or a miss falls back to all instances:
        // a whole-subject cutout beats no cutout.
        var instances = observation.allInstances
        if let focus {
            // `focus` is top-left normalized; Vision points are bottom-left.
            let targeted = observation
                .instanceAtPoint(NormalizedPoint(x: focus.x, y: 1 - focus.y))
                .subtracting(IndexSet(integer: 0))
            if !targeted.isEmpty {
                instances = targeted
            }
        }

        let buffer = try observation.generateMaskedImage(
            for: instances,
            imageFrom: ImageRequestHandler(image),
            croppedToInstancesExtent: true
        )

        // Through CoreImage so the mask's transparency survives into the
        // CGImage — the cutout is saved as a PNG with alpha.
        let masked = CIImage(cvPixelBuffer: buffer)
        return Self.ciContext.createCGImage(masked, from: masked.extent)
    }

    /// One context for every cutout. A `CIContext` owns a Metal command queue
    /// and compiled-kernel caches; Apple's guidance is to create one and reuse
    /// it, and a fresh context per image pays that setup again every time. It
    /// is thread-safe and Sendable, so a shared static is fine.
    private static let ciContext = CIContext()

    private static let notACandidate = GarmentObservation(
        isClothingCandidate: false,
        confidence: 0,
        labels: []
    )
}
