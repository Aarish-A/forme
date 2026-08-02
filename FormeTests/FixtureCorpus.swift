import CoreGraphics
import Foundation

/// The labelled corpus of real photos the scan is measured against.
///
/// The photos and their labels live **outside the repository** — at
/// `~/forme-fixtures` by default, overridable with `FORME_FIXTURES`. They are
/// photographs of the user, his partner and third parties, so they never enter
/// git, a build product, or an `.xcresult`. Nothing here loads image data; only
/// the labels, which are what the fast tests need.
///
/// When the corpus is absent — CI, a fresh clone, another machine — every test
/// that depends on it is *skipped*, never failed.
nonisolated struct FixtureCorpus: Sendable {
    /// One labelled photo. Field names match the label file exactly.
    nonisolated struct Photo: Codable, Sendable, Equatable {
        let id: String
        /// `yes` / `no` / `unsure` — is the app's owner in this photo?
        let aarish: String
        let people: Int
        /// `full_body` / `three_quarter` / `upper_body` / `face_closeup` /
        /// `distant` / `no_person` / `flatlay` / `screenshot_or_graphic`
        let shot: String
        /// `high` / `medium` / `low` / `none` — how much usable garment
        /// information this photo carries about the owner.
        let outfitValue: String
        let garments: [String]
        let issues: [String]
        let bucket: String
        let captured: String

        /// The photos a wardrobe should actually be built from: the owner is in
        /// it, and there is something worth cataloguing. This is the definition
        /// the whole feature is judged against.
        var isWorthExtracting: Bool {
            aarish == "yes" && (outfitValue == "high" || outfitValue == "medium")
        }

        /// Framing that shows a body rather than a face or a speck. On the real
        /// corpus this alone separates worth-extracting from junk with 98.4%
        /// recall — far better than any clothing-classifier confidence.
        var isBodyFramed: Bool {
            ["full_body", "three_quarter", "upper_body"].contains(shot)
        }

        /// Capture time, when the export preserved one. 57 of 490 lost theirs to
        /// the JPEG re-encode; `PHAsset.creationDate` survives that in
        /// production, so a missing date here is a fixture artifact, not a case
        /// the pipeline must handle.
        var capturedAt: Date? {
            Self.formatter.date(from: captured)
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter
        }()
    }

    let photos: [Photo]

    /// Where the corpus lives on this machine.
    ///
    /// `NSHomeDirectory()` is the app's sandbox container, not the Mac's home —
    /// so a simulator run looking for `~/forme-fixtures` finds nothing and the
    /// whole suite skips *silently*, which reads exactly like passing. The
    /// simulator sets `SIMULATOR_HOST_HOME` to the real home for this reason.
    static var directory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["FORME_FIXTURES"] {
            return URL(filePath: override)
        }
        let home = environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        return URL(filePath: home).appending(path: "forme-fixtures")
    }

    /// Nil when the corpus isn't on this machine.
    static func load() -> FixtureCorpus? {
        let url = directory.appending(path: "labels/labels.json")
        guard
            let data = try? Data(contentsOf: url),
            let photos = try? JSONDecoder().decode([Photo].self, from: data),
            !photos.isEmpty
        else { return nil }
        return FixtureCorpus(photos: photos)
    }

    static var isAvailable: Bool {
        load() != nil
    }

    // MARK: - Slices the gates are phrased in terms of

    var worthExtracting: [Photo] {
        photos.filter(\.isWorthExtracting)
    }

    var owner: [Photo] {
        photos.filter { $0.aarish == "yes" }
    }

    var otherPeople: [Photo] {
        photos.filter { $0.aarish == "no" && $0.people > 0 }
    }

    var unsure: [Photo] {
        photos.filter { $0.aarish == "unsure" }
    }

    var peopleFree: [Photo] {
        photos.filter { $0.people == 0 }
    }

    /// Owner photos with nothing worth cataloguing — face-filling selfies,
    /// distant specks, photos where a coat hides everything. The pipeline should
    /// drop these even though the owner is present, which is the half of the
    /// problem a pure identity filter can never solve.
    var ownerButUseless: [Photo] {
        photos.filter { $0.aarish == "yes" && ($0.outfitValue == "low" || $0.outfitValue == "none") }
    }

    /// Photos grouped into occasions by a capture-time gap. The corpus's own gap
    /// distribution is bimodal — 37% of consecutive gaps are under 10 seconds
    /// (burst mode) and the 15-minute-to-2-hour band is nearly empty — so two
    /// hours sits in the valley, where a boundary belongs.
    func sessions(gap: TimeInterval = 7200, among photos: [Photo]? = nil) -> [[Photo]] {
        let dated = (photos ?? self.photos)
            .compactMap { photo in photo.capturedAt.map { (photo, $0) } }
            .sorted { $0.1 < $1.1 }
        var sessions: [[Photo]] = []
        var current: [Photo] = []
        var previous: Date?
        for (photo, date) in dated {
            if let previous, date.timeIntervalSince(previous) > gap {
                sessions.append(current)
                current = []
            }
            current.append(photo)
            previous = date
        }
        if !current.isEmpty {
            sessions.append(current)
        }

        // Undated photos can't be placed, so each stands alone rather than
        // silently joining whatever happened to be adjacent.
        let undated = (photos ?? self.photos).filter { $0.capturedAt == nil }
        return sessions + undated.map { [$0] }
    }
}
