import CoreGraphics
import Foundation
import Testing
@testable import Forme

@Suite("Scan policy")
struct ScanPolicyTests {
    private let policy = ScanPolicy()

    private func observation(
        confidence: Float = 0.6,
        people: [CGRect] = [],
        framing: BodyFraming = BodyFraming(hasShoulders: true, hasHips: true),
        isUtility: Bool = false
    ) -> GarmentObservation {
        GarmentObservation(
            isClothingCandidate: confidence > 0,
            confidence: confidence,
            labels: [],
            people: people,
            isUtility: isUtility,
            framing: framing
        )
    }

    private func person(height: CGFloat) -> CGRect {
        CGRect(x: 0.3, y: 0.1, width: 0.3, height: height)
    }

    @Test("A person big enough to see, with a torso in shot, is a candidate")
    func acceptsFramedPerson() {
        #expect(policy.isCandidate(observation(people: [person(height: 0.5)])))
    }

    @Test("Nobody in frame is never a candidate")
    func rejectsPersonless() {
        #expect(policy.verdict(observation(confidence: 0.95, people: [])) == .noPerson)
    }

    @Test("A face filling the frame is rejected — no torso, no outfit")
    func rejectsFaceCloseup() {
        // The size gate passes comfortably; only framing catches this, which is
        // why box height alone was never enough.
        let closeup = observation(
            people: [person(height: 0.95)],
            framing: BodyFraming(hasShoulders: true)
        )
        #expect(policy.verdict(closeup) == .noOutfitVisible)
    }

    @Test("A distant figure is rejected on size even with a complete pose")
    func rejectsTinyPerson() {
        let distant = observation(
            people: [person(height: 0.1)],
            framing: BodyFraming(hasShoulders: true, hasHips: true, hasKnees: true)
        )
        #expect(policy.verdict(distant) == .personTooSmall)
    }

    @Test("Clothing confidence no longer decides anything")
    func confidenceDoesNotGate() {
        // Vision has no identifier for a shirt, trousers or a sweater, so a
        // confidence of zero says nothing about whether an outfit is visible.
        #expect(policy.isCandidate(observation(confidence: 0, people: [person(height: 0.5)])))
    }

    @Test("Screenshots and receipts are rejected however well framed")
    func rejectsUtilityImages() {
        let receipt = observation(people: [person(height: 0.8)], isUtility: true)
        #expect(policy.verdict(receipt) == .utilityImage)
    }

    @Test("One meaningful person among small ones is enough")
    func acceptsWhenAnyPersonIsMeaningful() {
        #expect(policy.isCandidate(observation(people: [person(height: 0.1), person(height: 0.3)])))
    }

    @Test("The size threshold is inclusive at the boundary")
    func boundaryIsInclusive() {
        #expect(policy.isCandidate(observation(people: [person(height: 0.25)])))
    }

    @Test("The size knob is the tuning surface")
    func knobChangesTheDecision() {
        var strict = ScanPolicy()
        strict.minPersonHeightFraction = 0.7
        let subject = observation(people: [person(height: 0.5)])
        #expect(!strict.isCandidate(subject))
        #expect(ScanPolicy().isCandidate(subject))
    }
}

@Suite("Image fingerprint")
struct ImageFingerprintTests {
    @Test("Distance is Euclidean")
    func euclideanDistance() {
        let lhs = ImageFingerprint(vector: [0, 0, 0])
        let rhs = ImageFingerprint(vector: [3, 4, 0])
        #expect(lhs.distance(to: rhs) == 5)
        #expect(rhs.distance(to: lhs) == 5)
        #expect(lhs.distance(to: lhs) == 0)
    }

    @Test("Mismatched vector lengths read as maximally distant, never a crash")
    func mismatchedLengthsAreFar() {
        let lhs = ImageFingerprint(vector: [1, 2])
        let rhs = ImageFingerprint(vector: [1, 2, 3])
        #expect(lhs.distance(to: rhs) == .greatestFiniteMagnitude)
        #expect(ImageFingerprint(vector: []).distance(to: ImageFingerprint(vector: [])) == .greatestFiniteMagnitude)
    }
}

@Suite("In-memory photo library")
struct InMemoryPhotoLibraryServiceTests {
    private func asset(_ id: String, daysAgo: Double, isScreenshot: Bool = false) -> PhotoAsset {
        PhotoAsset(
            id: id,
            creationDate: Date(timeIntervalSinceReferenceDate: 1_000_000 - daysAgo * 86400),
            isScreenshot: isScreenshot
        )
    }

    @Test("Assets come back newest first, capped at the limit")
    func newestFirstWithLimit() async {
        let service = InMemoryPhotoLibraryService(
            authorization: .full,
            assets: [asset("old", daysAgo: 3), asset("new", daysAgo: 1), asset("mid", daysAgo: 2)]
        )

        let all = await service.imageAssets(before: nil, limit: 10)
        #expect(all.map(\.id) == ["new", "mid", "old"])

        let capped = await service.imageAssets(before: nil, limit: 2)
        #expect(capped.map(\.id) == ["new", "mid"])
    }

    @Test("before returns only strictly older assets; undated ones drop out")
    func beforeIsStrict() async {
        let cutoff = asset("cutoff", daysAgo: 2)
        let service = InMemoryPhotoLibraryService(
            authorization: .full,
            assets: [
                asset("new", daysAgo: 1),
                cutoff,
                asset("old", daysAgo: 3),
                PhotoAsset(id: "undated", creationDate: nil)
            ]
        )

        let older = await service.imageAssets(before: cutoff.creationDate, limit: 10)

        #expect(older.map(\.id) == ["old"])
    }

    @Test("Screenshots keep their flag so the store's own filter can drop them")
    func screenshotFlagSurvives() async {
        let service = InMemoryPhotoLibraryService(
            authorization: .full,
            assets: [asset("shot", daysAgo: 1, isScreenshot: true), asset("photo", daysAgo: 2)]
        )

        let assets = await service.imageAssets(before: nil, limit: 10)

        #expect(assets.first { $0.id == "shot" }?.isScreenshot == true)
        #expect(assets.first { $0.id == "photo" }?.isScreenshot == false)
    }

    @Test("Selfies are their own seeded set, newest first and capped")
    func selfiesAreSeparate() async {
        let service = InMemoryPhotoLibraryService(
            authorization: .full,
            assets: [asset("library", daysAgo: 1)],
            selfies: [asset("selfie-old", daysAgo: 5), asset("selfie-new", daysAgo: 4)]
        )

        let selfies = await service.selfieAssets(limit: 10)
        #expect(selfies.map(\.id) == ["selfie-new", "selfie-old"])

        let capped = await service.selfieAssets(limit: 1)
        #expect(capped.map(\.id) == ["selfie-new"])

        let library = await service.imageAssets(before: nil, limit: 10)
        #expect(library.map(\.id) == ["library"])
    }
}

@Suite("Stub garment detector defaults")
struct StubGarmentDetectorDefaultTests {
    @Test("The default observation passes the scan policy's person gate")
    func defaultObservationPassesPolicy() async throws {
        let image = try #require(TestImageFactory.image(color: .teal))

        let observation = try await StubGarmentDetector().analyze(image)

        #expect(ScanPolicy().isCandidate(observation))
    }

    @Test("The default fingerprint is inert")
    func defaultFingerprintIsNil() async throws {
        let image = try #require(TestImageFactory.image(color: .teal))
        #expect(try await StubGarmentDetector().fingerprint(image) == nil)
    }

    @Test("The default cutout hands the image back whatever the focus")
    func defaultCutoutIgnoresFocus() async throws {
        let image = try #require(TestImageFactory.image(color: .teal))
        let detector = StubGarmentDetector()

        #expect(try await detector.cutout(from: image, focus: nil) === image)
        #expect(try await detector.cutout(from: image, focus: CGPoint(x: 0.5, y: 0.5)) === image)
    }
}
