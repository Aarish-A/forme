import Foundation
import OSLog

/// Namespaced loggers for the app.
///
/// Prefer these over `print`: `Logger` output is structured, survives release
/// builds, is visible in Console.app against a real device, and redacts
/// interpolated values by default unless marked `privacy: .public`.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.forme.app"

    /// App lifecycle, dependency wiring, configuration.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Sign in, sign out, session restoration.
    static let auth = Logger(subsystem: subsystem, category: "auth")

    /// Requests to Supabase and anything else over the wire.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Wardrobe, outfits, and the rest of the product surface.
    static let feature = Logger(subsystem: subsystem, category: "feature")

    /// The photo-library scan: stage counts and durations, never content.
    ///
    /// Its own category so `make logs` can watch a scan without the rest of the
    /// app's chatter. Nothing here may describe what a photo contains — no
    /// labels, no categories, no asset identifiers — so every message is
    /// counts, milliseconds, and thresholds.
    static let scan = Logger(subsystem: subsystem, category: "scan")
}
