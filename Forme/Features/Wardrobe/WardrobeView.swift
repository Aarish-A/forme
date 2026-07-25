import OSLog
import SwiftUI

/// The wardrobe: everything the user owns, ready to be combined into outfits.
///
/// This is the reference feature. New features follow the same shape — a folder
/// under `Features/`, a view that reads services from `\.appEnvironment`, and
/// state that lives in an `@Observable` store once it outgrows `@State`.
struct WardrobeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Your wardrobe is empty", systemImage: "hanger")
            } description: {
                Text("Add the clothes you already own and Forme will start suggesting outfits.")
            } actions: {
                Button("Add an item") {
                    Log.feature.info("Add wardrobe item tapped")
                }
                .buttonStyle(.formePrimary)
            }
            .navigationTitle("Wardrobe")
        }
    }
}

#Preview {
    WardrobeView()
        .environment(\.appEnvironment, .preview)
}
