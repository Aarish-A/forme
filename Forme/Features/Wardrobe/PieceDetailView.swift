import CoreGraphics
import SwiftUI

/// A single piece, big enough to see, with the two things anyone actually wants
/// to do to it: fix the category we guessed, or get rid of it.
///
/// Category edits save as they're made rather than behind a Save button. The
/// change is small, reversible and already visible — asking someone to confirm
/// it would imply they'd done something consequential.
struct PieceDetailView: View {
    let piece: Piece
    let image: CGImage?

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var category: Piece.Category
    @State private var isConfirmingRemoval = false

    init(piece: Piece, image: CGImage?) {
        self.piece = piece
        self.image = image
        _category = State(initialValue: piece.category)
    }

    private var store: WardrobeStore {
        environment.wardrobeStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // The store's banner lives in WardrobeView, which is behind
                    // this sheet — a failure that isn't shown here isn't shown.
                    if let errorMessage = store.errorMessage {
                        StatusLabel(.error, errorMessage)
                    }

                    photo
                    categoryPicker
                    removeButton
                }
                .formeScreenPadding()
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.Colors.surface)
            .navigationTitle("Piece")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: category) { _, newCategory in
                Task {
                    await store.updateCategory(newCategory, for: piece)
                    // A failed save must not leave the picker showing a value
                    // the wardrobe doesn't have — roll back so the control
                    // tells the truth. (Re-assigning triggers this handler
                    // again, but the store's no-op guard ends the loop.)
                    let saved = store.pieces.first { $0.id == piece.id }?.category
                    if let saved, saved != newCategory {
                        category = saved
                    }
                }
            }
            .confirmationDialog(
                "Remove this piece?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await store.remove(piece)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It leaves your wardrobe. The photo stays in your photo library.")
            }
        }
    }

    /// Decorative: the category picker below already says what this is, so
    /// VoiceOver announcing it twice would only slow someone down.
    private var photo: some View {
        ZStack {
            Theme.Colors.surfaceSecondary

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.lg)
            } else {
                Image(systemName: category.symbolName)
                    .formeText(.screenTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Theme.Radius.card))
        .accessibilityHidden(true)
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Category")
                .formeText(.sectionTitle)

            Text("Change it if Forme guessed wrong.")
                .formeText(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            Picker("Category", selection: $category) {
                ForEach(Piece.Category.allCases, id: \.self) { option in
                    Label(option.displayName, systemImage: option.symbolName)
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Label("Remove From Wardrobe", systemImage: "trash")
        }
        .buttonStyle(.formeSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    let piece = Piece(
        id: UUID(),
        category: .outerwear,
        imageFileName: "preview-outerwear.png",
        sourceAssetID: nil,
        createdAt: Date()
    )

    PieceDetailView(piece: piece, image: TestImageFactory.image(color: .brown))
        .environment(\.appEnvironment, .preview)
}
