import SwiftUI

/// The app's root. Accounts are out of the picture for now — the wardrobe
/// lives entirely on this device — so launch goes straight to the main
/// experience. When sign-in returns (Supabase sync), the session gate goes
/// back here and feature views stay none the wiser.
struct RootView: View {
    var body: some View {
        WardrobeView()
    }
}

#Preview {
    RootView()
        .environment(\.appEnvironment, .preview)
}
