import Foundation
import OSLog
import SwiftUI

/// The app's dependency graph, assembled once at launch.
///
/// Everything the app needs to talk to the outside world hangs off this object,
/// and it reaches views through the SwiftUI environment. Adding a service means
/// adding a stored property here and a line in `live()` and `preview` — no
/// singletons, and nothing a test or preview can't replace.
@Observable
final class AppEnvironment {
    let auth: any AuthService
    let session: SessionStore

    init(auth: any AuthService, initialPhase: SessionStore.Phase = .loading) {
        self.auth = auth
        self.session = SessionStore(auth: auth, initialPhase: initialPhase)
    }

    /// The real graph, used by `FormeApp`.
    ///
    /// Falls back to in-memory auth when Supabase isn't configured, so a fresh
    /// clone builds and runs. See `Config/Secrets.example.xcconfig`.
    static func live() -> AppEnvironment {
        guard let config = SupabaseConfig() else {
            Log.app.warning(
                """
                Supabase is not configured — running with in-memory auth. \
                Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig to connect.
                """
            )
            return AppEnvironment(auth: InMemoryAuthService())
        }

        Log.app.info("Supabase configured for host \(config.url.host() ?? "unknown", privacy: .public)")
        return AppEnvironment(auth: SupabaseAuthService(config: config))
    }

    /// A signed-in graph with no network behind it, for `#Preview` blocks.
    static var preview: AppEnvironment {
        let session = UserSession(id: UUID(), email: "sam@example.com")
        return AppEnvironment(
            auth: InMemoryAuthService(session: session),
            initialPhase: .signedIn(session)
        )
    }
}

extension EnvironmentValues {
    /// Injected by `FormeApp`; read with `@Environment(\.appEnvironment)`.
    @Entry var appEnvironment: AppEnvironment = .preview
}
