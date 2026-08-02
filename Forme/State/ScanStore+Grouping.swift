import CoreGraphics
import Foundation
import ImageIO
import UIKit

// MARK: - Candidates and groups

extension ScanStore {
    /// A photo the scan thinks shows clothing, waiting on the user's yes or no.
    nonisolated struct Candidate: Identifiable, Equatable {
        /// The source asset's identifier — one candidate per photo.
        let id: String
        let thumbnail: CGImage
        let suggestedCategory: Piece.Category
        var isSelected: Bool
        let creationDate: Date?
        let confidence: Float
        let aestheticsScore: Float?
        let fingerprint: ImageFingerprint?
        var groupID: Int
        var ownerStatus: OwnerStatus
        /// Matched face centre, else largest person centre. Normalized, top-left
        /// origin. Steers the save-time cutout at the right person instance.
        let focusPoint: CGPoint?

        init(
            id: String,
            thumbnail: CGImage,
            suggestedCategory: Piece.Category,
            isSelected: Bool = true,
            creationDate: Date? = nil,
            confidence: Float = 1,
            aestheticsScore: Float? = nil,
            fingerprint: ImageFingerprint? = nil,
            groupID: Int = 0,
            ownerStatus: OwnerStatus = .unknown,
            focusPoint: CGPoint? = nil
        ) {
            self.id = id
            self.thumbnail = thumbnail
            self.suggestedCategory = suggestedCategory
            self.isSelected = isSelected
            self.creationDate = creationDate
            self.confidence = confidence
            self.aestheticsScore = aestheticsScore
            self.fingerprint = fingerprint
            self.groupID = groupID
            self.ownerStatus = ownerStatus
            self.focusPoint = focusPoint
        }

        /// Hand-written rather than synthesised: `CGImage` is a reference type
        /// with no useful equality, and the asset id already settles identity.
        /// Every other field participates so SwiftUI sees state changes.
        static func == (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.id == rhs.id
                && lhs.suggestedCategory == rhs.suggestedCategory
                && lhs.isSelected == rhs.isSelected
                && lhs.creationDate == rhs.creationDate
                && lhs.confidence == rhs.confidence
                && lhs.aestheticsScore == rhs.aestheticsScore
                && lhs.fingerprint == rhs.fingerprint
                && lhs.groupID == rhs.groupID
                && lhs.ownerStatus == rhs.ownerStatus
                && lhs.focusPoint == rhs.focusPoint
        }
    }

    /// One "moment" of near-duplicate candidates. The review grid renders one
    /// tile per group with a "+N" badge — that expandable UI is the mitigation
    /// for dedup false-merges, so it's load-bearing, not cosmetic.
    nonisolated struct CandidateGroup: Identifiable, Equatable {
        let id: Int
        /// Best member: highest aestheticsScore, then confidence, then newest.
        var representative: Candidate
        var others: [Candidate]
        /// What identity concluded about the group as a whole.
        var confidence: GroupConfidence

        /// Visible in the review grid. Only positive evidence of someone else
        /// hides a group; absence of evidence never does.
        var isOwner: Bool {
            confidence != .notYou
        }
    }

    /// What the scan actually knows about whose clothes a group shows.
    ///
    /// Three values rather than a `Bool`, because the middle one is 41% of a
    /// real scan and it is not a mild case. Collapsing it into "yours" is what
    /// let a stranger's photoshoot arrive pre-approved: the identity filter was
    /// working — it simply never got a vote on photos where no face was big
    /// enough to embed, and silence was being read as consent.
    nonisolated enum GroupConfidence: Sendable, Equatable {
        /// Someone in the group matched the seed.
        case you
        /// No readable face anywhere in the group. Flat-lays, back-turned
        /// shots, distant figures, goggles — and also plenty of junk.
        case unsure
        /// Someone else matched and the user never did.
        case notYou
    }

    /// The group verdict shared by visibility and selection. `.you` wins over
    /// `.notYou` so one verified photo still vouches for the moment around it;
    /// `.unsure` is the absence of a verdict, never a verdict itself.
    nonisolated static func confidence(_ statuses: [OwnerStatus]) -> GroupConfidence {
        if statuses.contains(.you) {
            return .you
        }
        if statuses.contains(.other) {
            return .notYou
        }
        return .unsure
    }

    /// Kept as the visibility rule so hiding behaviour is unchanged.
    nonisolated static func isOwnerGroup(_ statuses: [OwnerStatus]) -> Bool {
        confidence(statuses) != .notYou
    }
}

// MARK: - Derived review state

extension ScanStore {
    /// The review grid's truth: one entry per moment, newest first, with
    /// non-owner groups withheld unless `showOthers`. ALWAYS render this, not
    /// `candidates`.
    var groups: [CandidateGroup] {
        memberships.compactMap { group in
            guard
                group.isOwner || showOthers,
                let representative = group.members.max(by: { Self.ranksHigher($1, over: $0) })
            else { return nil }
            return CandidateGroup(
                id: group.id,
                representative: representative,
                others: group.members.filter { $0.id != representative.id },
                confidence: group.confidence
            )
        }
    }

    /// The review's three sections, in the order they're shown. Empty sections
    /// are dropped by the view, so a scan that knows nothing about the user
    /// collapses to one list rather than showing two empty headers.
    var groupsByConfidence: [(confidence: GroupConfidence, groups: [CandidateGroup])] {
        let all = groups
        return [GroupConfidence.you, .unsure, .notYou].compactMap { confidence in
            let matching = all.filter { $0.confidence == confidence }
            return matching.isEmpty ? nil : (confidence, matching)
        }
    }

    /// How many photos the identity filter is holding back — every member of
    /// the non-owner groups, because the reveal banner promises photos and a
    /// hidden twelve-frame burst is twelve of them, not one. Independent of
    /// `showOthers`, so the count doesn't shift as it toggles.
    var hiddenOtherCount: Int {
        memberships.filter { !$0.isOwner }.reduce(0) { $0 + $1.members.count }
    }

    /// What "Add N Pieces" should say: selected members of visible groups —
    /// exactly the set `confirmSelection()` will save.
    var selectedCount: Int {
        groups.reduce(0) { total, group in
            total + ([group.representative] + group.others).count(where: \.isSelected)
        }
    }

    /// The representative ordering: highest aestheticsScore (absent scores
    /// lose), then confidence, then newest photo.
    nonisolated static func ranksHigher(_ lhs: Candidate, over rhs: Candidate) -> Bool {
        let lhsScore = lhs.aestheticsScore ?? -.infinity
        let rhsScore = rhs.aestheticsScore ?? -.infinity
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
    }

    /// A group's raw makeup, before hiding and representative election.
    private struct GroupSlice {
        var id: Int
        var members: [Candidate]
        var confidence: GroupConfidence

        var isOwner: Bool {
            confidence != .notYou
        }
    }

    /// Groups in newest-first order (first-seen order over the already-sorted
    /// candidates), each with its members and ownership settled.
    private var memberships: [GroupSlice] {
        var order: [Int] = []
        var byGroup: [Int: [Candidate]] = [:]
        for candidate in candidates {
            if byGroup[candidate.groupID] == nil {
                order.append(candidate.groupID)
            }
            byGroup[candidate.groupID, default: []].append(candidate)
        }
        return order.map { groupID in
            let members = byGroup[groupID] ?? []
            // With identity off every candidate is `.unknown`, and calling that
            // `.unsure` would be true but useless — there is nothing to be
            // unsure against. The whole grid is one undifferentiated list.
            let confidence = identityActive
                ? Self.confidence(members.map(\.ownerStatus))
                : GroupConfidence.you
            return GroupSlice(id: groupID, members: members, confidence: confidence)
        }
    }
}

// MARK: - Pipeline

/// The off-main half of a scan: everything between "here are some photos" and
/// "here is a candidate worth showing the user".
///
/// A separate `nonisolated` type rather than helpers on ``ScanStore`` because
/// the store is main-actor isolated and this work must not be. Nothing here
/// touches UI state; it emits events and lets the store decide what they mean.
nonisolated enum ScanPipeline {
    /// A photo that passed every gate, with the facts the store groups on.
    struct Finding: Sendable {
        var asset: PhotoAsset
        var thumbnail: CGImage
        var suggestedCategory: Piece.Category
        var confidence: Float
        var aestheticsScore: Float?
        var fingerprint: ImageFingerprint?
        var ownerStatus: ScanStore.OwnerStatus
        var focusPoint: CGPoint?
    }

    enum Event: Sendable {
        /// One photo looked at and passed over. Progress only.
        case scanned(PhotoAsset, PhotoTrace)
        /// One photo looked at and worth asking about.
        case found(Finding, PhotoTrace)

        var asset: PhotoAsset {
            switch self {
            case let .scanned(asset, _): asset
            case let .found(finding, _): finding.asset
            }
        }

        var trace: PhotoTrace {
            switch self {
            case let .scanned(_, trace), let .found(_, trace): trace
            }
        }
    }

    /// What the Selfies search came back with. Empty embeddings = no proposal.
    struct SeedProposal: Sendable {
        var faceCrop: CGImage?
        var embeddings: [FaceEmbedding]
    }

    /// Photos in flight at once. Three keeps the Neural Engine busy while
    /// other photos decode, without heating the phone or stuttering the grid.
    static let scanConcurrency = 3

    /// Longest edge of the image we classify and fingerprint. Small on purpose.
    static let analysisPixelSize = 512

    /// Longest edge for the identity retry.
    ///
    /// At `analysisPixelSize` a standing figure's face lands around 30–40px —
    /// under the embedding floor, so identity silently answered "don't know" on
    /// every full-length photo and absence of evidence read as ownership. When
    /// faces are seen but none are big enough, the photo is read again at this
    /// size, where the same face is ~100–130px. The retry is per-photo and only
    /// for candidates, so it costs a second decode on a small minority rather
    /// than raising the resolution of the whole scan.
    static let identityPixelSize = 1536

    /// Longest edge of the thumbnail a candidate keeps for the grids —
    /// hundreds of 512px bitmaps through review would be hundreds of megabytes.
    static let thumbnailPixelSize = 256

    /// Longest edge of the image we cut out and keep.
    static let cutoutPixelSize = 1536

    /// How many Selfies-album photos the seed search reads.
    static let selfieSeedLimit = 30

    /// Reference embeddings a seed keeps, per the FaceSeed contract.
    static let seedEmbeddingLimit = 5

    /// Scans `assets`, streaming one event per photo as it finishes.
    ///
    /// A fixed window of `scanConcurrency` tasks — start that many, start one
    /// more each time one finishes — so a 2,500-photo run never holds 2,500
    /// decoded images at once. Cancelling the consuming task terminates the
    /// stream, which cancels the work behind it.
    static func events(
        assets: [PhotoAsset],
        photoLibrary: any PhotoLibraryService,
        detector: any GarmentDetector,
        faceIdentity: any FaceIdentityService,
        seed: FaceSeed?
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            // Detached rather than inherited: this must not end up on whatever
            // actor happened to ask for the stream.
            let work = Task.detached {
                await withTaskGroup(of: Event.self) { group in
                    var next = 0
                    var inFlight = 0

                    while true {
                        while inFlight < scanConcurrency, next < assets.count {
                            let asset = assets[next]
                            next += 1
                            inFlight += 1
                            group.addTask {
                                await scan(
                                    asset: asset,
                                    photoLibrary: photoLibrary,
                                    detector: detector,
                                    faceIdentity: faceIdentity,
                                    seed: seed
                                )
                            }
                        }

                        guard inFlight > 0, let event = await group.next() else { break }
                        inFlight -= 1

                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// One photo, start to finish. Never throws: a photo that won't load or
    /// won't analyse is simply not a candidate, and the scan moves on.
    /// Fingerprint and identity failures degrade the candidate (own group,
    /// unknown owner) rather than dropping it.
    @concurrent
    static func scan(
        asset: PhotoAsset,
        photoLibrary: any PhotoLibraryService,
        detector: any GarmentDetector,
        faceIdentity: any FaceIdentityService,
        seed: FaceSeed?
    ) async -> Event {
        var trace = PhotoTrace()
        guard !Task.isCancelled else {
            trace.drop = .cancelled
            return .scanned(asset, trace)
        }

        do {
            guard
                let image = try await photoLibrary.loadImage(
                    assetID: asset.id,
                    maxPixelSize: analysisPixelSize
                )
            else {
                trace.drop = .imageUnavailable
                return .scanned(asset, trace)
            }
            trace.didLoad = true

            let observation = try await detector.analyze(image)
            trace.didAnalyze = true
            if observation.isClothingCandidate {
                trace.clothingConfidence = observation.confidence
            }
            trace.largestPersonHeight = observation.people.map(\.height).max()

            let verdict = ScanPolicy().verdict(observation)
            guard verdict == .candidate else {
                trace.drop = verdict.dropReason
                return .scanned(asset, trace)
            }

            // `try?` on an optional-returning call flattens to one optional.
            let fingerprint = try? await detector.fingerprint(image)

            let faces = await embeddableFaces(
                assetID: asset.id,
                in: image,
                photoLibrary: photoLibrary,
                faceIdentity: seed == nil ? nil : faceIdentity
            )
            let owner = ownerIdentity(
                detection: faces.detection,
                didRetry: faces.didRetry,
                personFocus: largestPersonCenter(observation.people),
                seed: seed
            )
            trace.record(owner)

            return .found(
                Finding(
                    asset: asset,
                    thumbnail: downscaled(image, maxPixelSize: thumbnailPixelSize),
                    suggestedCategory: GarmentLabelMap.category(for: observation.labels),
                    confidence: observation.confidence,
                    aestheticsScore: observation.aestheticsScore,
                    fingerprint: fingerprint,
                    ownerStatus: owner.status,
                    focusPoint: owner.focus
                ),
                trace
            )
        } catch {
            trace.drop = .analysisFailed
            return .scanned(asset, trace)
        }
    }

    /// What an identity check concluded, and what it measured getting there.
    struct IdentityOutcome: Sendable {
        var status: ScanStore.OwnerStatus
        var focus: CGPoint?
        var faceSidesPx: [CGFloat] = []
        var bestCosine: Float?
        var didRetry = false
    }

    /// Every face in a photo that's big enough to embed, re-reading the photo
    /// larger when the analysis copy was too small.
    ///
    /// The retry isn't an edge case. At ``analysisPixelSize`` a standing figure's
    /// face lands under the embedding floor, so "faces seen, none usable" is the
    /// *normal* outcome for exactly the photos a wardrobe scan is made of. Left
    /// unhandled it silently turns identity off.
    ///
    /// A nil `faceIdentity` means identity is off for this scan; it reads as
    /// "no faces", which is what the caller wants and saves a second guard.
    @concurrent
    private static func embeddableFaces(
        assetID: String,
        in image: CGImage,
        photoLibrary: any PhotoLibraryService,
        faceIdentity: (any FaceIdentityService)?
    ) async -> (detection: FaceDetection, didRetry: Bool) {
        guard let faceIdentity, faceIdentity.isAvailable else { return (.none, false) }
        let first = await (try? faceIdentity.detectFaces(in: image)) ?? .none
        guard first.faces.isEmpty, !first.detectedSidesPx.isEmpty else {
            return (first, false)
        }

        let larger = try? await photoLibrary.loadImage(
            assetID: assetID,
            maxPixelSize: identityPixelSize
        )
        guard let larger, let retried = try? await faceIdentity.detectFaces(in: larger) else {
            return (first, true)
        }
        return (
            FaceDetection(
                faces: retried.faces,
                // Both passes' measurements matter: the first says why the retry
                // happened, the second says whether it was enough.
                detectedSidesPx: first.detectedSidesPx + retried.detectedSidesPx
            ),
            true
        )
    }

    /// Who a candidate photo belongs to, and where to aim the cutout.
    /// Embeddings live only inside this call — never stored on candidates.
    static func ownerIdentity(
        detection: FaceDetection,
        didRetry: Bool,
        personFocus: CGPoint?,
        seed: FaceSeed?
    ) -> IdentityOutcome {
        var outcome = IdentityOutcome(
            status: .unknown,
            focus: personFocus,
            faceSidesPx: detection.detectedSidesPx,
            didRetry: didRetry
        )
        guard let seed, !detection.faces.isEmpty else { return outcome }

        outcome.bestCosine = FaceMatcher.bestSimilarity(faces: detection.faces, seed: seed)
        guard let match = FaceMatcher.bestMatch(faces: detection.faces, seed: seed) else {
            outcome.status = .other
            return outcome
        }
        outcome.status = .you
        // Normalized, so the focus point is valid against the analysis image
        // even when the match came from the larger retry.
        outcome.focus = CGPoint(x: match.boundingBox.midX, y: match.boundingBox.midY)
        return outcome
    }

    static func largestPersonCenter(_ people: [CGRect]) -> CGPoint? {
        guard let largest = people.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }
        return CGPoint(x: largest.midX, y: largest.midY)
    }

    /// Decodes picked-photo data at a bounded size, honouring orientation.
    static func decodeImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
