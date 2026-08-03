import CoreGraphics
import Foundation
import Testing
@testable import Forme

@Suite("Histogram")
nonisolated struct HistogramTests {
    @Test("The threshold becomes an exact bucket edge so the pass count is a fact")
    func thresholdIsSplicedAsAnEdge() {
        // 0.363 falls inside a bucket of a plain 0...1 split into ten.
        var histogram = Histogram(name: "cosine", lowerBound: 0, upperBound: 1, bins: 10, threshold: 0.363)
        #expect(histogram.edges.contains(0.363))

        histogram.record(0.2)
        histogram.record(0.362)
        histogram.record(0.363)
        histogram.record(0.9)

        #expect(histogram.sampleCount == 4)
        #expect(histogram.passed == 2)
        #expect(histogram.passRate == 0.5)
        #expect(histogram.minimum == 0.2)
        #expect(histogram.maximum == 0.9)
    }

    @Test("Counts cover everything, including values outside the nominal range")
    func countsAreTotal() {
        var histogram = Histogram(name: "side", lowerBound: 0, upperBound: 100, bins: 4)
        for value in [-5.0, 10, 50, 99, 400] {
            histogram.record(value)
        }
        #expect(histogram.counts.reduce(0, +) == 5)
        // No threshold means everything passes — "nothing to fail" rather than
        // a silent zero.
        #expect(histogram.passed == 5)
    }

    @Test("An empty histogram has no pass rate, which is not the same as zero")
    func emptyHasNoRate() {
        let histogram = Histogram(name: "cosine", lowerBound: 0, upperBound: 1, bins: 4, threshold: 0.5)
        #expect(histogram.passRate == nil)
        #expect(histogram.mean == nil)
    }
}

@Suite("ScanPolicy verdicts")
nonisolated struct ScanPolicyVerdictTests {
    @Test("Each rejection carries the reason that caused it")
    func verdictsNameTheGate() {
        let policy = ScanPolicy()

        #expect(policy.verdict(Fix.notGarment) == .noPerson)

        var utility = Fix.garment(confidence: 0.95)
        utility.isUtility = true
        #expect(policy.verdict(utility) == .utilityImage)

        // Confidence no longer gates anything — a photo with a visible torso
        // is a candidate however little Vision recognised.
        #expect(policy.verdict(Fix.garment(confidence: 0.2)) == .candidate)

        // A person, but a small one, and not confident enough for a flat-lay.
        let distant = Fix.garment(
            confidence: 0.5,
            people: [CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.1)]
        )
        #expect(policy.verdict(distant) == .personTooSmall)

        // And a face filling the frame: big enough, but no torso to read.
        let closeup = Fix.garment(framing: BodyFraming(hasShoulders: true))
        #expect(policy.verdict(closeup) == .noOutfitVisible)

        #expect(policy.verdict(Fix.garment()) == .candidate)
        // The flat-lay escape hatch is gone: of 24 flat-lay-framed photos in
        // the real corpus, every one was food, a receipt or a postcard, and
        // none was a garment on a bed. It can come back with evidence.
        #expect(policy.verdict(Fix.garment(confidence: 0.9, people: [])) == .noPerson)
    }

    @Test("isCandidate still agrees with the verdict it wraps")
    func boolMatchesVerdict() {
        let policy = ScanPolicy()
        for observation in [Fix.garment(), Fix.garment(confidence: 0.2), Fix.notGarment] {
            #expect(policy.isCandidate(observation) == (policy.verdict(observation) == .candidate))
        }
    }
}

@Suite("Scan report")
nonisolated struct ScanReportTests {
    private func builder(identityActive: Bool = true, fetched: Int = 100) -> ScanReportBuilder {
        ScanReportBuilder(
            policy: ScanPolicy(),
            fetched: fetched,
            identityActive: identityActive,
            startedAt: Fix.date(0),
            runID: "test-run"
        )
    }

    @Test("A gate that rejects every sample it sees raises a tripwire")
    func deadGateIsFlagged() throws {
        var builder = builder()
        // Exactly the field-test failure: Vision saw faces on every photo, all
        // of them under the embedding floor.
        for _ in 0 ..< 40 {
            var trace = PhotoTrace()
            trace.didLoad = true
            trace.didAnalyze = true
            trace.faceSidesPx = [35]
            builder.record(trace, wasCandidate: true, ownerStatus: .unknown)
        }

        let report = builder.report(wasCancelled: false, now: Fix.date(10))
        let warning = try #require(report.warnings.first { $0.subject == "faceSidePx" })
        #expect(warning.code == "gateRejectsAlmostEverything")
        #expect(warning.values["passed"] == 0)
        #expect(warning.values["max"] == 35)
        #expect(warning.values["threshold"] == Double(FaceIdentityLimits.minimumFacePixels))
    }

    @Test("A gate with no samples at all is flagged separately from one that rejects")
    func silentGateIsFlagged() {
        var builder = builder()
        for _ in 0 ..< 40 {
            var trace = PhotoTrace()
            trace.didLoad = true
            trace.didAnalyze = true
            builder.record(trace, wasCandidate: true, ownerStatus: .unknown)
        }

        let report = builder.report(wasCancelled: false, now: Fix.date(10))
        #expect(report.warnings.contains { $0.code == "noSamples" && $0.subject == "faceCosine" })
    }

    @Test("A healthy spread of scores raises nothing")
    func healthyRunIsQuiet() {
        var builder = builder()
        for index in 0 ..< 40 {
            var trace = PhotoTrace()
            trace.didLoad = true
            trace.didAnalyze = true
            trace.clothingConfidence = index.isMultiple(of: 2) ? 0.2 : 0.9
            trace.faceSidesPx = [index.isMultiple(of: 2) ? 30 : 140]
            trace.bestFaceCosine = index.isMultiple(of: 2) ? 0.1 : 0.8
            builder.record(trace, wasCandidate: true, ownerStatus: .you)
        }
        #expect(builder.report(wasCancelled: false, now: Fix.date(10)).warnings.isEmpty)
    }

    @Test("The funnel counts what survived each stage")
    func funnelAddsUp() {
        var builder = builder(fetched: 5)
        var loaded = PhotoTrace()
        loaded.didLoad = true
        loaded.didAnalyze = true
        loaded.clothingConfidence = 0.9
        builder.record(loaded, wasCandidate: true, ownerStatus: .you)
        builder.record(loaded, wasCandidate: true, ownerStatus: .other)
        builder.record(loaded, wasCandidate: true, ownerStatus: .unknown)

        var dropped = PhotoTrace()
        dropped.didLoad = true
        dropped.didAnalyze = true
        dropped.drop = .noPerson
        builder.record(dropped, wasCandidate: false, ownerStatus: nil)

        var missing = PhotoTrace()
        missing.drop = .imageUnavailable
        builder.record(missing, wasCandidate: false, ownerStatus: nil)

        builder.recordReview(groups: 2, groupsWithYou: 1, shown: 3)
        builder.recordSaved(2)

        let report = builder.report(wasCancelled: false, now: Fix.date(10))
        #expect(report.funnel.fetched == 5)
        #expect(report.funnel.scanned == 5)
        #expect(report.funnel.loaded == 4)
        #expect(report.funnel.candidates == 3)
        #expect(report.funnel.identityYou == 1)
        #expect(report.funnel.identityOther == 1)
        #expect(report.funnel.identityUnknown == 1)
        #expect(report.funnel.groups == 2)
        #expect(report.funnel.groupsWithYou == 1)
        #expect(report.funnel.saved == 2)
        #expect(report.drops["noPerson"] == 1)
        #expect(report.drops["imageUnavailable"] == 1)
    }

    @Test("A report round-trips through JSON, and carries no free text to hide content in")
    func reportEncodes() throws {
        var builder = builder()
        var trace = PhotoTrace()
        trace.didLoad = true
        trace.didAnalyze = true
        trace.clothingConfidence = 0.7
        builder.record(trace, wasCandidate: true, ownerStatus: .you)

        let report = builder.report(wasCancelled: false, now: Fix.date(10))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.knobs["minimumFacePixels"] == 48)

        // Every string in the payload is a key or an enum case we wrote, never
        // a value derived from a photo.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("sneaker"))
    }
}

// MARK: - The high-resolution identity retry

/// A library whose images are exactly `maxPixelSize` wide, so a scripted face
/// service can tell the analysis pass from the retry.
private nonisolated struct ResolutionAwareLibrary: PhotoLibraryService {
    let assets: [PhotoAsset]

    func currentAuthorization() -> PhotoLibraryAuthorization {
        .full
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        .full
    }

    func imageAssets(before _: Date?, limit: Int) async -> [PhotoAsset] {
        Array(assets.prefix(limit))
    }

    func selfieAssets(limit _: Int) async -> [PhotoAsset] {
        []
    }

    func loadImage(assetID _: String, maxPixelSize: Int) async throws -> CGImage? {
        TestImageFactory.image(color: .red, size: maxPixelSize)
    }
}

/// The rule that let a stranger's photoshoot arrive pre-approved: a group with
/// no readable face was counted as the user's, and pre-selected.
@Suite("Review sections and selection defaults")
struct ReviewSectionTests {
    /// Three photos, hours apart so each forms its own group: one confidently
    /// the user, one with no readable face, one confidently somebody else.
    private func store() async throws -> ScanStore {
        let identity = Fix.identity(faces: { image in
            switch image.width {
            case 40: [Fix.face(Fix.owner)]
            case 42: [Fix.face(Fix.stranger)]
            default: []
            }
        })
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [Fix.owner], createdAt: Fix.date(0)))
        return try makeStore(
            library: Fix.library([
                Fix.spec("you", 40, at: 0),
                Fix.spec("nobody", 41, at: -7200),
                Fix.spec("stranger", 42, at: -14400)
            ]),
            detector: Fix.detector(analyze: { _ in Fix.garment() }),
            faceIdentity: identity,
            faceSeed: seedService
        )
    }

    @Test("Only positive evidence pre-selects; no evidence is shown, unchecked")
    func onlyYouIsPreSelected() async throws {
        let store = try await store()
        await store.beginScan()

        let byID = Dictionary(uniqueKeysWithValues: store.candidates.map { ($0.id, $0) })
        #expect(byID["you"]?.isSelected == true)
        #expect(byID["nobody"]?.isSelected == false)
        #expect(byID["stranger"]?.isSelected == false)
        // The button's number counts only what the scan can actually stand behind.
        #expect(store.selectedCount == 1)
    }

    @Test("Sections split by what the scan knows, and the stranger stays hidden")
    func sectionsReflectConfidence() async throws {
        let store = try await store()
        await store.beginScan()

        let sections = store.groupsByConfidence
        #expect(sections.map(\.confidence) == [.you, .unsure])
        #expect(store.hiddenOtherCount == 1)

        store.toggleShowOthers()
        #expect(store.groupsByConfidence.map(\.confidence) == [.you, .unsure, .notYou])
    }

    @Test("Keep These takes one photo per unsure group without touching the rest")
    func keepAllSelectsOnePerGroup() async throws {
        let store = try await store()
        await store.beginScan()

        let unsure = try #require(store.groupsByConfidence.first { $0.confidence == .unsure })
        store.keepAll(inGroups: Set(unsure.groups.map(\.id)))

        #expect(store.selectedCount == 2)
        // Revealing the set-aside group must not quietly select it too.
        store.toggleShowOthers()
        #expect(store.selectedCount == 2)
    }

    @Test("With identity off there is one undifferentiated section, as before")
    func identityOffKeepsOldBehaviour() async throws {
        let store = try makeStore(
            library: Fix.library([Fix.spec("a", 40, at: 0)]),
            detector: Fix.detector(analyze: { _ in Fix.garment() }),
            faceIdentity: Fix.identity(available: false)
        )
        await store.beginScan()

        #expect(!store.identityActive)
        #expect(store.groupsByConfidence.count == 1)
        #expect(store.selectedCount == 1)
    }
}

/// Main-actor isolated (the project default) because these drive ``ScanStore``.
@Suite("Identity retries at full resolution")
struct IdentityRetryTests {
    /// Faces are visible at both sizes but only embeddable at the larger one —
    /// which is what a real full-length photo does at a 512px analysis size.
    private func identity() -> StubFaceIdentityService {
        var stub = StubFaceIdentityService()
        stub.isAvailable = true
        stub.facesResult = { image in
            image.width >= ScanPipeline.identityPixelSize ? [Fix.face(Fix.owner)] : []
        }
        stub.detectedSidesResult = { image in
            image.width >= ScanPipeline.identityPixelSize ? [] : [35]
        }
        return stub
    }

    private func store(seed: FaceEmbedding) async -> ScanStore {
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [seed], createdAt: Fix.date(0)))
        return makeStore(
            library: ResolutionAwareLibrary(
                assets: [PhotoAsset(id: "asset-0", creationDate: Fix.date(0))]
            ),
            detector: Fix.detector(analyze: { _ in Fix.garment() }),
            faceIdentity: identity(),
            faceSeed: seedService
        )
    }

    @Test("A face too small to embed at analysis size is re-read larger and matched")
    func smallFaceIsRetriedAndMatched() async throws {
        let store = await store(seed: Fix.owner)
        await store.beginScan()

        #expect(store.phase == .review)
        // Without the retry this photo would be `.unknown` — absence of
        // evidence — and the identity filter would be silently inert.
        #expect(store.candidates.first?.ownerStatus == .you)

        let report = try #require(store.lastReport)
        #expect(report.funnel.identityRetried == 1)
        #expect(report.funnel.identityYou == 1)
        // Both passes' face sizes are recorded, so the report shows why the
        // retry happened as well as that it worked.
        let sides = try #require(report.scores.first { $0.name == "faceSidePx" })
        #expect(sides.sampleCount == 2)
        #expect(sides.passed == 1)
    }

    @Test("The retry can also convict: a stranger's photo becomes someone else's")
    func smallFaceIsRetriedAndRejected() async throws {
        let store = await store(seed: Fix.stranger)
        await store.beginScan()

        #expect(store.candidates.first?.ownerStatus == .other)
        let report = try #require(store.lastReport)
        #expect(report.funnel.identityOther == 1)
        // The near-miss score is recorded even though it failed the gate —
        // that distribution is what says whether 0.363 is the right number.
        let cosine = try #require(report.scores.first { $0.name == "faceCosine" })
        #expect(cosine.sampleCount == 1)
        #expect(cosine.passed == 0)
    }
}
