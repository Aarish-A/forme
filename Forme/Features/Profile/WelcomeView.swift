import SwiftUI

/// The signed-out entry point.
///
/// Placeholder for the real onboarding, but wired to the live auth path so the
/// full loop — view to store to service to Supabase — is exercised from day one.
struct WelcomeView: View {
    @Environment(\.appEnvironment) private var environment

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Spacer()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Forme")
                    .formeText(.screenTitle)
                Text("Get dressed with confidence.")
                    .formeText(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(spacing: Theme.Spacing.sm) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage = environment.session.errorMessage {
                StatusLabel(.error, errorMessage)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Button("Sign in") {
                    Task { await submit { await environment.session.signIn(email: email, password: password) } }
                }
                .buttonStyle(.formePrimary)

                Button("Create an account") {
                    Task { await submit { await environment.session.signUp(email: email, password: password) } }
                }
                .buttonStyle(.formeSecondary)
            }
            .frame(maxWidth: .infinity)
            .disabled(isWorking || email.isEmpty || password.isEmpty)

            Spacer()
        }
        .formeScreenPadding()
    }

    private func submit(_ action: () async -> Void) async {
        isWorking = true
        defer { isWorking = false }
        await action()
    }
}

#Preview {
    WelcomeView()
        .environment(\.appEnvironment, AppEnvironment(auth: InMemoryAuthService()))
}
