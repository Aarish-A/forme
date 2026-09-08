import Foundation

/// What one scan measured about itself.
///
/// The point of this type is tuning. Every threshold in the pipeline is a guess
/// until we can see the distribution of the value it gates on, and a scan over
/// a real library is the only place that distribution exists. A report is
/// written after every scan and can be pulled off the device with `make diag`.
///
/// **Privacy is a property of the type, not of its callers.** Nothing here may
/// describe what the user wears, who they are, or which photos exist: no
/// classification labels, no `Piece.Category` (not even as a count), no asset
/// identifiers or hashes of them (a stable per-photo key is still a key), no
/// embeddings, boxes, crops or thumbnails, no filenames, no location, no photo
/// timestamps. What is here is counts, durations, and histograms of scalars.
/// ``Warning`` carries `[String: Double]` rather than free text specifically so
/// that it is structurally incapable of smuggling a string derived from a
/// user's photo.
///
/// One field is included deliberately rather than by accident:
/// ``Histogram`` `faceCosine` records how strongly faces matched the user's own
/// seed. A scalar cannot be inverted back into a face, but the distribution does
/// reveal "some photos contained a person who isn't you" — a social fact, not an
/// identity. It earns its place because it is the only way to calibrate the
/// match threshold, and it is the one field to argue with first if this file
/// ever needs to get smaller.
nonisolated struct ScanReport: Codable, Sendable, Equatable {
    /// Bump when a field changes meaning, so an old report is never read as a
    /// new one.
    var schema = 1
    var runID: String
    var startedAt: Date
    var durationMS: Int
    var wasCancelled: Bool
    var build: Build
    /// Every live threshold, verbatim. Without this a report can't be compared
    /// with another one — "what changed between these two runs" would depend on
    /// remembering what the code said at the time.
    var knobs: [String: Double]
    var funnel: Funnel
    /// Why photos didn't become candidates, keyed by ``DropReason``.
    var drops: [String: Int]
    var scores: [Histogram]
    var warnings: [Warning]

    var photosPerSecond: Double {
        guard durationMS > 0 else { return 0 }
        return Double(funnel.scanned) / (Double(durationMS) / 1000)
    }

    nonisolated struct Build: Codable, Sendable, Equatable {
        var version: String
        var build: String
        var osVersion: String
        var model: String
        var isDebug: Bool
        var isSimulator: Bool
    }

    /// The scan as a funnel: each field counts what survived the stage above.
    nonisolated struct Funnel: Codable, Sendable, Equatable {
        /// Assets PhotoKit handed back for this run.
        var fetched = 0
        /// Assets the pipeline actually looked at (the rest were cancelled).
        var scanned = 0
        /// Assets whose image loaded.
        var loaded = 0
        /// Assets that reached ``ScanPolicy``.
        var analyzed = 0
        /// Assets ``ScanPolicy`` called candidates.
        var candidates = 0
        /// Candidates that got an identity verdict of `.you`.
        var identityYou = 0
        /// Candidates positively matched to someone else.
        var identityOther = 0
        /// Candidates with no usable face either way.
        var identityUnknown = 0
        /// Candidates whose face had to be re-read at full resolution.
        var identityRetried = 0
        /// Every group the scan formed, hidden ones included. Counting only the
        /// visible ones made the hidden set unmeasurable from the report.
        var groups = 0
        /// Groups containing at least one face-verified photo — the ones the
        /// review pre-selects. The honest size of the wardrobe on offer.
        var groupsWithYou = 0
        /// Candidates in visible (owner) groups.
        var shown = 0
        /// Pieces actually written to the wardrobe.
        var saved = 0
    }

    /// Why a photo didn't become a candidate. Raw values are the JSON keys.
    nonisolated enum DropReason: String, Codable, Sendable, CaseIterable {
        case cancelled
        case screenshot
        case imageUnavailable
        case analysisFailed
        case noPerson
        case utilityImage
        case personTooSmall
        case noOutfitVisible
    }

    /// A tripwire: a diagnosis rather than evidence.
    ///
    /// A histogram tells you the shape of the data and leaves you to notice the
    /// problem. A warning is the pipeline noticing on your behalf — which is
    /// what would have caught the 48px face floor on the first field test
    /// instead of the third.
    nonisolated struct Warning: Codable, Sendable, Equatable {
        var code: String
        var subject: String
        var values: [String: Double]
    }
}

// MARK: - Histogram

/// A fixed-bucket distribution of one scalar, with the live threshold spliced in
/// as an exact bucket edge.
///
/// The splice is the part that matters. If the threshold falls in the middle of
/// a bucket, "how much of this population would a different threshold admit?"
/// becomes interpolation — a guess about the thing we are trying to stop
/// guessing about. Because the edge is exact, ``passed`` is a fact.
nonisolated struct Histogram: Codable, Sendable, Equatable {
    /// What is being measured, e.g. `faceSidePx`.
    var name: String
    /// The gate applied to this value, if any. Always an exact member of
    /// ``edges``.
    var threshold: Double?
    /// Ascending bucket boundaries.
    var edges: [Double]
    /// One more entry than ``edges``: values below the first edge, each
    /// half-open bucket, then values at or above the last edge.
    var counts: [Int]
    var sampleCount = 0
    /// Values passing ``threshold`` (`>=`). Equal to ``sampleCount`` when
    /// there is no threshold.
    var passed = 0
    var sum: Double = 0
    var minimum: Double?
    var maximum: Double?

    /// Linear buckets across the given range, plus `threshold` as its own edge.
    init(name: String, lowerBound: Double, upperBound: Double, bins: Int, threshold: Double? = nil) {
        self.name = name
        self.threshold = threshold

        let count = max(1, bins)
        let step = (upperBound - lowerBound) / Double(count)
        var boundaries = (0 ... count).map { lowerBound + Double($0) * step }
        if let threshold, !boundaries.contains(threshold) {
            boundaries.append(threshold)
        }
        boundaries.sort()
        self.edges = boundaries
        self.counts = Array(repeating: 0, count: boundaries.count + 1)
    }

    mutating func record(_ value: Double) {
        sampleCount += 1
        sum += value
        minimum = Swift.min(minimum ?? value, value)
        maximum = Swift.max(maximum ?? value, value)
        if let threshold {
            if value >= threshold {
                passed += 1
            }
        } else {
            passed += 1
        }

        let index = edges.firstIndex { value < $0 } ?? edges.count
        counts[index] += 1
    }

    var mean: Double? {
        guard sampleCount > 0 else { return nil }
        return sum / Double(sampleCount)
    }

    /// Fraction of recorded values that clear ``threshold``. Nil when nothing
    /// was recorded — "no samples" is a different problem from "nothing passed",
    /// and conflating them is how a dead stage looks like a strict one.
    var passRate: Double? {
        guard sampleCount > 0 else { return nil }
        return Double(passed) / Double(sampleCount)
    }
}
