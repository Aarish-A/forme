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
}
