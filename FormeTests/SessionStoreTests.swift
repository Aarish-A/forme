import Foundation
import Testing
@testable import Forme

@Suite("Session store", .serialized)
@MainActor
struct SessionStoreTests {
    @Test("Starts in loading so the UI never flashes a sign-in form")
    func startsLoading() {
        let store = SessionStore(auth: InMemoryAuthService())

        #expect(store.phase == .loading)
        #expect(store.session == nil)
    }

    @Test("Restores a persisted session at launch")
    func restoresExistingSession() async {
        let existing = UserSession(id: UUID(), email: "sam@example.com")
        let store = SessionStore(auth: InMemoryAuthService(session: existing))

        await store.restore()

        #expect(store.phase == .signedIn(existing))
        #expect(store.session == existing)
    }

    @Test("Restoring with no stored session lands on signed out")
    func restoresToSignedOut() async {
        let store = SessionStore(auth: InMemoryAuthService())

        await store.restore()

        #expect(store.phase == .signedOut)
    }

    @Test("A successful sign in exposes the session and clears any error")
    func signInSucceeds() async {
        let store = SessionStore(auth: InMemoryAuthService())

        await store.signIn(email: "sam@example.com", password: "hunter2")

        #expect(store.session?.email == "sam@example.com")
        #expect(store.errorMessage == nil)
    }

    @Test("A failed sign in surfaces a message and leaves the user signed out")
    func signInFailureSurfacesMessage() async {
        let store = SessionStore(auth: InMemoryAuthService())

        await store.signIn(email: "sam@example.com", password: "")

        #expect(store.session == nil)
        #expect(store.errorMessage == AuthError.invalidCredentials.errorDescription)
    }

    @Test("Signing out drops the session")
    func signOutClearsSession() async {
        let store = SessionStore(auth: InMemoryAuthService())
        await store.signIn(email: "sam@example.com", password: "hunter2")

        await store.signOut()

        #expect(store.phase == .signedOut)
        #expect(store.session == nil)
    }
}

@Suite("User session")
struct UserSessionTests {
    @Test("Display name uses the email local part")
    func displayNameFromEmail() {
        let session = UserSession(id: UUID(), email: "sam.jones@example.com")

        #expect(session.displayName == "sam.jones")
    }

    @Test("Display name falls back when there is no email")
    func displayNameFallback() {
        #expect(UserSession(id: UUID(), email: nil).displayName == "there")
        #expect(UserSession(id: UUID(), email: "").displayName == "there")
    }
}
