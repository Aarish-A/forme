import CoreGraphics
import Foundation
import ImageIO
import Vision

// Runs the app's real perception code over the fixture corpus and writes down
// everything Vision saw, once, so that tuning a threshold costs milliseconds
// instead of a build and a device.
//
// The split this enforces is the whole point. Perception is expensive, slow and
// fixed; policy is cheap, fast and the thing we are actually iterating on. Every
// number a gate could possibly want lives in the cache — every pose joint with
// its confidence, every face with its capture quality and its embedding, the raw
// person boxes — so a new gate can be scored against 490 real photos without
// re-running a single Vision request.
//
// It compiles `Forme/Services/**` directly rather than reimplementing it. A
// runner that approximates the app is a runner that measures the wrong thing,
// and this is the same source file the phone runs. Vision itself is native on
// macOS; only the Simulator cannot run it, because the weights are Neural
// Engine only.
//
//     make vision-cache

// MARK: - What we write down

/// One photo's worth of measured facts. Deliberately raw: no verdicts, no
/// thresholds, nothing a policy could disagree with later.
nonisolated struct PhotoFacts: Codable {
    var id: String
    var widthPx: Int
    var heightPx: Int

    var isUtility: Bool
    var aestheticsScore: Float?

    /// Normalized person boxes, tallest first.
    var people: [Box]
    /// One entry per detected body, in the same order Vision reported them.
    var poses: [Pose]
    var faces: [Face]

    var analysisMS: Int
    var errors: [String]

    nonisolated struct Box: Codable {
        var x: Double, y: Double, width: Double, height: Double
    }

    /// Joint confidences rather than booleans. `hasHips` is a policy decision
    /// about a number, and storing the boolean would bake today's threshold
    /// into a cache meant to outlive it.
    nonisolated struct Pose: Codable {
        var joints: [String: Joint]
        nonisolated struct Joint: Codable {
            var x: Double, y: Double, confidence: Double
        }
    }

    nonisolated struct Face: Codable {
        var box: Box
        /// Side length in pixels of the face in the source image — the number
        /// that killed identity when it was measured against a 512 px render.
        var sidePx: Double
        var captureQuality: Float?
        var embedding: [Float]?
    }
}

// MARK: - Loading

nonisolated struct Runner {
    let fixtures: URL
    let modelURL: URL?

    /// Matches the app: analysis at 512 px, identity retried at 1536 px because
    /// a face in a full-length photo is tiny at 512.
    static let analysisPixels = 512
    static let identityPixels = 1536

    func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func facts(for id: String, at url: URL) async -> PhotoFacts {
        let started = Date()
        var errors: [String] = []

        guard let small = image(at: url, maxPixelSize: Self.analysisPixels) else {
            return PhotoFacts(
                id: id, widthPx: 0, heightPx: 0, isUtility: false, aestheticsScore: nil,
                people: [], poses: [], faces: [], analysisMS: 0, errors: ["decode failed"]
            )
        }

        let detector = VisionGarmentDetector()
        var observation = GarmentObservation(isClothingCandidate: false, confidence: 0, labels: [])
        do {
            observation = try await detector.analyze(small)
        } catch {
            errors.append("analyze: \(error)")
        }

        // Raw pose, separately, because `GarmentObservation.framing` is already
        // a policy summary (`hasHips`) and the cache must outlive that policy.
        var poses: [PhotoFacts.Pose] = []
        do {
            var request = DetectHumanBodyPoseRequest()
            request.detectsHands = false
            for pose in try await request.perform(on: small) {
                var joints: [String: PhotoFacts.Pose.Joint] = [:]
                for (name, point) in pose.allJoints() {
                    joints[String(describing: name)] = .init(
                        x: point.location.x, y: point.location.y, confidence: Double(point.confidence)
                    )
                }
                poses.append(.init(joints: joints))
            }
        } catch {
            errors.append("pose: \(error)")
        }

        // Identity at full resolution — the retry that made faces exist at all.
        var faces: [PhotoFacts.Face] = []
        let large = image(at: url, maxPixelSize: Self.identityPixels) ?? small
        let identity = VisionFaceIdentityService(modelURL: modelURL)
        do {
            let detection = try await identity.detectFaces(in: large)
            let width = CGFloat(large.width)
            let height = CGFloat(large.height)
            for (index, face) in detection.faces.enumerated() {
                let box = face.boundingBox
                faces.append(
                    .init(
                        box: .init(
                            x: box.origin.x, y: box.origin.y,
                            width: box.width, height: box.height
                        ),
                        sidePx: Double(
                            detection.detectedSidesPx.indices.contains(index)
                                ? detection.detectedSidesPx[index]
                                : min(box.width * width, box.height * height)
                        ),
                        captureQuality: face.captureQuality,
                        embedding: face.embedding.vector
                    )
                )
            }
            // Faces Vision found but that produced no embedding still matter:
            // "a face was there and identity could not use it" is the exact
            // failure that has to stay visible.
            for (index, side) in detection.detectedSidesPx.enumerated()
                where index >= detection.faces.count
            {
                faces.append(
                    .init(
                        box: .init(x: 0, y: 0, width: 0, height: 0),
                        sidePx: Double(side), captureQuality: nil, embedding: nil
                    )
                )
            }
        } catch {
            errors.append("identity: \(error)")
        }

        return PhotoFacts(
            id: id,
            widthPx: large.width,
            heightPx: large.height,
            isUtility: observation.isUtility,
            aestheticsScore: observation.aestheticsScore,
            people: observation.people.map {
                .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            },
            poses: poses,
            faces: faces,
            analysisMS: Int(Date().timeIntervalSince(started) * 1000),
            errors: errors
        )
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: vision-cache <fixtures-dir> <output.json> [model.mlmodelc]\n".utf8))
    exit(2)
}

let fixtures = URL(filePath: arguments[1])
let output = URL(filePath: arguments[2])
let modelURL = arguments.count > 3 ? URL(filePath: arguments[3]) : nil

if modelURL == nil {
    print("warning: no SFace model — faces will be detected but not embedded")
}

let inbox = fixtures.appending(path: "inbox")
var jobs: [(id: String, url: URL)] = []
for bucket in ["you", "others", "reject", "unsure", "seed"] {
    let directory = inbox.appending(path: bucket)
    let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for entry in entries where entry.pathExtension.lowercased() == "jpg" {
        jobs.append((entry.deletingPathExtension().lastPathComponent, entry))
    }
}

jobs.sort { $0.id < $1.id }

guard !jobs.isEmpty else {
    FileHandle.standardError.write(Data("no photos under \(inbox.path())\n".utf8))
    exit(1)
}

print("Running Vision over \(jobs.count) photos…")
let runner = Runner(fixtures: fixtures, modelURL: modelURL)
let started = Date()
var all: [PhotoFacts] = []
for (index, job) in jobs.enumerated() {
    await all.append(runner.facts(for: job.id, at: job.url))
    if (index + 1) % 50 == 0 {
        print("  \(index + 1)/\(jobs.count)")
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(all).write(to: output)

// A summary that would have caught every structural failure this project has
// had: a request that never fires reads as a column of zeros.
let withPeople = all.count { !$0.people.isEmpty }
let withPose = all.count { !$0.poses.isEmpty }
let withFaces = all.count { !$0.faces.isEmpty }
let withEmbedding = all.count { $0.faces.contains { $0.embedding != nil } }
let failed = all.count { !$0.errors.isEmpty }
let elapsed = Date().timeIntervalSince(started)

print("""

  \(all.count) photos in \(String(format: "%.1f", elapsed))s \
(\(Int(elapsed / Double(all.count) * 1000)) ms each)
  people   \(withPeople)
  pose     \(withPose)
  faces    \(withFaces)
  embedded \(withEmbedding)
  errors   \(failed)
  → \(output.path())
""")

if withPose == 0 || withPeople == 0 {
    FileHandle.standardError
        .write(Data("\nA whole stage returned nothing — that is a broken runner, not a hard corpus.\n".utf8))
    exit(1)
}
