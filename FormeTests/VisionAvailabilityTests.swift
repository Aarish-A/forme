import Foundation
import OSLog
import Testing
import Vision
@testable import Forme

/// Two facts the whole test strategy rests on, checked rather than assumed.
///
/// The first is whether Vision runs at all on the destination the tests are on.
/// Vision's models ship Neural-Engine-only weights, and a simulator has no Neural
/// Engine — so requests are expected to fail there. Every Vision call site in this
/// app degrades silently by design, which means a simulator run doesn't error, it
/// quietly produces confident numbers about nothing. That has to be detectable.
///
/// The second is whether the clothing identifiers the scan looks for are real.
/// They are hand-written strings compared against a taxonomy Apple controls, so
/// a typo, a plural, or a word Apple simply never used is indistinguishable from
/// "the classifier didn't see clothes" — which is exactly how the scan spent four
/// field tests hunting words that do not exist.
@Suite("Vision availability and taxonomy")
nonisolated struct VisionAvailabilityTests {
    @Test("Vision classification is available on this destination")
    func classificationIsAvailable() {
        let identifiers = ClassifyImageRequest().supportedIdentifiers
        let count = identifiers.count
        Log.scan.notice("visionTaxonomy identifiers=\(count)")
        #expect(
            !identifiers.isEmpty,
            """
            Vision returned no classification identifiers. If this is a Simulator, that is \
            expected — Vision ships ANE-only weights and there is no Neural Engine here, so \
            the scan pipeline cannot be exercised on this destination. Run on a device.
            """
        )
    }

    /// The question that decides where the test harness runs.
    ///
    /// `supportedIdentifiers` only reads a bundled label list, so it succeeds
    /// anywhere. Actually running the models is different: Vision ships several of
    /// them with Neural-Engine-only weights, and a simulator has no Neural Engine.
    /// This performs each request the scan depends on and reports which survive.
    @Test("Report which Vision requests can actually run here")
    func requestsThatActuallyRun() async throws {
        let image = try #require(TestImageFactory.image(color: .teal, size: 640))

        func probe(_ name: String, _ work: () async throws -> String) async {
            // `.public` because every value here is a request name or a count we
            // chose ourselves — nothing derived from a photo. Without it OSLog
            // redacts the strings and the probe reports nothing.
            do {
                let detail = try await work()
                Log.scan.notice("visionProbe request=\(name, privacy: .public) ok=1 detail=\(detail, privacy: .public)")
            } catch {
                let kind = "\(type(of: error))"
                Log.scan.error("visionProbe request=\(name, privacy: .public) ok=0 error=\(kind, privacy: .public)")
            }
        }

        await probe("ClassifyImage") {
            let results = try await ClassifyImageRequest().perform(on: image)
            return "\(results.count) observations"
        }
        await probe("DetectHumanRectangles") {
            let results = try await DetectHumanRectanglesRequest().perform(on: image)
            return "\(results.count) people"
        }
        await probe("DetectFaceRectangles") {
            let results = try await DetectFaceRectanglesRequest().perform(on: image)
            return "\(results.count) faces"
        }
        await probe("CalculateImageAesthetics") {
            let result = try await CalculateImageAestheticsScoresRequest().perform(on: image)
            return "utility=\(result.isUtility)"
        }
        await probe("GenerateImageFeaturePrint") {
            let result = try await GenerateImageFeaturePrintRequest().perform(on: image)
            return "\(result.elementCount) dims"
        }
        await probe("GenerateForegroundInstanceMask") {
            let result = try await GenerateForegroundInstanceMaskRequest().perform(on: image)
            return "\(result?.allInstances.count ?? 0) instances"
        }
        await probe("DetectHumanBodyPose") {
            let results = try await DetectHumanBodyPoseRequest().perform(on: image)
            return "\(results.count) poses"
        }
    }

    /// Reports rather than asserts, for now: the label set is known to be wrong
    /// and the fix is a separate change. Once it lands this becomes an
    /// `#expect(dead.isEmpty)` and stays a permanent guard against Apple shifting
    /// the taxonomy under us.
    @Test("Report which clothing identifiers actually exist in Vision's taxonomy")
    func clothingLabelsAgainstTaxonomy() throws {
        let taxonomy = Set(ClassifyImageRequest().supportedIdentifiers.map { $0.lowercased() })
        try #require(!taxonomy.isEmpty, "No taxonomy on this destination — device-only test")

        let ours = VisionGarmentDetector.clothingLabels.map { $0.lowercased() }
        let live = ours.filter { taxonomy.contains($0) }.sorted()
        let dead = ours.filter { !taxonomy.contains($0) }.sorted()

        let total = ours.count
        let liveCount = live.count
        let deadCount = dead.count
        let liveList = live.joined(separator: " ")
        let deadList = dead.joined(separator: " ")
        Log.scan.notice("clothingLabels total=\(total) live=\(liveCount) dead=\(deadCount)")
        Log.scan.notice("clothingLabels live=\(liveList, privacy: .public)")
        Log.scan.notice("clothingLabels dead=\(deadList, privacy: .public)")

        // What else the taxonomy offers that we never look for — the shopping
        // list for the vocabulary fix.
        let wardrobeish = taxonomy.filter { identifier in
            ["shirt", "shoe", "boot", "coat", "hat", "sock", "glove", "jacket", "wear", "dress", "suit", "pant"]
                .contains { identifier.contains($0) }
        }.sorted()
        let candidates = wardrobeish.joined(separator: " ")
        Log.scan.notice("taxonomyWardrobeTerms terms=\(candidates, privacy: .public)")

        #expect(!live.isEmpty, "Not one clothing identifier matched — the label set is entirely fictional")
    }
}
