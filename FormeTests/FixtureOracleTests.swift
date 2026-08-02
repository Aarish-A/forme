import CoreGraphics
import Foundation
import OSLog
import Testing
@testable import Forme

/// The scan's decision logic, measured against 490 real labelled photos.
///
/// This is the fast half of the harness. It runs no Vision and loads no image:
/// the labels state what is *true* about each photo, this synthesises the facts a
/// perfect detector would report, and the real ``ScanPolicy`` and grouping code
/// decide. So a failure here is a bug in our logic, never in Vision's accuracy —
/// which is a separate question, and the only one that needs a device.
///
/// The value is that it turns "the user says the result is wrong" into a number
/// that moves when the code changes, in under a second, without anybody's phone.
@Suite("Fixture oracle", .enabled(if: FixtureCorpus.isAvailable))
nonisolated struct FixtureOracleTests {
    // MARK: - The oracle

    /// Person-box height as a fraction of frame, by how the photo is framed.
    ///
    /// `face_closeup` deliberately sits *highest*. A face filling the frame
    /// implies a huge person box, which is precisely why box height cannot
    /// separate a useful outfit photo from a useless selfie — the current gate's
    /// central flaw, reproduced here rather than papered over.
    private static func personHeight(for shot: String) -> CGFloat? {
        switch shot {
        case "full_body": 0.90
        case "three_quarter": 0.72
        case "upper_body": 0.60
        case "face_closeup": 0.95
        case "distant": 0.12
        default: nil
        }
    }

    /// Clothing identifiers Vision can actually return, verified at runtime
    /// against `ClassifyImageRequest.supportedIdentifiers`.
    private static let nameable: Set = [
        "jacket", "sneaker", "sneakers", "jeans", "polo", "hoodie", "suit",
        "boot", "boots", "scarf", "sandal", "sandals", "swimsuit", "gown"
    ]

    /// What Vision would report for this photo, modelled honestly.
    ///
    /// The generic `clothing` identifier fires for any dressed human, which is
    /// why the real scan produced 898 confidence samples with a flat mean of
    /// 0.42 and no separation. A specific garment only scores higher when Vision
    /// has a word for it — true of 16.7% of this wardrobe. Modelling the broken
    /// vocabulary is the point: a fix has to beat *this*, not an idealised
    /// classifier.
    private static func observation(for photo: FixtureCorpus.Photo) -> GarmentObservation {
        let boxes: [CGRect] = {
            guard photo.people > 0, let height = personHeight(for: photo.shot) else { return [] }
            let width = min(0.9, height * 0.55)
            return (0 ..< photo.people).map { index in
                CGRect(x: 0.05 + Double(index) * 0.06, y: (1 - height) / 2, width: width, height: height)
            }
        }()

        let hasNameableGarment = photo.garments.contains { garment in
            garment.split(separator: " ").contains { nameable.contains(String($0)) }
        }
        let confidence: Float = if hasNameableGarment {
            0.85
        } else if !boxes.isEmpty {
            0.5 // the generic `clothing` label, which says only "a dressed human"
        } else {
            0.05
        }

        // What pose would report. `upper_body` and better show a torso;
        // a face-filling selfie shows shoulders at most; a distant figure may
        // resolve fully but is rejected on size, not framing.
        let framing = switch photo.shot {
        case "full_body": BodyFraming(hasShoulders: true, hasHips: true, hasKnees: true)
        case "three_quarter": BodyFraming(hasShoulders: true, hasHips: true, hasKnees: true)
        case "upper_body": BodyFraming(hasShoulders: true, hasHips: true)
        case "face_closeup": BodyFraming(hasShoulders: true)
        case "distant": BodyFraming(hasShoulders: true, hasHips: true, hasKnees: true)
        default: BodyFraming.none
        }

        return GarmentObservation(
            isClothingCandidate: confidence > 0.1,
            confidence: confidence,
            labels: [],
            people: boxes,
            aestheticsScore: nil,
            isUtility: photo.shot == "screenshot_or_graphic",
            framing: framing
        )
    }

    private static func ownerStatus(for photo: FixtureCorpus.Photo) -> ScanStore.OwnerStatus {
        switch photo.aarish {
        case "yes": .you
        case "no": photo.people > 0 ? .other : .unknown
        default: .unknown
        }
    }

    // MARK: - Gates

    @Test("No photo without a person ever becomes a candidate")
    func peopleFreePhotosNeverAdmitted() throws {
        let corpus = try #require(FixtureCorpus.load())
        let policy = ScanPolicy()
        let admitted = corpus.peopleFree.filter { policy.isCandidate(Self.observation(for: $0)) }
        let total = corpus.peopleFree.count
        let leaked = admitted.count
        Log.scan.notice("gate peopleFree total=\(total) admitted=\(leaked)")
        #expect(admitted.isEmpty, "\(leaked) of \(total) people-free photos became candidates")
    }

    @Test("A session containing only other people is never the owner's")
    func otherPeopleSessionsAreNotOwned() throws {
        let corpus = try #require(FixtureCorpus.load())
        let statuses = corpus.otherPeople.map { Self.ownerStatus(for: $0) }
        #expect(!statuses.isEmpty)
        // Every one of these must read as positive evidence of someone else —
        // this is the line two field tests broke on.
        #expect(ScanStore.confidence(statuses) == .notYou)
    }

    @Test("Not knowing who is in a photo never pre-selects it")
    func unsurePhotosAreNotPreSelected() throws {
        let corpus = try #require(FixtureCorpus.load())
        for photo in corpus.unsure {
            #expect(
                ScanStore.confidence([Self.ownerStatus(for: photo)]) == .unsure,
                "\(photo.id) should be unsure, not a verdict"
            )
        }
    }

    // MARK: - Measurements

    /// Prints the funnel this policy produces over the whole corpus.
    ///
    /// Deliberately assertion-light: the numbers are the deliverable, and the
    /// gate they will eventually be held to has to be chosen from a measurement
    /// rather than guessed — guessing thresholds is what four field tests were
    /// lost to.
    @Test("Measure: what the current policy does to 490 real photos")
    func measureCurrentPolicy() throws {
        let corpus = try #require(FixtureCorpus.load())
        let policy = ScanPolicy()

        var admitted: Set<String> = []
        var reasons: [String: Int] = [:]
        for photo in corpus.photos {
            let verdict = policy.verdict(Self.observation(for: photo))
            if verdict == .candidate {
                admitted.insert(photo.id)
            } else {
                reasons["\(verdict)", default: 0] += 1
            }
        }

        let target = corpus.worthExtracting
        let kept = target.count { admitted.contains($0.id) }
        let junkAdmitted = corpus.photos.count { !$0.isWorthExtracting && admitted.contains($0.id) }

        let total = corpus.photos.count
        let admittedCount = admitted.count
        let targetCount = target.count
        Log.scan.notice("fixture total=\(total) admitted=\(admittedCount) target=\(targetCount)")
        Log.scan.notice("fixture recall=\(kept)/\(targetCount) junkAdmitted=\(junkAdmitted)")
        for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) {
            Log.scan.notice("fixture drop reason=\(reason, privacy: .public) count=\(count)")
        }

        // The comparison that matters: framing alone, which the corpus says
        // separates useful from useless with 98.4% recall.
        let framedRecall = target.count(where: \.isBodyFramed)
        let framedJunk = corpus.photos.count { !$0.isWorthExtracting && $0.isBodyFramed && $0.people > 0 }
        Log.scan.notice("fixture framingRecall=\(framedRecall)/\(targetCount) framingJunk=\(framedJunk)")

        #expect(admittedCount > 0, "policy admitted nothing — the oracle is broken, not the policy")
    }

    @Test("Measure: sessions at a two-hour gap")
    func measureSessions() throws {
        let corpus = try #require(FixtureCorpus.load())
        let sessions = corpus.sessions(among: corpus.worthExtracting)
        let count = sessions.count
        let photos = corpus.worthExtracting.count
        Log.scan.notice("fixture sessions=\(count) fromPhotos=\(photos)")
        #expect(count > 0)
        #expect(count < photos, "every photo became its own session — grouping is doing nothing")
    }
}
