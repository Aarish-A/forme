import SwiftUI

@main
struct FormeApp: App {
    /// The single point where the real dependency graph is built. Everything
    /// downstream receives it through the environment, which is what makes
    /// previews and tests able to substitute their own.
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appEnvironment, environment)
                .task {
                    await environment.session.restore()
                }
        }
    }
}
