import Foundation
import Testing
@testable import Forme

@Suite("Supabase configuration")
struct SupabaseConfigTests {
    private func values(url: String, key: String = "sb-anon-key") -> [String: String] {
        [SupabaseConfig.urlKey: url, SupabaseConfig.anonKeyKey: key]
    }

    @Test("Accepts a well-formed project URL and key")
    func acceptsValidValues() throws {
        let config = try #require(SupabaseConfig(values: values(url: "https://abcdefgh.supabase.co")))

        #expect(config.url.host() == "abcdefgh.supabase.co")
        #expect(config.anonKey == "sb-anon-key")
    }

    /// The form Secrets.example.xcconfig recommends, because a bare host has no
    /// `//` for the xcconfig comment scanner to swallow.
    @Test("Accepts a bare host and assumes https")
    func acceptsBareHost() throws {
        let config = try #require(SupabaseConfig(values: values(url: "abcdefgh.supabase.co")))

        #expect(config.url.absoluteString == "https://abcdefgh.supabase.co")
    }

    @Test("Rejects missing configuration so a fresh clone still runs")
    func rejectsMissingValues() {
        #expect(SupabaseConfig(values: [:]) == nil)
        #expect(SupabaseConfig(values: values(url: "")) == nil)
        #expect(SupabaseConfig(values: values(url: "https://abcdefgh.supabase.co", key: "   ")) == nil)
    }

    // The `//` in an xcconfig starts a comment, so an unescaped URL truncates to
    // "https:" and would otherwise reach SupabaseClient as a hostless URL.
    @Test("Rejects a URL truncated by the xcconfig comment trap")
    func rejectsTruncatedURL() {
        #expect(SupabaseConfig(values: values(url: "https:")) == nil)
        #expect(SupabaseConfig(values: values(url: "https:/")) == nil)
        #expect(SupabaseConfig(values: values(url: "https://")) == nil)
    }

    @Test("Rejects a scheme it can't talk to")
    func rejectsUnsupportedScheme() {
        #expect(SupabaseConfig(values: values(url: "ftp://abcdefgh.supabase.co")) == nil)
    }

    @Test("Rejects the placeholders from Secrets.example.xcconfig")
    func rejectsPlaceholders() {
        #expect(SupabaseConfig(values: values(url: "your-project-ref.supabase.co")) == nil)
        #expect(
            SupabaseConfig(
                values: values(url: "https://abcdefgh.supabase.co", key: "your-anon-key-here")
            ) == nil
        )
    }
}
