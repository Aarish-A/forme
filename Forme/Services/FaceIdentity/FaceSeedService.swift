import Foundation
import OSLog

/// The user's reference face — the only face data that ever touches disk.
///
/// Up to five embeddings of the same person (different angles and lighting
/// make matching forgiving). Stored locally, never synced, deleted whole by
/// `FaceSeedService.clear()`.
nonisolated struct FaceSeed: Codable, Sendable, Equatable {
    var embeddings: [FaceEmbedding]
    var createdAt: Date
}

/// Persists the user's face seed. One seed per device, or none.
nonisolated protocol FaceSeedService: Sendable {
    func load() async -> FaceSeed?
    func save(_ seed: FaceSeed) async
    func clear() async
}

/// The seed as a single JSON file in Application Support.
///
/// Save and clear are best-effort: a failed write logs (never the content —
/// this is biometric data) and the app carries on as if no seed were set,
/// which only means identity filtering asks again next scan.
actor LocalFaceSeedService: FaceSeedService {
    private let fileURL: URL

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Defaults to Application Support; tests pass a temporary directory.
    init(directory: URL = .applicationSupportDirectory) {
        self.fileURL = directory.appending(path: "FaceSeed.json")
    }

    func load() async -> FaceSeed? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(FaceSeed.self, from: data)
    }

    func save(_ seed: FaceSeed) async {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(seed).write(to: fileURL, options: .atomic)
        } catch {
            Log.feature.error("Face seed save failed")
        }
    }

    func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// In-memory seed store for previews and tests.
actor InMemoryFaceSeedService: FaceSeedService {
    private var seed: FaceSeed?

    init(seed: FaceSeed? = nil) {
        self.seed = seed
    }

    func load() async -> FaceSeed? {
        seed
    }

    func save(_ seed: FaceSeed) async {
        self.seed = seed
    }

    func clear() async {
        seed = nil
    }
}
