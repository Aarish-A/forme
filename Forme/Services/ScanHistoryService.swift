import Foundation
import OSLog

/// How far back scanning has reached, persisted across launches.
///
/// The watermark is what makes "Scan Older Photos" and incremental re-scans
/// possible: `oldestScannedDate` is the oldest photo a scan has actually
/// looked at, so the next "older" scan starts strictly before it. Dates only —
/// nothing here says what was found.
nonisolated struct ScanRecord: Codable, Sendable, Equatable {
    var oldestScannedDate: Date?
    var lastScanAt: Date
}

/// Persistence for the scan watermark, behind a protocol so stores can be
/// tested and previewed without touching UserDefaults.
nonisolated protocol ScanHistoryService: Sendable {
    func load() async -> ScanRecord?
    func save(_ record: ScanRecord) async
    func clear() async
}

// MARK: - UserDefaults implementation

/// One Codable blob in UserDefaults. A record is a few dozen bytes and there
/// is exactly one, so defaults beats a file on disk for ceremony.
nonisolated struct DefaultsScanHistoryService: ScanHistoryService {
    static let key = "scanHistory"

    /// UserDefaults is documented thread-safe but predates Sendable, so the
    /// compiler can't see it. Scoped to this one property, not the whole type.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Tests pass a throwaway suite so runs never see each other's watermark.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() async -> ScanRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(ScanRecord.self, from: data)
        } catch {
            // An unreadable record means "never scanned" — the cost is one
            // redundant scan, not a crash.
            Log.feature.error("Scan history unreadable — treating as no history")
            return nil
        }
    }

    func save(_ record: ScanRecord) async {
        do {
            try defaults.set(JSONEncoder().encode(record), forKey: Self.key)
        } catch {
            Log.feature.error("Scan history write failed")
        }
    }

    func clear() async {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - In-memory implementation

/// A scripted history for previews and tests.
actor InMemoryScanHistoryService: ScanHistoryService {
    private var record: ScanRecord?

    init(record: ScanRecord? = nil) {
        self.record = record
    }

    func load() async -> ScanRecord? {
        record
    }

    func save(_ record: ScanRecord) async {
        self.record = record
    }

    func clear() async {
        record = nil
    }
}
