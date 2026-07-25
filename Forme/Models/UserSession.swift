import Foundation

/// The signed-in user, as the app cares about them.
///
/// Deliberately not Supabase's `User` type: keeping our own model at the
/// boundary means swapping or upgrading the backend never ripples into views.
nonisolated struct UserSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let email: String?

    /// What to show when we greet someone. Falls back to the email local part.
    var displayName: String {
        guard let email, let localPart = email.split(separator: "@").first else {
            return "there"
        }
        return String(localPart)
    }
}
