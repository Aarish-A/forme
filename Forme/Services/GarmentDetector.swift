import CoreGraphics
import Foundation

/// What an image analysis says about a photo.
///
/// `labels` stay in memory for the length of a scan and are never logged or
/// persisted — what someone wears is theirs.
nonisolated struct GarmentObservation: Sendable, Equatable {
    var isClothingCandidate: Bool
    var confidence: Float
    var labels: [String]
    /// Normalized (0–1, top-left origin) person bounding boxes. Empty = none
    /// detected or detection unavailable.
    var people: [CGRect] = []
    /// Vision aesthetics overallScore (-1…1) when available.
    var aestheticsScore: Float?
    /// Vision's "this is a screenshot / document / receipt" flag. A fact, not a
    /// decision — ``ScanPolicy`` is what rejects on it, so the rejection shows
    /// up as a countable reason rather than as a photo that quietly vanished.
    var isUtility = false
    /// Which parts of a body the photo actually shows.
    var framing = BodyFraming()

    /// Hand-written so the new fields default to "no effect" at every existing
    /// call site — a bare optional gets no memberwise default, and `= nil` on
    /// the property is stripped by the formatter.
    init(
        isClothingCandidate: Bool,
        confidence: Float,
        labels: [String],
        people: [CGRect] = [],
        aestheticsScore: Float? = nil,
        isUtility: Bool = false,
        framing: BodyFraming = BodyFraming()
    ) {
        self.isClothingCandidate = isClothingCandidate
        self.confidence = confidence
        self.labels = labels
        self.people = people
        self.aestheticsScore = aestheticsScore
        self.isUtility = isUtility
        self.framing = framing
    }
}

/// Which parts of a body a photo shows, from pose keypoints.
///
/// This replaces clothing classification as the "is there an outfit here" signal,
/// and the swap is the single largest quality change available. Measured over 490
/// real photos: torso framing plus identity keeps 126 of 128 catalogueable photos
/// at 90% precision, where gating on Vision's clothing labels managed 44% — and
/// no threshold could have fixed that, because Vision's taxonomy has no word for
/// `shirt`, `pants`, `shorts` or `sweater`, which is most of what people wear.
///
/// The two halves are complementary and both are needed. A face-filling selfie
/// has a huge person box but no hips, so torso framing rejects it. A figure at
/// the far end of a landscape has a complete pose but occupies 12% of frame
/// height, so the size gate rejects it. Either signal alone lets one of those
/// through; that is exactly what four field tests looked like.
nonisolated struct BodyFraming: Sendable, Equatable {
    var hasShoulders = false
    var hasHips = false
    var hasKnees = false

    /// Enough of a body to read a garment off. Shoulders and hips together mean
    /// the torso is in frame, which is where a top lives — the most common item
    /// in a real wardrobe by some margin.
    var showsTorso: Bool {
        hasShoulders && hasHips
    }

    /// No pose at all: nobody in frame, or a body Vision couldn't resolve.
    static let none = BodyFraming()
}

/// A compact perceptual signature of an image, for near-duplicate grouping.
///
/// Distances are only meaningful between fingerprints computed by the same
/// detector in the same scan — Vision's feature-print space shifts between OS
/// revisions, so nothing here is persisted.
nonisolated struct ImageFingerprint: Sendable, Equatable {
    var vector: [Float]

    /// Euclidean distance; smaller means more similar. Mismatched lengths
    /// (different Vision revisions mid-flight) read as maximally distant.
    func distance(to other: ImageFingerprint) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var sum: Float = 0
        for index in vector.indices {
            let difference = vector[index] - other.vector[index]
            sum += difference * difference
        }
        return sum.squareRoot()
    }
}

/// On-device image understanding for the scan and manual-add flows.
///
/// Stores depend on this rather than Vision so the pipeline can be scripted in
/// tests and previews — and because Vision requests routinely fail on the
/// Simulator, which every call site has to survive anyway.
nonisolated protocol GarmentDetector: Sendable {
    /// Does this photo prominently contain clothing / an outfit?
    func analyze(_ image: CGImage) async throws -> GarmentObservation
    /// Feature print for near-duplicate grouping. Nil when unavailable.
    func fingerprint(_ image: CGImage) async throws -> ImageFingerprint?
    /// Subject lifted onto transparency, cropped to the subject; nil when no
    /// clear subject is found. `focus` (normalized, top-left origin) selects
    /// the instance at that point (person-targeted cutout); nil = all
    /// instances.
    func cutout(from image: CGImage, focus: CGPoint?) async throws -> CGImage?
}

/// Pure candidacy policy — facts in, decision out. All tuning lives here.
///
/// A photo is a candidate when it prominently shows clothing AND either a
/// meaningfully-sized person wears it or the classifier is so sure it's
/// clothing that a flat-lay/garment-on-bed shot survives without one.
nonisolated struct ScanPolicy: Sendable {
    /// Smallest a person can be, as a fraction of frame height, and still have
    /// a readable outfit. Kills the figure at the far end of a landscape.
    var minPersonHeightFraction: CGFloat = 0.25

    /// Why a photo is or isn't a candidate.
    ///
    /// The reason is the point. A `Bool` makes every rejection look the same, so
    /// "the scan found nothing" can't be told apart from "the scan found plenty
    /// and one gate ate it all" — which is precisely the question a field test
    /// needs answered.
    nonisolated enum Verdict: Sendable, Equatable {
        case candidate
        case noPerson
        case utilityImage
        case personTooSmall
        case noOutfitVisible

        var dropReason: ScanReport.DropReason? {
            switch self {
            case .candidate: nil
            case .noPerson: .noPerson
            case .utilityImage: .utilityImage
            case .personTooSmall: .personTooSmall
            case .noOutfitVisible: .noOutfitVisible
            }
        }
    }

    /// Three questions, in cost order: is anyone here, are they big enough to
    /// read, and can we actually see what they're wearing.
    ///
    /// Note what is **not** asked: "does this look like clothing". That gate is
    /// gone. It was answering a question Vision cannot answer — its taxonomy has
    /// no identifier for a shirt, trousers or a sweater — and on a real library
    /// it dropped 1,602 of 2,500 photos on that basis while admitting a
    /// stranger's formalwear photoshoot, because `suit` and `gown` *are* in the
    /// vocabulary. Clothing labels survive as a category hint on
    /// ``GarmentObservation``; they no longer decide anything.
    func verdict(_ observation: GarmentObservation) -> Verdict {
        // Screenshots, receipts and catalogue pages, which classify as clothing
        // confidently and often.
        guard !observation.isUtility else { return .utilityImage }

        guard let tallest = observation.people.map(\.height).max() else { return .noPerson }
        guard tallest >= minPersonHeightFraction else { return .personTooSmall }
        // A face filling the frame passes the size gate comfortably and carries
        // no garment at all; only the torso being in shot settles it.
        guard observation.framing.showsTorso else { return .noOutfitVisible }
        return .candidate
    }

    func isCandidate(_ observation: GarmentObservation) -> Bool {
        verdict(observation) == .candidate
    }
}

/// Maps Vision classify labels to a rough category suggestion.
///
/// The user can always correct it, so the bar is "usually right and never
/// insulting", not accuracy.
nonisolated enum GarmentLabelMap {
    /// Priority order: the first set with a match wins. Dresses come first
    /// because "gown" also classifies as clothing, and shoes before tops
    /// because a full-body photo labels both.
    private static let orderedSets: [(labels: Set<String>, category: Piece.Category)] = [
        (dressLabels, .dress),
        (outerwearLabels, .outerwear),
        (bottomLabels, .bottom),
        (shoeLabels, .shoes),
        (accessoryLabels, .accessory),
        (topLabels, .top)
    ]

    private static let dressLabels: Set = [
        "dress", "dresses", "gown", "gowns", "sundress", "wedding_dress", "evening_dress", "jumpsuit"
    ]

    private static let outerwearLabels: Set = [
        "coat", "coats", "overcoat", "trench_coat", "raincoat", "jacket", "jackets", "blazer",
        "parka", "cloak", "cape", "poncho"
    ]

    private static let bottomLabels: Set = [
        "jeans", "denim", "pants", "trousers", "leggings", "shorts", "skirt", "skirts", "kilt", "sarong"
    ]

    private static let shoeLabels: Set = [
        "shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "sandal", "sandals",
        "high_heel", "high_heels", "footwear", "moccasin", "loafer", "slipper"
    ]

    private static let accessoryLabels: Set = [
        "hat", "hats", "cap", "beanie", "scarf", "necktie", "tie", "bow_tie", "belt", "backpack",
        "purse", "handbag", "bag", "sunglasses", "glasses", "watch", "jewelry", "glove", "gloves"
    ]

    private static let topLabels: Set = [
        "blouse", "hoodie", "sweatshirt", "sweater", "jumper", "cardigan", "vest", "suit", "tuxedo",
        "shirt", "shirts", "tshirt", "t-shirt", "t_shirt", "top", "tank_top", "polo", "swimsuit"
    ]

    static func category(for labels: [String]) -> Piece.Category {
        let normalized = Set(labels.map { $0.lowercased() })

        for entry in orderedSets where !entry.labels.isDisjoint(with: normalized) {
            return entry.category
        }
        return .other
    }
}

// MARK: - Stub implementation

/// A scripted detector. Defaults say "yes, clothing, worn by someone" and hand
/// the image back unchanged, which is what a preview wants; tests override the
/// closures. The default person rect matters: it keeps `ScanPolicy`'s person
/// gate open so existing previews and tests pass without scripting people.
nonisolated struct StubGarmentDetector: GarmentDetector {
    var analyzeResult: @Sendable (CGImage) -> GarmentObservation = { _ in
        GarmentObservation(
            isClothingCandidate: true,
            confidence: 1,
            labels: ["garment"],
            people: [CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6)],
            // Torso visible by default, so a preview or a test that isn't about
            // framing still produces candidates.
            framing: BodyFraming(hasShoulders: true, hasHips: true)
        )
    }

    /// Inert by default — no fingerprint means "grouping unavailable", so
    /// tests that aren't about grouping never see it.
    var fingerprintResult: @Sendable (CGImage) -> ImageFingerprint? = { _ in nil }

    var cutoutResult: @Sendable (CGImage, CGPoint?) -> CGImage? = { image, _ in image }

    func analyze(_ image: CGImage) async throws -> GarmentObservation {
        analyzeResult(image)
    }

    func fingerprint(_ image: CGImage) async throws -> ImageFingerprint? {
        fingerprintResult(image)
    }

    func cutout(from image: CGImage, focus: CGPoint?) async throws -> CGImage? {
        cutoutResult(image, focus)
    }
}
