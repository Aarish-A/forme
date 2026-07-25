import Foundation
import OSLog

/// Observable auth state for the whole app.
///
/// The split is deliberate: `AuthService` does I/O and knows nothing about
/// SwiftUI, `SessionStore` holds the state SwiftUI observes and knows nothing
/// about Supabase. Views read `session` and `phase`; nothing else touches auth.
@Observable
final class SessionStore {
    enum Phase: Equatable {
        /// Before `restore()` has finished — show a splash, not a sign-in form.
        case loading
        case signedOut
        case signedIn(UserSession)
    }

    private(set) var phase: Phase
    private(set) var errorMessage: String?

    private let auth: any AuthService

    /// `initialPhase` exists so previews and tests can start from a signed-in
    /// state without going through the sign-in flow first.
    init(auth: any AuthService, initialPhase: Phase = .loading) {
        self.auth = auth
        self.phase = initialPhase
    }

    var session: UserSession? {
        if case let .signedIn(session) = phase {
            return session
        }
        return nil
    }

    /// Restores a persisted session. Call once, at launch.
    func restore() async {
        let session = await auth.restoreSession()
        phase = session.map(Phase.signedIn) ?? .signedOut
    }

    func signIn(email: String, password: String) async {
        await perform { try await self.auth.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String) async {
        await perform { try await self.auth.signUp(email: email, password: password) }
    }

    func signOut() async {
        errorMessage = nil
        do {
            try await auth.signOut()
            phase = .signedOut
        } catch {
            errorMessage = error.localizedDescription
            Log.auth.error("Sign out failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func perform(_ operation: () async throws -> UserSession) async {
        errorMessage = nil
        do {
            let session = try await operation()
            phase = .signedIn(session)
        } catch {
            errorMessage = error.localizedDescription
            Log.auth.error("Auth failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
