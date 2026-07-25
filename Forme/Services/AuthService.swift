import Foundation

/// Everything the app needs from an identity provider.
///
/// Views and stores depend on this protocol, never on Supabase directly. That
/// keeps previews and unit tests free of network access, and means the backend
/// is a swappable detail rather than a load-bearing assumption.
protocol AuthService {
    /// The session restored from disk at launch, if the user is still signed in.
    func restoreSession() async -> UserSession?

    func signUp(email: String, password: String) async throws -> UserSession
    func signIn(email: String, password: String) async throws -> UserSession
    func signOut() async throws
}

/// Errors surfaced to the UI. Provider-specific errors are mapped into these at
/// the service boundary so views never have to know what a `PostgrestError` is.
enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case invalidCredentials
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Forme isn't connected to its server yet."
        case .invalidCredentials:
            "That email and password don't match an account."
        case .network:
            "Couldn't reach the server. Check your connection and try again."
        case let .unknown(message):
            message
        }
    }
}

// MARK: - In-memory implementation

/// A working `AuthService` with no backend behind it.
///
/// Used by SwiftUI previews, unit tests, and — importantly — by the real app
/// whenever `Config/Secrets.xcconfig` is missing, so a fresh clone builds and
/// runs before anyone has set up a Supabase project.
@Observable
final class InMemoryAuthService: AuthService {
    private(set) var session: UserSession?

    init(session: UserSession? = nil) {
        self.session = session
    }

    func restoreSession() async -> UserSession? {
        session
    }

    func signUp(email: String, password: String) async throws -> UserSession {
        try await signIn(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws -> UserSession {
        guard !password.isEmpty else { throw AuthError.invalidCredentials }
        let session = UserSession(id: UUID(), email: email)
        self.session = session
        return session
    }

    func signOut() async throws {
        session = nil
    }
}
