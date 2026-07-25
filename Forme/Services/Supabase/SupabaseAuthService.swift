import Foundation
import OSLog
import Supabase

/// `AuthService` backed by Supabase Auth.
///
/// This type is the only place in the app that knows Supabase exists for auth.
/// Its job is narrow on purpose: call the SDK, translate the result into our own
/// `UserSession` and `AuthError`, and log what happened.
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    convenience init(config: SupabaseConfig) {
        self.init(client: SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey))
    }

    func restoreSession() async -> UserSession? {
        do {
            // The SDK persists and refreshes the session in the Keychain for us.
            let session = try await client.auth.session
            return UserSession(session)
        } catch {
            Log.auth.debug("No session to restore: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func signUp(email: String, password: String) async throws -> UserSession {
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            Log.auth.info("Signed up new user")
            // With email confirmation enabled the session is nil until the user
            // clicks the link, so fall back to the user record.
            return response.session.map(UserSession.init) ?? UserSession(response.user)
        } catch {
            throw Self.mapped(error)
        }
    }

    func signIn(email: String, password: String) async throws -> UserSession {
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            Log.auth.info("Signed in")
            return UserSession(session)
        } catch {
            throw Self.mapped(error)
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
            Log.auth.info("Signed out")
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Collapses SDK and transport errors into the small set the UI knows how to
    /// present. Anything unrecognised keeps its message rather than being hidden.
    private static func mapped(_ error: any Error) -> AuthError {
        if let authError = error as? AuthError {
            return authError
        }

        if let urlError = error as? URLError {
            Log.network.error("Auth request failed: \(urlError.code.rawValue, privacy: .public)")
            return .network
        }

        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("invalid login credentials") {
            return .invalidCredentials
        }

        Log.auth.error("Unmapped auth error: \(message, privacy: .public)")
        return .unknown(message)
    }
}

// MARK: - Mapping Supabase types to ours

private extension UserSession {
    init(_ session: Session) {
        self.init(id: session.user.id, email: session.user.email)
    }

    init(_ user: User) {
        self.init(id: user.id, email: user.email)
    }
}
