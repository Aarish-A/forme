import SwiftUI

/// Decides what the app shows based on auth state, and nothing else.
///
/// Keeping this branch in one place means feature views can assume they are
/// only ever rendered for a signed-in user.
struct RootView: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        switch environment.session.phase {
        case .loading:
            LaunchView()
        case .signedOut:
            WelcomeView()
        case .signedIn:
            MainTabView()
        }
    }
}

/// Shown while the persisted session is being restored. Intentionally quiet —
/// a spinner on first launch reads as a problem, a wordmark reads as an app.
private struct LaunchView: View {
    var body: some View {
        Text("Forme")
            .font(Theme.Typography.screenTitle)
            .foregroundStyle(.secondary)
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Wardrobe", systemImage: "hanger") {
                WardrobeView()
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                ProfileView()
            }
        }
    }
}

#Preview("Signed in") {
    RootView()
        .environment(\.appEnvironment, .preview)
}

#Preview("Signed out") {
    RootView()
        .environment(\.appEnvironment, AppEnvironment(auth: InMemoryAuthService()))
}
