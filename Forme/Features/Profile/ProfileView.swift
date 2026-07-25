import SwiftUI

struct ProfileView: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        NavigationStack {
            List {
                if let session = environment.session.session {
                    Section {
                        LabeledContent("Signed in as", value: session.email ?? "—")
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await environment.session.signOut() }
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    ProfileView()
        .environment(\.appEnvironment, .preview)
}
