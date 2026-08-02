import Foundation
import Testing
@testable import Forme

@Suite("Scan history")
struct ScanHistoryServiceTests {
    /// A throwaway suite so tests never touch the app's real defaults and
    /// parallel runs never see each other's watermark.
    private func makeDefaults() throws -> (UserDefaults, suiteName: String) {
        let suiteName = "scan-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test("A record round trips through UserDefaults")
    func defaultsRoundTrip() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let service = DefaultsScanHistoryService(defaults: defaults)
        let record = ScanRecord(
            oldestScannedDate: Date(timeIntervalSince1970: 1_600_000_000),
            lastScanAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        await service.save(record)

        #expect(await service.load() == record)
    }

    @Test("No saved record reads as nil, not a default")
    func defaultsEmptyReadsNil() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        #expect(await DefaultsScanHistoryService(defaults: defaults).load() == nil)
    }

    @Test("A nil oldestScannedDate survives the round trip")
    func defaultsRoundTripWithNilOldest() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let service = DefaultsScanHistoryService(defaults: defaults)
        let record = ScanRecord(oldestScannedDate: nil, lastScanAt: Date(timeIntervalSince1970: 1_700_000_000))

        await service.save(record)

        let loaded = await service.load()
        #expect(loaded == record)
        #expect(loaded?.oldestScannedDate == nil)
    }

    @Test("Clearing forgets the watermark")
    func defaultsClear() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let service = DefaultsScanHistoryService(defaults: defaults)
        await service.save(ScanRecord(oldestScannedDate: Date(), lastScanAt: Date()))

        await service.clear()

        #expect(await service.load() == nil)
    }

    @Test("Garbage on disk reads as no history, never a crash")
    func defaultsCorruptDataReadsNil() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: DefaultsScanHistoryService.key)

        #expect(await DefaultsScanHistoryService(defaults: defaults).load() == nil)
    }

    @Test("The in-memory service saves, loads and clears")
    func inMemoryLifecycle() async {
        let service = InMemoryScanHistoryService()
        #expect(await service.load() == nil)

        let record = ScanRecord(
            oldestScannedDate: Date(timeIntervalSince1970: 1_500_000_000),
            lastScanAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await service.save(record)
        #expect(await service.load() == record)

        await service.clear()
        #expect(await service.load() == nil)
    }

    @Test("A seeded in-memory service starts with its record")
    func inMemorySeeded() async {
        let record = ScanRecord(oldestScannedDate: nil, lastScanAt: Date(timeIntervalSince1970: 1))
        #expect(await InMemoryScanHistoryService(record: record).load() == record)
    }
}
