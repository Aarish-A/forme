import CoreGraphics
import Foundation
import Testing
@testable import Forme

// MARK: - Core scan behaviour

@Suite("Scan store")
struct ScanStoreTests {
    @Test("Denied photo access stops before any scanning happens")
    func deniedAuthorizationStopsAtDenied() async throws {
        let store = try makeStore(library: Fix.library(Fix.clothingSpecs(2), authorization: .denied))

        await store.beginScan()

        #expect(store.phase == .denied)
        #expect(store.authorization == .denied)
    }

    @Test("A scan asks for access, skips junk, and streams candidates into review")
    func scanStreamsCandidatesAndAutoReviews() async throws {
        let library = try Fix.library(
            Fix.clothingSpecs(3, other: 2),
            extra: [PhotoAsset(id: "shot", creationDate: Fix.date(600), isScreenshot: true)],
            authorization: .notDetermined,
            grantsOnRequest: .limited
        )
        let store = makeStore(library: library, existing: ["asset-0"])

        await store.beginScan()

        #expect(store.authorization == .limited)
        #expect(store.phase == .review)
        // The screenshot and the already-imported photo never entered the scan.
        #expect(store.totalCount == 4)
        #expect(store.alreadyImportedCount == 1)
        // Outside `#expect`: the macro re-types the key path as a throwing
        // function and refuses to compile it.
        let allSelected = store.candidates.allSatisfy(\.isSelected)
        #expect(allSelected)
        #expect(store.selectedCount == 2)
        // Fingerprints default to nil, so every candidate is its own group.
        #expect(store.groups.count == 2)
        #expect(store.candidates.allSatisfy { $0.suggestedCategory == .shoes })
        #expect(store.candidates.map(\.id) == ["asset-1", "asset-2"])
        // The watermark covers every scanned photo, candidates or not.
        #expect(store.scannedThroughDate == Fix.date(-4 * 3600))
    }

    @Test("Candidates insert newest-photo-first even when completion order scrambles")
    func chronologicalInsertionDespiteCompletionOrder() async throws {
        let image = try #require(TestImageFactory.image(color: .blue, size: Fix.clothingEdge))
        let library = ReorderingPhotoLibrary(
            assets: [
                PhotoAsset(id: "newest", creationDate: Fix.date(7200)),
                PhotoAsset(id: "middle", creationDate: Fix.date(3600)),
                PhotoAsset(id: "oldest", creationDate: Fix.date(0))
            ],
            image: image,
            delayedID: "newest"
        )
        let store = makeStore(library: library)

        await store.beginScan()

        #expect(store.phase == .review)
        #expect(store.candidates.map(\.id) == ["newest", "middle", "oldest"])
    }

    @Test("A photo with nobody in it is never a candidate")
    func policyGatesOnPeopleAndConfidence() async throws {
        let detector = Fix.detector(analyze: { image in
            switch image.width {
            case 40: Fix.garment(confidence: 0.5)
            case 41: Fix.garment(confidence: 0.5, people: [])
            default: Fix.garment(people: [])
            }
        })
        let library = try Fix.library([
            Fix.spec("worn", 40, at: 0),
            Fix.spec("nobody", 41, at: -3600),
            Fix.spec("flat-lay", 42, at: -7200)
        ])
        let store = makeStore(library: library, detector: detector)

        await store.beginScan()

        // The flat-lay escape hatch is gone: no person, no candidate, however
        // confident the classifier. Of 24 flat-lay-framed photos in the real
        // corpus every one was food, a receipt or a postcard.
        #expect(Set(store.candidates.map(\.id)) == ["worn"])
    }

    @Test("Stopping early keeps what the scan found and still records the watermark")
    func earlyStopKeepsPartialCandidatesAndRecordsWatermark() async throws {
        let image = try #require(TestImageFactory.image(color: .blue, size: Fix.clothingEdge))
        let library = StallingPhotoLibrary(assetCount: 6, servesBeforeStalling: 1, image: image)
        let history = InMemoryScanHistoryService()
        let store = makeStore(library: library, history: history)

        let scan = Task { await store.beginScan() }
        await library.waitForStall()
        store.stopAndReview()
        await scan.value

        #expect(store.phase == .review)
        // Five photos never came back, so the scan cannot have finished.
        #expect(store.scannedCount < 6)
        #expect(store.candidates.count == store.scannedCount)
        let record = try #require(await history.load())
        #expect(record.oldestScannedDate != nil)
    }

    @Test("Near photos group, one member stays selected, the best one fronts the group")
    func groupingJoinsSplitsAndSelectsBest() async throws {
        let detector = Fix.detector(
            analyze: { image in Fix.garment(aesthetics: image.width == 31 ? 0.9 : 0.2) },
            fingerprint: { image in
                image.width == 33 ? ImageFingerprint(vector: [5, 0]) : ImageFingerprint(vector: [0, 0])
            }
        )
        let library = try Fix.library([
            Fix.spec("shoot-a", 30, at: 0),
            Fix.spec("shoot-b", 31, at: 60),
            // Same fingerprint but 30 minutes on: a different moment.
            Fix.spec("later", 32, at: 1860),
            // Same minute but a far fingerprint: a different outfit.
            Fix.spec("different", 33, at: 120)
        ])
        let store = makeStore(library: library, detector: detector)

        await store.beginScan()

        #expect(store.groups.count == 3)
        let pair = try #require(store.groups.first { !$0.others.isEmpty })
        #expect(pair.representative.id == "shoot-b")
        #expect(pair.others.map(\.id) == ["shoot-a"])
        #expect(pair.representative.isSelected)
        #expect(pair.others.allSatisfy { !$0.isSelected })
        #expect(store.selectedCount == 3)
        // Newest-first over groups, driven by the candidates' order.
        #expect(store.groups.map(\.representative.id) == ["later", "different", "shoot-b"])
    }

    @Test("The watermark keeps the oldest date across scans and always updates lastScanAt")
    func watermarkMergesAcrossScans() async throws {
        let history = InMemoryScanHistoryService()

        let first = try makeStore(
            library: Fix.library([Fix.spec("old", Fix.clothingEdge, at: -500_000)]),
            history: history
        )
        await first.beginScan()
        let firstRecord = try #require(await history.load())
        #expect(firstRecord.oldestScannedDate == Fix.date(-500_000))

        let second = try makeStore(
            library: Fix.library([Fix.spec("new", Fix.clothingEdge, at: 0)]),
            history: history
        )
        await second.beginScan()
        let secondRecord = try #require(await history.load())
        #expect(secondRecord.oldestScannedDate == Fix.date(-500_000))
        #expect(secondRecord.lastScanAt >= firstRecord.lastScanAt)
        #expect(second.scannedThroughDate == Fix.date(0))
    }

    @Test("Older mode only scans photos taken strictly before the watermark")
    func olderModeScansBeforeDate() async throws {
        let store = try makeStore(
            library: Fix.library(Fix.clothingSpecs(4)),
            mode: .older(before: Fix.date(-5400))
        )

        await store.beginScan()

        #expect(store.totalCount == 2)
        #expect(Set(store.candidates.map(\.id)) == ["asset-2", "asset-3"])
    }

    @Test("Saving goes oldest photo first and stamps capturedAt")
    func saveOrderIsOldestFirstWithCapturedAt() async throws {
        let wardrobe = InMemoryWardrobeService()
        let store = try makeStore(library: Fix.library(Fix.clothingSpecs(3)), wardrobe: wardrobe)
        await store.beginScan()

        await store.confirmSelection()

        #expect(store.phase == .finished(addedCount: 3))
        // `loadPieces` is newest-imported-first, so it mirrors the save order:
        // the oldest photo was added first and comes back last.
        let pieces = try await wardrobe.loadPieces()
        #expect(pieces.map(\.sourceAssetID) == ["asset-0", "asset-1", "asset-2"])
        #expect(pieces.map(\.capturedAt) == [Fix.date(0), Fix.date(-3600), Fix.date(-7200)])
    }

    @Test("Toggling round-trips, and confirming adds only the photos the user kept")
    func confirmSelectionAddsOnlySelected() async throws {
        let wardrobe = InMemoryWardrobeService()
        let store = try makeStore(library: Fix.library(Fix.clothingSpecs(3)), wardrobe: wardrobe)
        await store.beginScan()

        let discarded = try #require(store.candidates.first?.id)
        store.toggleSelection(discarded)
        #expect(store.selectedCount == 2)
        store.toggleSelection(discarded)
        #expect(store.selectedCount == 3)
        store.toggleSelection(discarded)

        await store.confirmSelection()

        #expect(store.phase == .finished(addedCount: 2))
        let pieces = try await wardrobe.loadPieces()
        #expect(pieces.count == 2)
        #expect(!pieces.compactMap(\.sourceAssetID).contains(discarded))
        let data = try await wardrobe.imageData(for: #require(pieces.first))
        #expect(data?.isEmpty == false)
    }

    @Test("Deselecting everything adds nothing and says so")
    func emptyConfirmAddsNothing() async throws {
        let store = try makeStore(library: Fix.library(Fix.clothingSpecs(2)))
        await store.beginScan()

        for candidate in store.candidates {
            store.toggleSelection(candidate.id)
        }
        await store.confirmSelection()

        #expect(store.phase == .finished(addedCount: 0))
    }
}

// MARK: - Identity behaviour

@Suite("Scan store identity")
struct ScanStoreIdentityTests {
    private struct IdentityParts {
        var library: InMemoryPhotoLibraryService
        var detector: StubGarmentDetector
        var identity: StubFaceIdentityService
        var seedService: InMemoryFaceSeedService
    }

    /// Three photos: "you" (your face), "mirror" (faceless, same shoot as
    /// "you"), and "stranger" (someone else's face, its own moment) — plus a
    /// seed service already holding your face.
    private func makeIdentityParts() async throws -> IdentityParts {
        let detector = Fix.detector(
            analyze: { _ in Fix.garment() },
            fingerprint: { image in
                switch image.width {
                case 40: ImageFingerprint(vector: [0, 0])
                case 42: ImageFingerprint(vector: [0.1, 0])
                default: ImageFingerprint(vector: [3, 0])
                }
            }
        )
        let identity = Fix.identity(faces: { image in
            switch image.width {
            case 40: [Fix.face(Fix.owner)]
            case 41: [Fix.face(Fix.stranger)]
            default: []
            }
        })
        let library = try Fix.library([
            Fix.spec("you", 40, at: 0),
            Fix.spec("mirror", 42, at: 60),
            Fix.spec("stranger", 41, at: 1800)
        ])
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [Fix.owner], createdAt: Fix.date(0)))
        return IdentityParts(library: library, detector: detector, identity: identity, seedService: seedService)
    }

    @Test("With a seed, other people's groups hide and your face vouches for its moment")
    func identityHidesOthersAndVouchesWithinGroups() async throws {
        let parts = try await makeIdentityParts()
        let store = makeStore(
            library: parts.library,
            detector: parts.detector,
            faceIdentity: parts.identity,
            faceSeed: parts.seedService
        )

        // A stored seed skips identity setup entirely.
        await store.beginScan()

        #expect(store.phase == .review)
        let byID = Dictionary(uniqueKeysWithValues: store.candidates.map { ($0.id, $0) })
        #expect(byID["you"]?.ownerStatus == .you)
        #expect(byID["mirror"]?.ownerStatus == .unknown)
        #expect(byID["stranger"]?.ownerStatus == .other)

        // The faceless mirror shot shares a moment with "you", so it's vouched.
        #expect(byID["mirror"]?.groupID == byID["you"]?.groupID)
        #expect(store.groups.count == 1)
        #expect(store.hiddenOtherCount == 1)
        #expect(try #require(store.groups.first).isOwner)

        // The stranger's group is deselected as well as hidden, and exactly
        // one of the vouched pair stays selected.
        #expect(byID["stranger"]?.isSelected == false)
        #expect(store.selectedCount == 1)
    }

    @Test("Show Others reveals hidden groups deselected, and a tap re-selects for saving")
    func showOthersRevealsAndReselectionSaves() async throws {
        let parts = try await makeIdentityParts()
        let wardrobe = InMemoryWardrobeService()
        let store = makeStore(
            library: parts.library,
            detector: parts.detector,
            wardrobe: wardrobe,
            faceIdentity: parts.identity,
            faceSeed: parts.seedService
        )
        await store.beginScan()
        #expect(store.groups.count == 1)

        store.toggleShowOthers()

        #expect(store.groups.count == 2)
        #expect(store.candidates.first { $0.id == "stranger" }?.isSelected == false)

        store.toggleSelection("stranger")
        #expect(store.selectedCount == 2)

        await store.confirmSelection()

        #expect(store.phase == .finished(addedCount: 2))
        let pieces = try await wardrobe.loadPieces()
        // "mirror" is the vouched pair's newest member, so it won selection.
        #expect(Set(pieces.compactMap(\.sourceAssetID)) == ["mirror", "stranger"])
    }

    @Test("Skipping identity scans with every candidate unknown and nothing hidden")
    func skipIdentityScansAllUnknown() async throws {
        let identity = Fix.identity(faces: { _ in [Fix.face(Fix.stranger)] })
        let store = try makeStore(library: Fix.library(Fix.clothingSpecs(2)), faceIdentity: identity)

        // No stored seed and no selfies: setup parks with nothing to propose.
        await store.beginScan()
        #expect(store.phase == .identitySetup)
        #expect(store.proposedFaceCrop == nil)
        #expect(!store.isSearchingSelfies)

        await store.skipIdentityThisScan()

        #expect(store.phase == .review)
        #expect(store.candidates.count == 2)
        #expect(store.candidates.allSatisfy { $0.ownerStatus == .unknown })
        #expect(store.hiddenOtherCount == 0)
    }

    @Test("Identity setup proposes the dominant selfie face and saves the seed on confirm")
    func identitySetupProposesDominantSelfieFace() async throws {
        let identity = Fix.identity(faces: { image in
            switch image.width {
            case 50: [Fix.face(Fix.owner, quality: 0.9)]
            case 51: [Fix.face(Fix.nearOwner, quality: 0.3)]
            case 52: [Fix.face(Fix.stranger, quality: 0.8)]
            case Fix.clothingEdge: [Fix.face(Fix.owner)]
            default: []
            }
        })
        let library = try Fix.library(
            [Fix.spec("main-0", Fix.clothingEdge, at: 0)],
            selfies: [
                Fix.spec("selfie-0", 50, at: -60),
                Fix.spec("selfie-1", 51, at: -120),
                Fix.spec("selfie-2", 52, at: -180)
            ]
        )
        let seedService = InMemoryFaceSeedService()
        let store = makeStore(library: library, faceIdentity: identity, faceSeed: seedService)

        await store.beginScan()

        #expect(store.phase == .identitySetup)
        #expect(!store.isSearchingSelfies)
        #expect(store.proposedFaceCrop != nil)

        await store.confirmProposedFace()

        // Your face matched itself and its near twin; the stranger stayed out.
        let seed = try #require(await seedService.load())
        #expect(seed.embeddings.count == 2)
        #expect((seed.embeddings.first?.similarity(to: Fix.owner) ?? 0) > 0.99)
        #expect(store.seedIsSet)

        // The scan then ran with the fresh seed in force.
        #expect(store.phase == .review)
        #expect(store.candidates.first?.ownerStatus == .you)
    }

    @Test("A faceless photo is shown but not pre-selected — absence of evidence is not consent")
    func soloUnknownStaysVisibleButUnselected() async throws {
        // Someone photographed from behind: a person, a torso in shot, and no
        // face to identify. `.unknown` is absence of evidence, so a seed must
        // not hide it — but it must not pre-approve it either. On a real
        // library 41% of candidates land here, and pre-checking them all is
        // what put a stranger's photoshoot one tap from the wardrobe.
        let detector = Fix.detector(analyze: { _ in Fix.garment() })
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [Fix.owner], createdAt: Fix.date(0)))
        let store = try makeStore(
            library: Fix.library([Fix.spec("back-turned", 40, at: 0)]),
            detector: detector,
            faceIdentity: Fix.identity(),
            faceSeed: seedService
        )

        await store.beginScan()

        #expect(store.phase == .review)
        #expect(store.candidates.first?.ownerStatus == .unknown)
        #expect(store.groups.count == 1)
        #expect(store.hiddenOtherCount == 0)
        #expect(store.groups.first?.confidence == .unsure)
        #expect(store.candidates.first?.isSelected == false)
        #expect(store.selectedCount == 0)

        // And it's one tap away: "Keep These" on the Not sure section.
        try store.keepAll(inGroups: [#require(store.groups.first).id])
        #expect(store.selectedCount == 1)
    }

    @Test("The hidden count speaks in photos, not groups")
    func hiddenCountSumsGroupMembers() async throws {
        // Two frames of the same stranger in one moment: one hidden group,
        // but the banner's promise is photos, so the count must be two.
        let detector = Fix.detector(
            analyze: { _ in Fix.garment() },
            fingerprint: { _ in ImageFingerprint(vector: [0, 0]) }
        )
        let identity = Fix.identity(faces: { _ in [Fix.face(Fix.stranger)] })
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [Fix.owner], createdAt: Fix.date(0)))
        let store = try makeStore(
            library: Fix.library([Fix.spec("stranger-a", 40, at: 0), Fix.spec("stranger-b", 41, at: 60)]),
            detector: detector,
            faceIdentity: identity,
            faceSeed: seedService
        )

        await store.beginScan()

        #expect(store.groups.isEmpty)
        #expect(store.hiddenOtherCount == 2)
    }

    @Test("A seeded scan degrades to identity-off when the face model dies mid-scan")
    func seededScanSurvivesModelDeath() async throws {
        // The real model loads lazily inside the first `faces(in:)` call, so
        // `isAvailable` can flip to false only after the scan has begun.
        let seedService = InMemoryFaceSeedService()
        await seedService.save(FaceSeed(embeddings: [Fix.owner], createdAt: Fix.date(0)))
        let store = try ScanStore(
            photoLibrary: Fix.library(Fix.clothingSpecs(2)),
            detector: Fix.detector(),
            wardrobe: InMemoryWardrobeService(),
            history: InMemoryScanHistoryService(),
            faceIdentity: DyingFaceIdentityService(),
            faceSeed: seedService
        )

        await store.beginScan()

        #expect(store.phase == .review)
        // Identity dropped out rather than filtering on a verdict it can no
        // longer reach: nothing hidden, everything still selected.
        #expect(!store.identityActive)
        #expect(store.groups.count == 2)
        #expect(store.hiddenOtherCount == 0)
        let allSelected = store.candidates.allSatisfy(\.isSelected)
        #expect(allSelected)
    }
}
