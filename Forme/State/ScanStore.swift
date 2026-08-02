import CoreGraphics
import Foundation
import OSLog

/// Drives the photo-library scan: asking for access, setting up face identity,
/// running the scan, holding the grouped review, and saving what the user kept.
///
/// The split that matters is between this type and ``ScanPipeline``. Decoding
/// thousands of photos and running Vision over them must never touch the main
/// actor; the state SwiftUI observes must only ever change there. So the
/// pipeline runs off main and reports back through an `AsyncStream` of small
/// events that this store drains on main, one at a time. That drain is the
/// scan's single serialized point, which is why dedup grouping lives there —
/// no locks, no races, one candidate considered at a time.
@Observable
final class ScanStore {
    /// Which slice of the library this scan covers. `.older` continues past a
    /// previous scan's watermark instead of re-reading the newest photos.
    nonisolated enum ScanMode: Equatable {
        case newest
        case older(before: Date)
    }

    /// Where the user is in the flow. The view switches on this and nothing else.
    nonisolated enum Phase: Equatable {
        case primer
        case requestingAccess
        case denied
        case identitySetup
        case scanning
        case review
        case saving
        case finished(addedCount: Int)
    }

    /// What face identity concluded about a candidate. `.unknown` covers "no
    /// faces found" and "identity off" alike — absence of evidence, not a verdict.
    nonisolated enum OwnerStatus: Equatable {
        case you
        case other
        case unknown
    }

    // MARK: - Tuning constants (single definitions; ScanPolicy holds the rest)

    /// How many photos one scan will look at. An MVP tradeoff, not a limit
    /// anyone asked for: the newest few thousand photos hold the clothes
    /// someone actually wears now, and "Scan Older Photos" continues past it.
    nonisolated static let assetLimit = 2500

    /// Widest time gap a photo can sit outside a group's date range and still
    /// join it. Ten minutes is one "moment" — a photoshoot, a fitting-room try-on.
    nonisolated static let groupTimeGap: TimeInterval = 600

    /// Feature-print distance under which two photos count as the same shot.
    /// Not comparable across Vision revisions; prints are computed per scan and
    /// never cached, so no versioning is needed yet.
    nonisolated static let fingerprintDistanceThreshold: Float = 0.35

    // MARK: - Published state

    private(set) var phase: Phase = .primer
    private(set) var authorization: PhotoLibraryAuthorization = .notDetermined
    private(set) var scannedCount = 0
    private(set) var totalCount = 0

    /// Newest photo first, inserted chronologically no matter what order the
    /// pipeline finishes in. Render `groups`, not this — this is the raw pool.
    private(set) var candidates: [Candidate] = []

    /// What the last scan measured about itself. Also written to disk in DEBUG
    /// builds — see ``DiagnosticsStore`` and `make diag`. Kept in memory as
    /// well so tests can assert on it without touching the filesystem.
    private(set) var lastReport: ScanReport?

    /// Reveals the groups the identity filter hid. Set via `toggleShowOthers()`.
    private(set) var showOthers = false

    /// Save progress, so the saving screen can say "Adding 3 of 12".
    private(set) var savedCount = 0
    private(set) var savingTotal = 0

    /// How many fetched assets were skipped because they're already in the
    /// wardrobe. Lets the empty review state say "you're up to date".
    private(set) var alreadyImportedCount = 0

    /// Oldest `creationDate` this scan actually looked at — the watermark.
    private(set) var scannedThroughDate: Date?

    /// Whether a face seed is stored on this device.
    private(set) var seedIsSet = false

    private(set) var isSearchingSelfies = false

    /// Face crop proposed during `.identitySetup`; nil means nothing to propose
    /// and the UI offers pick-a-photo / skip instead.
    private(set) var proposedFaceCrop: CGImage?

    private(set) var errorMessage: String?

    /// Whether owner filtering is in force for the current candidates: a seed
    /// is active and the face model loaded. Everything is "yours" when off.
    var identityActive: Bool {
        activeSeed != nil
    }

    /// Whether this run is a "Scan Older Photos" continuation past a previous
    /// watermark. The empty review reads it so it never blames "recent" photos
    /// a scan that only looked backwards never saw.
    var isOlderScan: Bool {
        if case .older = mode {
            return true
        }
        return false
    }

    // MARK: - Dependencies & private scan state

    private let photoLibrary: any PhotoLibraryService
    private let detector: any GarmentDetector
    private let wardrobe: any WardrobeService
    private let history: any ScanHistoryService
    private let faceIdentity: any FaceIdentityService
    private let faceSeed: any FaceSeedService
    /// Photos already in the wardrobe, skipped so a rescan doesn't re-ask.
    private let existingSourceAssetIDs: Set<String>
    private let mode: ScanMode

    /// The task draining the scan stream, held so an early "Review" or a
    /// dismissed sheet can tear the pipeline down behind it.
    private var scanTask: Task<Void, Never>?

    /// The seed in force for THIS scan; nil = identity off (skipped, no seed,
    /// or the model failed to load).
    private var activeSeed: FaceSeed?

    /// Embeddings backing `proposedFaceCrop`, saved on `confirmProposedFace()`.
    private var pendingSeedEmbeddings: [FaceEmbedding] = []

    /// Date span per group id, for the time half of the join test.
    private var groupSpans: [Int: DateInterval] = [:]

    /// Best member so far per group id — the fingerprint anchor new candidates
    /// are compared against. Its `isSelected` may be stale; only ranking fields
    /// and the fingerprint are read.
    private var groupReps: [Int: Candidate] = [:]

    private var nextGroupID = 0

    /// Accumulates this run's measurements. Nil outside a scan.
    private var reportBuilder: ScanReportBuilder?

    /// Not injected: it has one implementation, writes only in DEBUG builds, and
    /// tests assert on ``lastReport`` rather than on the filesystem — so a
    /// protocol seam here would be indirection with nothing behind it.
    private let diagnostics = DiagnosticsStore()

    init(
        photoLibrary: any PhotoLibraryService,
        detector: any GarmentDetector,
        wardrobe: any WardrobeService,
        history: any ScanHistoryService,
        faceIdentity: any FaceIdentityService,
        faceSeed: any FaceSeedService,
        existingSourceAssetIDs: Set<String> = [],
        mode: ScanMode = .newest
    ) {
        self.photoLibrary = photoLibrary
        self.detector = detector
        self.wardrobe = wardrobe
        self.history = history
        self.faceIdentity = faceIdentity
        self.faceSeed = faceSeed
        self.existingSourceAssetIDs = existingSourceAssetIDs
        self.mode = mode

        // The primer needs `seedIsSet` before `beginScan` runs, so it can show
        // "Not you?". Best-effort; `beginScan` reloads authoritatively.
        Task { [weak self] in
            let seed = await faceSeed.load()
            self?.seedIsSet = seed != nil
        }
    }
}

// MARK: - Flow

extension ScanStore {
    /// Primer → permission → (identity setup) → scan. Returns when the scan
    /// has finished, been stopped, or is parked in `.identitySetup` waiting on
    /// the user — the identity methods below resume the flow from there.
    func beginScan() async {
        // Guard on phase, not `scanTask`: the task handle isn't assigned until
        // deep inside `runScan()`, so a double-tap would pass a task-based
        // guard and start two pipelines. `.denied` re-enters so the user can
        // retry after granting access in Settings.
        guard phase == .primer || phase == .denied else { return }

        errorMessage = nil
        phase = .requestingAccess

        var status = photoLibrary.currentAuthorization()
        if status == .notDetermined {
            status = await photoLibrary.requestAuthorization()
        }
        authorization = status

        guard status == .full || status == .limited else {
            phase = .denied
            Log.feature.info("Photo library access not granted; scan cannot start")
            return
        }

        let seed = await faceSeed.load()
        seedIsSet = seed != nil

        guard faceIdentity.isAvailable else {
            activeSeed = nil
            await runScan()
            return
        }

        if let seed {
            activeSeed = seed
            await runScan()
        } else {
            await prepareIdentitySetup()
        }
    }

    /// The user tapped "Review", or the scan ran out of photos. Either way the
    /// candidates found so far are what they get.
    func stopAndReview() {
        scanTask?.cancel()
        guard phase == .scanning || phase == .requestingAccess else { return }
        phase = .review
    }

    func toggleSelection(_ id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].isSelected.toggle()
    }

    /// Show or hide the groups the identity filter set aside. Revealing never
    /// re-selects — members stay deselected until tapped.
    func toggleShowOthers() {
        showOthers.toggle()
    }

    /// Turns the kept candidates into wardrobe pieces: selected members of
    /// visible groups only, oldest photo first so the wardrobe's newest-first
    /// order matches when the clothes were actually worn.
    func confirmSelection() async {
        let selected = groups
            .flatMap { [$0.representative] + $0.others }
            .filter(\.isSelected)
            .sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
        errorMessage = nil

        guard !selected.isEmpty else {
            phase = .finished(addedCount: 0)
            await persistWatermark()
            return
        }

        savingTotal = selected.count
        savedCount = 0
        phase = .saving
        var added = 0

        for candidate in selected {
            defer { savedCount += 1 }
            let png = await ScanPipeline.pieceImagePNG(
                assetID: candidate.id,
                fallback: candidate.thumbnail,
                focus: candidate.focusPoint,
                photoLibrary: photoLibrary,
                detector: detector
            )
            guard let png else { continue }

            do {
                try await wardrobe.addPiece(
                    imagePNG: png,
                    category: candidate.suggestedCategory,
                    sourceAssetID: candidate.id,
                    capturedAt: candidate.creationDate
                )
                added += 1
            } catch {
                Log.feature.error("Saving a scanned piece failed")
            }
        }

        if added < selected.count {
            errorMessage = added == 0
                ? "We couldn't save those photos. Give it another go in a moment."
                : "Some photos couldn't be saved. The rest are in your wardrobe."
        }

        Log.feature.info("Scan added \(added) of \(selected.count) selected photos")
        phase = .finished(addedCount: added)
        reportBuilder?.recordSaved(added)
        await writeReport()
        await persistWatermark()
    }

    /// Abandons the scan without deciding anything — the sheet is going away.
    func cancelScanning() {
        scanTask?.cancel()
        scanTask = nil
    }
}

// MARK: - Identity setup

extension ScanStore {
    /// "Yes, That's Me": persists the proposed face as the seed and scans.
    func confirmProposedFace() async {
        guard phase == .identitySetup, !pendingSeedEmbeddings.isEmpty else { return }
        let embeddings = Array(pendingSeedEmbeddings.prefix(ScanPipeline.seedEmbeddingLimit))
        await activateSeed(FaceSeed(embeddings: embeddings, createdAt: Date()))
    }

    /// "Choose a Photo of Me": seeds identity from a picked photo's largest face.
    func useSeedPhoto(_ imageData: Data) async {
        guard phase == .identitySetup else { return }
        errorMessage = nil

        guard let embedding = await ScanPipeline.seedEmbedding(fromPhoto: imageData, faceIdentity: faceIdentity) else {
            errorMessage = "We couldn't find a face in that photo. Try one where your face is clear."
            return
        }
        await activateSeed(FaceSeed(embeddings: [embedding], createdAt: Date()))
    }

    /// Scans with identity off for this run only; nothing is stored.
    func skipIdentityThisScan() async {
        guard phase == .identitySetup else { return }
        activeSeed = nil
        await runScan()
    }

    /// Deletes the stored seed. Callable from the primer's "Not you?".
    func resetIdentity() async {
        await faceSeed.clear()
        activeSeed = nil
        seedIsSet = false
        proposedFaceCrop = nil
        pendingSeedEmbeddings = []
    }

    /// Searches the Selfies album for the dominant face and proposes it.
    private func prepareIdentitySetup() async {
        phase = .identitySetup
        isSearchingSelfies = true
        proposedFaceCrop = nil
        pendingSeedEmbeddings = []

        let proposal = await ScanPipeline.proposeSeed(photoLibrary: photoLibrary, faceIdentity: faceIdentity)

        isSearchingSelfies = false
        // The user may have skipped mid-search; don't clobber a running scan.
        guard phase == .identitySetup else { return }
        proposedFaceCrop = proposal.faceCrop
        pendingSeedEmbeddings = proposal.embeddings
    }

    private func activateSeed(_ seed: FaceSeed) async {
        await faceSeed.save(seed)
        activeSeed = seed
        seedIsSet = true
        await runScan()
    }
}

// MARK: - Scanning & grouping

extension ScanStore {
    private func runScan() async {
        proposedFaceCrop = nil

        var modeBefore: Date?
        if case let .older(before) = mode {
            modeBefore = before
        }
        let assets = await photoLibrary.imageAssets(before: modeBefore, limit: Self.assetLimit)

        // Screenshots are dropped twice on purpose: the PhotoKit predicate is
        // documented-flaky, so the flag filter here is the belt to its braces.
        let photos = assets.filter { !$0.isScreenshot }
        let toScan = photos.filter { !existingSourceAssetIDs.contains($0.id) }
        alreadyImportedCount = photos.count - toScan.count

        candidates = []
        groupSpans = [:]
        groupReps = [:]
        nextGroupID = 0
        showOthers = false
        scannedCount = 0
        scannedThroughDate = nil
        totalCount = toScan.count
        phase = .scanning
        reportBuilder = ScanReportBuilder(
            policy: ScanPolicy(),
            fetched: toScan.count,
            identityActive: activeSeed != nil,
            startedAt: Date(),
            runID: DiagnosticsStore.makeRunID()
        )

        guard !toScan.isEmpty else {
            phase = .review
            await persistWatermark()
            return
        }

        let events = ScanPipeline.events(
            assets: toScan,
            photoLibrary: photoLibrary,
            detector: detector,
            faceIdentity: faceIdentity,
            seed: activeSeed
        )
        let task = Task { [self] in
            for await event in events {
                apply(event)
            }
        }
        scanTask = task
        await task.value

        // A cleared handle means `cancelScanning()` abandoned this run, so the
        // phase it left behind is the one that should stand — and an abandoned
        // scan records no watermark.
        guard scanTask == task else { return }
        scanTask = nil

        // Local copies: the logger's autoclosure would otherwise demand an
        // explicit `self.` that the format hook strips right back out.
        let scanned = scannedCount
        let found = candidates.count
        Log.feature.info("Scan finished: \(scanned) photos, \(found) candidates")
        if phase == .scanning {
            phase = .review
        }
        await writeReport()
        await persistWatermark()
    }

    /// Records how far back scanning has ever reached. Merge keeps the OLDER
    /// date across `.newest` and `.older` runs; `lastScanAt` always updates.
    private func persistWatermark() async {
        let existing = await history.load()
        let oldest = [existing?.oldestScannedDate, scannedThroughDate]
            .compactMap(\.self)
            .min()
        await history.save(ScanRecord(oldestScannedDate: oldest, lastScanAt: Date()))
    }

    /// The serialized event drain: progress, the watermark, and grouping all
    /// advance here, one event at a time on the main actor.
    private func apply(_ event: ScanPipeline.Event) {
        // The face model loads lazily inside the pipeline's first `faces(in:)`
        // call, so a seeded scan can discover mid-run that the model is dead.
        // Left alone, every candidate would come back `.unknown` while the
        // filter stayed armed; identity degrades to off instead, and the
        // selection already made under it is re-settled.
        if activeSeed != nil, !faceIdentity.isAvailable {
            activeSeed = nil
            for groupID in Set(candidates.map(\.groupID)) {
                normalizeSelection(inGroup: groupID)
            }
        }

        scannedCount += 1
        if let date = event.asset.creationDate, date < (scannedThroughDate ?? .distantFuture) {
            scannedThroughDate = date
        }

        switch event {
        case let .scanned(_, trace):
            reportBuilder?.record(trace, wasCandidate: false, ownerStatus: nil)
        case let .found(finding, trace):
            reportBuilder?.record(trace, wasCandidate: true, ownerStatus: finding.ownerStatus)
            admit(finding)
        }
    }

    /// Finalises this run's report and, in DEBUG builds, puts it on disk.
    ///
    /// Called twice: once when scanning ends, so a scan the user abandons at the
    /// review screen still leaves measurements behind, and again after saving so
    /// the saved count is real. Both writes carry the same run id, so the second
    /// replaces the first rather than accumulating.
    private func writeReport() async {
        guard var builder = reportBuilder else { return }
        // Every group, not just the visible ones — counting only what survived
        // hiding made the hidden set invisible to the report as well as to the
        // user, which is the one place it most needs to be legible.
        let byGroup = Dictionary(grouping: candidates, by: \.groupID)
        let visible = groups
        builder.recordReview(
            groups: byGroup.count,
            groupsWithYou: byGroup.values.count { members in
                members.contains { $0.ownerStatus == .you }
            },
            shown: visible.reduce(0) { $0 + 1 + $1.others.count }
        )
        reportBuilder = builder

        let report = builder.report(wasCancelled: scanTask != nil)
        lastReport = report

        // Locals: the logger's autoclosure would demand an explicit `self.`
        // that the format hook strips straight back out.
        let candidateCount = report.funnel.candidates
        let groupCount = report.funnel.groups
        let warnings = report.warnings.count
        let seconds = report.durationMS / 1000
        Log.scan.notice(
            "candidates=\(candidateCount) groups=\(groupCount) warnings=\(warnings) seconds=\(seconds)"
        )
        for warning in report.warnings {
            let code = warning.code
            let subject = warning.subject
            Log.scan.warning("\(code): \(subject)")
        }
        await diagnostics.write(report)
    }

    private func admit(_ finding: ScanPipeline.Finding) {
        var candidate = Candidate(
            id: finding.asset.id,
            thumbnail: finding.thumbnail,
            suggestedCategory: finding.suggestedCategory,
            isSelected: true,
            creationDate: finding.asset.creationDate,
            confidence: finding.confidence,
            aestheticsScore: finding.aestheticsScore,
            fingerprint: finding.fingerprint,
            ownerStatus: finding.ownerStatus,
            focusPoint: finding.focusPoint
        )

        candidate.groupID = resolvedGroupID(for: candidate)
        insertChronologically(candidate)
        updateGroupState(with: candidate)
        normalizeSelection(inGroup: candidate.groupID)
    }

    /// The group a candidate belongs to: a time-and-fingerprint match when the
    /// evidence exists, otherwise a fresh group — no date or no fingerprint
    /// means no evidence of duplication, and a false split is cheaper than a
    /// false merge.
    private func resolvedGroupID(for candidate: Candidate) -> Int {
        guard let date = candidate.creationDate, let fingerprint = candidate.fingerprint else {
            return newGroupID()
        }
        return matchedGroupID(date: date, fingerprint: fingerprint) ?? newGroupID()
    }

    private func newGroupID() -> Int {
        defer { nextGroupID += 1 }
        return nextGroupID
    }

    /// A candidate joins the closest group whose date range it sits within
    /// `groupTimeGap` of AND whose representative's fingerprint is nearer than
    /// `fingerprintDistanceThreshold`. Both, not either: same-looking photos a
    /// week apart are different wears; different outfits a minute apart are
    /// different pieces.
    private func matchedGroupID(date: Date, fingerprint: ImageFingerprint) -> Int? {
        var best: (id: Int, distance: Float)?
        for (groupID, span) in groupSpans {
            guard
                date >= span.start.addingTimeInterval(-Self.groupTimeGap),
                date <= span.end.addingTimeInterval(Self.groupTimeGap),
                let anchor = groupReps[groupID]?.fingerprint
            else { continue }

            let distance = fingerprint.distance(to: anchor)
            guard
                distance < Self.fingerprintDistanceThreshold,
                distance < (best?.distance ?? .infinity)
            else { continue }
            best = (groupID, distance)
        }
        return best?.id
    }

    private func updateGroupState(with candidate: Candidate) {
        let groupID = candidate.groupID
        if let date = candidate.creationDate {
            if let span = groupSpans[groupID] {
                groupSpans[groupID] = DateInterval(
                    start: min(span.start, date),
                    end: max(span.end, date)
                )
            } else {
                groupSpans[groupID] = DateInterval(start: date, end: date)
            }
        }

        if let current = groupReps[groupID], !Self.ranksHigher(candidate, over: current) {
            return
        }
        groupReps[groupID] = candidate
    }

    /// Re-settles selection after a group changes: non-owner groups lose all
    /// selection (they're hidden), owner groups keep exactly one member — the
    /// best by the representative ordering. Runs only while events arrive, so
    /// it never fights the user's own review-time taps.
    private func normalizeSelection(inGroup groupID: Int) {
        let indices = candidates.indices.filter { candidates[$0].groupID == groupID }
        guard var bestIndex = indices.first else { return }

        // Only positive evidence pre-selects. A group where identity never got
        // a readable face is shown but left unchecked: 41% of a real scan lands
        // there, and pre-approving it is what put a stranger's photoshoot — and
        // a pan of paella — one tap from the user's wardrobe. With identity off
        // there is no evidence to have, so the old behaviour stands.
        let confidence = identityActive
            ? Self.confidence(indices.map { candidates[$0].ownerStatus })
            : .you
        guard confidence == .you else {
            for index in indices {
                candidates[index].isSelected = false
            }
            return
        }
        selectBest(among: indices, startingAt: bestIndex)
    }

    /// Keeps one photo from each of these groups — the "Keep These" on a review
    /// section. One per group, exactly like pre-selection, so the number on the
    /// button means the same thing however a photo got there.
    func keepAll(inGroups groupIDs: Set<Int>) {
        for groupID in groupIDs {
            let indices = candidates.indices.filter { candidates[$0].groupID == groupID }
            guard let first = indices.first else { continue }
            selectBest(among: indices, startingAt: first)
        }
    }

    private func selectBest(among indices: [Int], startingAt seed: Int) {
        var bestIndex = seed
        for index in indices where Self.ranksHigher(candidates[index], over: candidates[bestIndex]) {
            bestIndex = index
        }
        for index in indices {
            candidates[index].isSelected = index == bestIndex
        }
    }

    /// Newest photo first, wherever the pipeline happened to finish this one.
    /// Dateless photos sink to the end rather than floating unpredictably.
    private func insertChronologically(_ candidate: Candidate) {
        let date = candidate.creationDate ?? .distantPast
        let index = candidates.firstIndex { ($0.creationDate ?? .distantPast) < date } ?? candidates.endIndex
        candidates.insert(candidate, at: index)
    }
}
