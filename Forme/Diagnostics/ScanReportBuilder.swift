import CoreGraphics
import Foundation

/// The measurements one photo produced on its way through the pipeline.
///
/// Scalars only, and deliberately so: this rides on every pipeline event, so it
/// must stay cheap to copy across actor boundaries, and it must not become a
/// place where facts about a photo's *content* accumulate. See ``ScanReport``
/// for what may and may not be recorded.
nonisolated struct PhotoTrace: Sendable, Equatable {
    var didLoad = false
    var didAnalyze = false
    /// Best clothing-label confidence, whatever the gate thinks of it. Nil when
    /// the photo showed no clothing at all — those belong in ``drop``, not in
    /// the histogram, where thousands of zeroes would drown the range the
    /// threshold actually discriminates over.
    var clothingConfidence: Float?
    /// Tallest person box as a fraction of frame height.
    var largestPersonHeight: CGFloat?
    /// Shortest side, in pixels, of every face *detected* — including the ones
    /// too small to embed. Measuring only the survivors is what hid the 48px
    /// floor for three field tests.
    var faceSidesPx: [CGFloat] = []
    /// Best cosine similarity against the seed, gate or no gate.
    var bestFaceCosine: Float?
    /// Set when the analysis-resolution faces were all too small and the photo
    /// was re-read at full resolution to try again.
    var didRetryIdentityAtHighRes = false
    var drop: ScanReport.DropReason?

    mutating func record(_ outcome: ScanPipeline.IdentityOutcome) {
        faceSidesPx = outcome.faceSidesPx
        bestFaceCosine = outcome.bestCosine
        didRetryIdentityAtHighRes = outcome.didRetry
    }
}

/// Folds per-photo traces into a ``ScanReport``.
///
/// A plain value the store owns and mutates at its serialized event drain —
/// not a service behind a protocol. There is one implementation and one call
/// site, and the drain is already the pipeline's single ordered point, so a
/// seam here would buy nothing but indirection.
nonisolated struct ScanReportBuilder {
    private let runID: String
    private let startedAt: Date
    private let policy: ScanPolicy
    private let identityActive: Bool

    private var funnel = ScanReport.Funnel()
    private var drops: [ScanReport.DropReason: Int] = [:]
    private var clothingConfidence: Histogram
    private var personHeight: Histogram
    private var faceSidePx: Histogram
    private var faceCosine: Histogram

    init(policy: ScanPolicy, fetched: Int, identityActive: Bool, startedAt: Date, runID: String) {
        self.runID = runID
        self.startedAt = startedAt
        self.policy = policy
        self.identityActive = identityActive
        funnel.fetched = fetched

        self.clothingConfidence = Histogram(
            name: "clothingConfidence",
            lowerBound: 0,
            upperBound: 1,
            bins: 20,
            threshold: nil
        )
        self.personHeight = Histogram(
            name: "personHeightFraction",
            lowerBound: 0,
            upperBound: 1,
            bins: 20,
            threshold: Double(policy.minPersonHeightFraction)
        )
        // 0–320px spans "invisible to Vision" through "comfortably embeddable",
        // which is the range the analysis resolution actually produces.
        self.faceSidePx = Histogram(
            name: "faceSidePx",
            lowerBound: 0,
            upperBound: 320,
            bins: 40,
            threshold: Double(FaceIdentityLimits.minimumFacePixels)
        )
        // Cosine can go negative for actively dissimilar faces, so the floor is
        // below zero — clipping it would hide exactly the confident non-matches.
        self.faceCosine = Histogram(
            name: "faceCosine",
            lowerBound: -0.2,
            upperBound: 1,
            bins: 48,
            threshold: Double(FaceMatcher.similarityThreshold)
        )
    }

    mutating func record(_ trace: PhotoTrace, wasCandidate: Bool, ownerStatus: ScanStore.OwnerStatus?) {
        funnel.scanned += 1

        if trace.didLoad {
            funnel.loaded += 1
        }
        if trace.didAnalyze {
            funnel.analyzed += 1
        }
        if let confidence = trace.clothingConfidence {
            clothingConfidence.record(Double(confidence))
        }

        if let height = trace.largestPersonHeight {
            personHeight.record(Double(height))
        }
        for side in trace.faceSidesPx {
            faceSidePx.record(Double(side))
        }
        if let cosine = trace.bestFaceCosine {
            faceCosine.record(Double(cosine))
        }
        if trace.didRetryIdentityAtHighRes {
            funnel.identityRetried += 1
        }
        if let drop = trace.drop {
            drops[drop, default: 0] += 1
        }

        guard wasCandidate else { return }
        funnel.candidates += 1
        switch ownerStatus {
        case .you: funnel.identityYou += 1
        case .other: funnel.identityOther += 1
        case .unknown, nil: funnel.identityUnknown += 1
        }
    }

    /// Review-time counts, known only once the user has finished with the grid.
    mutating func recordReview(groups: Int, groupsWithYou: Int, shown: Int) {
        funnel.groups = groups
        funnel.groupsWithYou = groupsWithYou
        funnel.shown = shown
    }

    mutating func recordSaved(_ count: Int) {
        funnel.saved = count
    }

    func report(wasCancelled: Bool, now: Date = Date()) -> ScanReport {
        let histograms = [clothingConfidence, personHeight, faceSidePx, faceCosine]
        return ScanReport(
            runID: runID,
            startedAt: startedAt,
            durationMS: Int(now.timeIntervalSince(startedAt) * 1000),
            wasCancelled: wasCancelled,
            build: .current,
            knobs: [
                "minPersonHeightFraction": Double(policy.minPersonHeightFraction),
                "faceSimilarityThreshold": Double(FaceMatcher.similarityThreshold),
                "minimumFacePixels": Double(FaceIdentityLimits.minimumFacePixels),
                "analysisPixelSize": Double(ScanPipeline.analysisPixelSize),
                "identityPixelSize": Double(ScanPipeline.identityPixelSize),
                "scanConcurrency": Double(ScanPipeline.scanConcurrency)
            ],
            funnel: funnel,
            drops: Dictionary(uniqueKeysWithValues: drops.map { ($0.key.rawValue, $0.value) }),
            scores: histograms,
            warnings: Self.tripwires(
                over: histograms,
                funnel: funnel,
                identityActive: identityActive
            )
        )
    }

    // MARK: - Tripwires

    /// The minimum sample size before a pass rate means anything. Below this a
    /// unanimous result is just a small sample.
    private static let minimumSamples = 20

    /// Pass rate at or below which a gate is doing nothing worth the name — and,
    /// mirrored, above which it is letting everything through. 5% is a judgement
    /// call, not a measurement; it is here to be loud, and a false alarm costs
    /// one line in a debug report.
    private static let inertPassRate = 0.05

    private static func tripwires(
        over histograms: [Histogram],
        funnel: ScanReport.Funnel,
        identityActive: Bool
    ) -> [ScanReport.Warning] {
        var warnings: [ScanReport.Warning] = []

        for histogram in histograms {
            guard let threshold = histogram.threshold else { continue }
            guard histogram.sampleCount >= minimumSamples, let rate = histogram.passRate else { continue }

            let shared: [String: Double] = [
                "threshold": threshold,
                "samples": Double(histogram.sampleCount),
                "passed": Double(histogram.passed),
                "max": histogram.maximum ?? 0,
                "min": histogram.minimum ?? 0
            ]
            // Near-unanimous, not unanimous. The first real scan had a person
            // gate passing 96.8% — a gate rejecting 18 photos out of 2500 is
            // decorative, and a rule that only fired at exactly 100% said
            // nothing about it.
            if rate <= Self.inertPassRate {
                warnings.append(.init(
                    code: "gateRejectsAlmostEverything",
                    subject: histogram.name,
                    values: shared
                ))
            } else if rate >= 1 - Self.inertPassRate {
                warnings.append(.init(
                    code: "gateAcceptsAlmostEverything",
                    subject: histogram.name,
                    values: shared
                ))
            }
        }

        // A gate that never saw a sample is invisible to the rules above, and
        // it is the more alarming failure: the stage above it produced nothing
        // to measure.
        if identityActive, funnel.candidates >= minimumSamples {
            let cosine = histograms.first { $0.name == "faceCosine" }
            if cosine?.sampleCount == 0 {
                warnings.append(.init(
                    code: "noSamples",
                    subject: "faceCosine",
                    values: ["samples": 0, "upstreamCandidates": Double(funnel.candidates)]
                ))
            }
        }
        return warnings
    }
}
