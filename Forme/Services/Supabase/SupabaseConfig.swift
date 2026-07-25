import Foundation

/// Supabase connection details, injected at build time.
///
/// The values come from `Config/Secrets.xcconfig` (gitignored), get written
/// into Info.plist by `Config/Forme.xcconfig`, and are read back here. Nothing
/// is hardcoded, so a fork of this repo can't accidentally point at your project.
///
/// The anon key is safe to ship — Row Level Security, not secrecy, is what
/// protects your data. The service role key must never appear in this app.
nonisolated struct SupabaseConfig: Sendable, Equatable {
    static let urlKey = "SUPABASE_URL"
    static let anonKeyKey = "SUPABASE_ANON_KEY"

    let url: URL
    let anonKey: String

    /// Validates a raw key/value pair.
    ///
    /// Returns `nil` — rather than trapping — when values are missing, blank, or
    /// still the placeholder text. That's the expected state on a fresh clone,
    /// and `AppEnvironment` falls back to in-memory auth so the app still runs.
    ///
    /// The URL is accepted as a bare host (`abcdefgh.supabase.co`) as well as a
    /// full URL. The bare form is what `Secrets.example.xcconfig` recommends,
    /// because `//` starts a comment in an xcconfig and a full URL written the
    /// obvious way silently truncates to `https:`. A value that has been
    /// truncated that way has no host, so it is rejected here rather than
    /// reaching `SupabaseClient` and failing at runtime.
    init?(values: [String: String]) {
        let whitespace = CharacterSet.whitespacesAndNewlines

        guard
            let rawURL = values[Self.urlKey]?.trimmingCharacters(in: whitespace), !rawURL.isEmpty,
            let anonKey = values[Self.anonKeyKey]?.trimmingCharacters(in: whitespace), !anonKey.isEmpty,
            !anonKey.contains("your-anon-key"),
            let url = Self.normalizedURL(from: rawURL),
            let host = url.host(), !host.contains("your-project-ref")
        else {
            return nil
        }

        self.url = url
        self.anonKey = anonKey
    }

    /// Turns a configured value into a URL, accepting a bare host and rejecting
    /// anything that looks like it lost its slashes to an xcconfig comment.
    private static func normalizedURL(from raw: String) -> URL? {
        let candidate: String

        if raw.contains("://") {
            candidate = raw
        } else if !raw.contains(":"), !raw.contains("/") {
            // A bare host — the form Secrets.example.xcconfig recommends.
            candidate = "https://\(raw)"
        } else {
            // Something like "https:" or "https:/". The xcconfig comment scanner
            // ate the slashes; prefixing a scheme here would produce a URL that
            // parses but points nowhere.
            return nil
        }

        guard
            let url = URL(string: candidate),
            url.scheme == "https" || url.scheme == "http",
            let host = url.host(), !host.isEmpty
        else {
            return nil
        }

        return url
    }

    /// Reads the configuration from a bundle's Info.plist.
    init?(bundle: Bundle = .main) {
        let values = [Self.urlKey, Self.anonKeyKey].reduce(into: [String: String]()) { result, key in
            result[key] = bundle.object(forInfoDictionaryKey: key) as? String
        }
        self.init(values: values)
    }
}
