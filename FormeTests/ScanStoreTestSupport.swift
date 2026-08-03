import CoreGraphics
import Foundation
import Testing
@testable import Forme

// Shared fixtures and scripted services for the scan-store suites, split out
// of `ScanStoreTests.swift` purely for file length. Internal rather than
// private so both suites (and only this test target) can reach them.

// MARK: - Shared fixtures

/// Builders the scan-store suites lean on. `nonisolated` because the stub
/// closures that use them run off the main actor inside the scan pipeline.
nonisolated enum Fix {
    /// The scripted detector tells clothing from everything else by pixel
    /// size, because a `CGImage`'s dimensions are the only handle a test has.
    static let clothingEdge = 32
    static let otherEdge = 64

    /// A fixed base date so grouping and watermark maths are deterministic.
    static let baseDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func date(_ offset: TimeInterval) -> Date {
        baseDate.addingTimeInterval(offset)
    }

    /// A person tall enough to pass `ScanPolicy`'s gate.
    static let tallPerson = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.7)

    // L2-normalized so dot-product similarity behaves like the real model's.
    static let owner = FaceEmbedding(vector: [1, 0, 0])
    static let stranger = FaceEmbedding(vector: [0, 1, 0])
    static let nearOwner = FaceEmbedding(vector: [0.93, 0, 0.3676])

    static let faceBox = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
    static func face(_ embedding: FaceEmbedding, quality: Float = 0.5) -> DetectedFace {
        DetectedFace(boundingBox: faceBox, embedding: embedding, captureQuality: quality)
    }

    /// Torso visible by default, so suites that aren't about framing keep
    /// producing candidates. Pass `framing:` to test the outfit-visibility gate.
    static func garment(
        confidence: Float = 0.9,
        people: [CGRect] = [tallPerson],
        aesthetics: Float? = nil,
        framing: BodyFraming = BodyFraming(hasShoulders: true, hasHips: true)
    ) -> GarmentObservation {
        GarmentObservation(
            isClothingCandidate: true,
            confidence: confidence,
            labels: ["sneaker"],
            people: people,
            aestheticsScore: aesthetics,
            framing: framing
        )
    }

    static let notGarment = GarmentObservation(isClothingCandidate: false, confidence: 0.1, labels: [])

    struct Spec {
        var id: String
        var width: Int
        var date: Date
    }

    static func spec(_ id: String, _ width: Int, at offset: TimeInterval) -> Spec {
        Spec(id: id, width: width, date: date(offset))
    }

    /// `count` garment assets (then `other` non-garments), an hour apart,
    /// newest first, ids "asset-0"...
    static func clothingSpecs(_ count: Int, other: Int = 0) -> [Spec] {
        (0 ..< (count + other)).map { index in
            spec("asset-\(index)", index < count ? clothingEdge : otherEdge, at: TimeInterval(-index) * 3600)
        }
    }

    /// A library with one distinct-size image per spec. `extra` assets carry
    /// no image (for screenshots, which must never be loaded anyway).
    static func library(
        _ specs: [Spec],
        selfies: [Spec] = [],
        extra: [PhotoAsset] = [],
        authorization: PhotoLibraryAuthorization = .full,
        grantsOnRequest: PhotoLibraryAuthorization = .full
    ) throws -> InMemoryPhotoLibraryService {
        var images: [String: CGImage] = [:]
        func assets(_ list: [Spec]) throws -> [PhotoAsset] {
            try list.enumerated().map { index, spec in
                // Unwrapped into a local rather than assigned straight into the
                // dictionary: a subscript assignment expects `CGImage?`, which
                // makes `#require` look like it is unwrapping nothing, and it
                // says so as a warning that CI turns into an error.
                let image = try #require(
                    TestImageFactory.image(color: TestImageFactory.Color.palette(index), size: spec.width)
                )
                images[spec.id] = image
                return PhotoAsset(id: spec.id, creationDate: spec.date)
            }
        }
        return try InMemoryPhotoLibraryService(
            authorization: authorization,
            grantsOnRequest: grantsOnRequest,
            assets: assets(specs) + extra,
            selfies: assets(selfies),
            images: images
        )
    }

    /// Defaults to "width == clothingEdge is clothing worn by a person".
    static func detector(
        analyze: (@Sendable (CGImage) -> GarmentObservation)? = nil,
        fingerprint: (@Sendable (CGImage) -> ImageFingerprint?)? = nil
    ) -> StubGarmentDetector {
        var stub = StubGarmentDetector()
        stub.analyzeResult = analyze ?? { image in image.width == clothingEdge ? garment() : notGarment }
        if let fingerprint {
            stub.fingerprintResult = fingerprint
        }
        return stub
    }

    static func identity(
        available: Bool = true,
        faces: @escaping @Sendable (CGImage) -> [DetectedFace] = { _ in [] }
    ) -> StubFaceIdentityService {
        var stub = StubFaceIdentityService()
        stub.isAvailable = available
        stub.facesResult = faces
        return stub
    }
}

/// Identity is off by default so non-identity tests never park in
/// `.identitySetup`; identity tests pass their own scripted service.
func makeStore(
    library: any PhotoLibraryService,
    detector: StubGarmentDetector? = nil,
    wardrobe: any WardrobeService = InMemoryWardrobeService(),
    history: any ScanHistoryService = InMemoryScanHistoryService(),
    faceIdentity: StubFaceIdentityService? = nil,
    faceSeed: any FaceSeedService = InMemoryFaceSeedService(),
    existing: Set<String> = [],
    mode: ScanStore.ScanMode = .newest
) -> ScanStore {
    ScanStore(
        photoLibrary: library,
        detector: detector ?? Fix.detector(),
        wardrobe: wardrobe,
        history: history,
        faceIdentity: faceIdentity ?? Fix.identity(available: false),
        faceSeed: faceSeed,
        existingSourceAssetIDs: existing,
        mode: mode
    )
}

// MARK: - Scripted services

/// A face service that reports available until its first detection call
/// "fails to load the model" — the lazy-load failure a seeded scan must
/// survive without hiding everything as someone else's.
final nonisolated class DyingFaceIdentityService: FaceIdentityService, @unchecked Sendable {
    private let lock = NSLock()
    private var died = false

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !died
    }

    func detectFaces(in _: CGImage) async throws -> FaceDetection {
        die()
        return .none
    }

    /// Synchronous on purpose: `NSLock` may not be held across an `await`,
    /// and the compiler bans it inside async bodies outright.
    private func die() {
        lock.lock()
        defer { lock.unlock() }
        died = true
    }
}

/// Shared plumbing for the scripted photo libraries below: always authorized,
/// no selfies, assets straight from immutable storage.
nonisolated protocol ScriptedPhotoLibrary: PhotoLibraryService {
    nonisolated var scriptedAssets: [PhotoAsset] { get }
}

extension ScriptedPhotoLibrary {
    nonisolated func currentAuthorization() -> PhotoLibraryAuthorization {
        .full
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        .full
    }

    func imageAssets(before _: Date?, limit _: Int) async -> [PhotoAsset] {
        scriptedAssets
    }

    func selfieAssets(limit _: Int) async -> [PhotoAsset] {
        []
    }
}

/// A photo library that delays one asset's image until every other asset has
/// been served, so the newest photo's pipeline finishes LAST and chronological
/// insertion has real out-of-order completion to fix up.
actor ReorderingPhotoLibrary: ScriptedPhotoLibrary {
    nonisolated let scriptedAssets: [PhotoAsset]
    private let image: CGImage
    private let delayedID: String
    private var servedOthers = 0
    private var release: AsyncStream<Void>.Continuation?

    init(assets: [PhotoAsset], image: CGImage, delayedID: String) {
        self.scriptedAssets = assets
        self.image = image
        self.delayedID = delayedID
    }

    func loadImage(assetID: String, maxPixelSize _: Int) async throws -> CGImage? {
        if assetID == delayedID {
            if servedOthers < scriptedAssets.count - 1 {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                release = continuation
                for await _ in stream {}
            }
        } else {
            servedOthers += 1
            if servedOthers >= scriptedAssets.count - 1 {
                release?.finish()
                release = nil
            }
        }
        return image
    }
}

/// A photo library that serves a few images and then makes every later request
/// wait until it is cancelled.
///
/// This is what lets a test observe a scan *mid-flight* without sleeping or
/// polling: `waitForStall()` returns the moment the pipeline has run out of
/// photos it can get, which is a fact about the scan rather than about timing.
actor StallingPhotoLibrary: ScriptedPhotoLibrary {
    nonisolated let scriptedAssets: [PhotoAsset]
    private let image: CGImage
    private let servesBeforeStalling: Int
    private var served = 0

    private let stalled: AsyncStream<Void>
    private let stalledContinuation: AsyncStream<Void>.Continuation

    init(assetCount: Int, servesBeforeStalling: Int, image: CGImage) {
        self.scriptedAssets = (0 ..< assetCount).map {
            PhotoAsset(id: "asset-\($0)", creationDate: Fix.date(TimeInterval(-$0)))
        }
        self.image = image
        self.servesBeforeStalling = servesBeforeStalling
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stalled = stream
        self.stalledContinuation = continuation
    }

    func loadImage(assetID _: String, maxPixelSize _: Int) async -> CGImage? {
        guard served < servesBeforeStalling else {
            await stallUntilCancelled()
            return nil
        }
        served += 1
        return image
    }

    /// Returns once at least one request has had to stall.
    func waitForStall() async {
        for await _ in stalled {
            return
        }
    }

    private func stallUntilCancelled() async {
        stalledContinuation.yield(())
        // Cancellation ends the sleep instantly; the duration is only a
        // backstop against a scan that forgot to tear itself down.
        try? await Task.sleep(for: .seconds(600))
    }
}
