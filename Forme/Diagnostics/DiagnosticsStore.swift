import Foundation
import OSLog

/// Where scan reports live on disk, so they can be read after the fact.
///
/// `Application Support/Diagnostics/` rather than `Documents/`: `Documents` is
/// one `UIFileSharingEnabled` away from being browsable, and the app's promise
/// is that its container stays shut. `xcrun devicectl device copy from` reaches
/// Application Support without opening anything to the user — see `make diag`.
///
/// Writes happen in DEBUG builds only. A release build carries the report types
/// (they ride along in the pipeline) but never puts anything on disk.
nonisolated struct DiagnosticsStore: Sendable {
    /// How many reports to keep. Enough to compare a change against the run
    /// before it, few enough that nobody has to think about disk.
    static let retained = 5

    private let directory: URL?

    init(directory: URL? = DiagnosticsStore.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    /// Reports newest-first. Empty when nothing has been written.
    func reports() -> [URL] {
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "latest.json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func latestURL() -> URL? {
        guard let directory else { return nil }
        let latest = directory.appending(path: "latest.json")
        return FileManager.default.fileExists(atPath: latest.path(percentEncoded: false)) ? latest : nil
    }

    /// `@concurrent` because the caller is the main-actor store and this is
    /// encoding plus file I/O.
    @concurrent
    func write(_ report: ScanReport) async {
        #if DEBUG
            guard let directory else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                var mutable = directory
                try? mutable.setResourceValues(excluded)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)

                // The run id is time-ordered, so lexical sort is chronological
                // and pruning needs no file dates.
                try data.write(to: directory.appending(path: "\(report.runID).json"), options: .atomic)
                try data.write(to: directory.appending(path: "latest.json"), options: .atomic)
                prune(in: directory)

                let warnings = report.warnings.count
                Log.scan.notice("Scan report written, \(warnings) warning(s)")
            } catch {
                // Diagnostics failing must never affect a scan.
                Log.scan.error("Could not write the scan report")
            }
        #endif
    }

    private func prune(in _: URL) {
        let stale = reports().dropFirst(Self.retained)
        for url in stale {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Time-ordered so reports sort chronologically by name, with a short
    /// random tail so two scans in the same second can't collide.
    static func makeRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let suffix = String(UInt16.random(in: 0 ... .max), radix: 16)
        return "\(formatter.string(from: now))-\(suffix)"
    }
}

/// `nonisolated` on the extension, not just the type: the project defaults every
/// declaration to `@MainActor`, and the report is assembled off the main actor.
nonisolated extension ScanReport.Build {
    /// Deliberately built from `ProcessInfo` and `uname` rather than `UIDevice`:
    /// the report is assembled off the main actor, `UIDevice` is main-actor
    /// isolated, and the hardware identifier (`iPhone18,3`) is the more useful
    /// answer anyway — Vision and Neural Engine behaviour tracks the chip, which
    /// `UIDevice.model`'s "iPhone" cannot tell you.
    static var current: ScanReport.Build {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(simulator)
            let isSimulator = true
        #else
            let isSimulator = false
        #endif
        #if DEBUG
            let isDebug = true
        #else
            let isDebug = false
        #endif
        return ScanReport.Build(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            model: hardwareIdentifier(),
            isDebug: isDebug,
            isSimulator: isSimulator
        )
    }

    private static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = Data(raw.prefix { $0 != 0 })
            return String(bytes: bytes, encoding: .utf8) ?? "unknown"
        }
    }
}
