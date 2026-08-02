import Foundation
import PhotosUI
import SwiftUI

/// The wardrobe: everything the user owns, in one grid.
///
/// Two ways in, deliberately unequal. Scanning the photo library is the one we
/// lead with everywhere, because the alternative — photographing a hundred
/// garments — is the reason most people never finish setting up an app like
/// this. Picking from the library is the escape hatch for the odd piece the
/// scan missed.
struct WardrobeView: View {
    @Environment(\.appEnvironment) private var environment

    @State private var isPickingPhotos = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isScanning = false
    @State private var scanStore: ScanStore?
    @State private var selectedPiece: Piece?

    /// Select mode. Held here rather than in the store because it's a property
    /// of this screen, not of the wardrobe: dismissing the view should forget
    /// it, and nothing else in the app has an opinion about it.
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var isConfirmingRemoval = false

    /// The oldest photo any scan has reached, from the persisted watermark.
    /// Nil until the first scan finishes — which is also when "Scan Older
    /// Photos" starts making sense as an offer.
    @State private var scannedThroughDate: Date?

    /// How many picked photos are being loaded and added right now. The picker
    /// dismisses the moment a selection is made, so without visible progress
    /// the first several seconds of a manual add change nothing on screen.
    @State private var addingPhotoCount = 0

    /// Three columns on a standard phone. Below this a cutout stops being
    /// recognisable, which defeats the point of a visual wardrobe.
    private static let minimumTileWidth: CGFloat = 110

    /// Enough for a small manual top-up. Anyone adding more than this wants the
    /// scan, and loading 20 full-size photos is already a slow few seconds.
    private static let maximumPickedPhotos = 20

    private var store: WardrobeStore {
        environment.wardrobeStore
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.minimumTileWidth), spacing: Theme.Spacing.md)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.md) {
                if let errorMessage = store.errorMessage {
                    StatusLabel(.error, errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .formeScreenPadding()
                        .formeTransition(.move(edge: .top).combined(with: .opacity))
                }

                if addingPhotoCount > 0 {
                    addingBanner
                }

                content
            }
            .background(Theme.Colors.surface)
            .animation(Theme.Motion.settle, value: store.pieces)
            .animation(Theme.Motion.tap, value: store.errorMessage)
            .animation(Theme.Motion.tap, value: addingPhotoCount)
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    removalBar
                }
            }
            // After the inset, not before it: an `animation` only reaches the
            // hierarchy beneath it, and the bar sliding in is the change worth
            // animating here.
            .animation(Theme.Motion.tap, value: isSelecting)
            .task {
                await store.refresh()
                await loadScanWatermark()
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $pickedItems,
                maxSelectionCount: Self.maximumPickedPhotos,
                matching: .images
            )
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                pickedItems = []
                Task { await add(items) }
            }
            // A wardrobe that empties out — the whole point of bulk remove —
            // leaves select mode with nothing to select.
            .onChange(of: store.pieces.isEmpty) { _, isEmpty in
                if isEmpty {
                    endSelecting()
                }
            }
            .sheet(item: $selectedPiece) { piece in
                PieceDetailView(piece: piece, image: store.images[piece.id])
            }
            .sheet(isPresented: $isScanning, onDismiss: dismissScan) {
                // Held in state rather than built here: a sheet's content
                // closure runs on every redraw, and a fresh store each time
                // would reset the scan mid-flight.
                if let scanStore {
                    ScanFlowView(store: scanStore)
                }
            }
            .confirmationDialog(
                removalConfirmationTitle,
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task { await removeSelected() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They leave your wardrobe. The photos stay in your photo library.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.pieces.isEmpty {
            grid
        } else if store.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Opening your wardrobe")
        } else {
            emptyState
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ForEach(store.pieces) { piece in
                    Button {
                        tap(piece)
                    } label: {
                        PieceTile(
                            piece: piece,
                            image: store.images[piece.id],
                            selection: PieceTile.Selection(
                                isSelecting: isSelecting,
                                isSelected: selection.contains(piece.id)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.contains(piece.id) ? [.isSelected] : [])
                    .accessibilityHint(isSelecting ? "Selects or deselects this piece." : "Opens details.")
                }
            }
            .formeScreenPadding()
            .padding(.bottom, Theme.Spacing.lg)
        }
        .refreshable { await store.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your wardrobe is empty", systemImage: "hanger")
        } description: {
            Text("Scan your photos and Forme finds the clothes you own — right on your iPhone.")
        } actions: {
            Button("Scan My Photos") { beginScan(mode: .newest) }
                .buttonStyle(.formePrimary)
            Button("Choose From Library") { isPickingPhotos = true }
                .buttonStyle(.formeSecondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEverythingSelected ? "Deselect All" : "Select All", action: toggleSelectAll)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done", action: endSelecting)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
    }

    private var addMenu: some View {
        Menu {
            // The watermark heads the scanning group rather than floating
            // loose: it's the answer to "what would scanning again even do",
            // which is only a question about these two buttons.
            Section {
                Button("Scan My Photos", systemImage: "magnifyingglass") { beginScan(mode: .newest) }

                if let scannedThroughDate {
                    Button("Scan Older Photos", systemImage: "clock.arrow.circlepath") {
                        beginScan(mode: .older(before: scannedThroughDate))
                    }
                }
            } header: {
                if let scannedThroughDate {
                    Text("Scanned back to \(monthAndYear(scannedThroughDate))")
                }
            }

            Button("Choose From Library", systemImage: "photo.on.rectangle") {
                isPickingPhotos = true
            }

            if !store.pieces.isEmpty {
                Button("Select", systemImage: "checkmark.circle") { isSelecting = true }
            }
        } label: {
            Label("Add pieces", systemImage: "plus")
        }
        // While an add is in flight: a second batch on top of a silent
        // first one is how duplicates happen.
        .disabled(addingPhotoCount > 0)
    }

    /// The one action select mode exists for, pinned where a thumb reaches it.
    private var removalBar: some View {
        Button(removalTitle, role: .destructive) { isConfirmingRemoval = true }
            .buttonStyle(.formePrimary)
            .disabled(selection.isEmpty)
            .frame(maxWidth: .infinity)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.sm)
            .background(.bar)
            .formeTransition(.move(edge: .bottom))
    }

    /// Progress for a manual add, shown over the grid and the empty state
    /// alike — `content` only spins when the wardrobe is empty, which tells a
    /// user with existing pieces nothing at all.
    private var addingBanner: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text(addingPhotoCount == 1 ? "Adding 1 photo…" : "Adding \(addingPhotoCount) photos…")
                .formeText(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .formeScreenPadding()
        .formeTransition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Copy

    /// The title carries the count in select mode, so the number of chosen
    /// pieces is readable without hunting for the button at the bottom.
    private var navigationTitle: String {
        guard isSelecting else { return "Wardrobe" }
        return selection.isEmpty ? "Select Pieces" : "\(selection.count) Selected"
    }

    private var removalTitle: String {
        switch selection.count {
        case 0: "Remove Pieces"
        case 1: "Remove 1 Piece"
        default: "Remove \(selection.count) Pieces"
        }
    }

    private var removalConfirmationTitle: String {
        selection.count == 1 ? "Remove 1 piece?" : "Remove \(selection.count) pieces?"
    }

    private func monthAndYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Actions

    private var isEverythingSelected: Bool {
        !store.pieces.isEmpty && selection.count == store.pieces.count
    }

    private func tap(_ piece: Piece) {
        guard isSelecting else {
            selectedPiece = piece
            return
        }

        if selection.contains(piece.id) {
            selection.remove(piece.id)
        } else {
            selection.insert(piece.id)
        }
    }

    private func toggleSelectAll() {
        selection = isEverythingSelected ? [] : Set(store.pieces.map(\.id))
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    private func removeSelected() async {
        let ids = selection
        // Leave select mode first: a grid that keeps its checkmarks while the
        // pieces behind them disappear reads as if the tap didn't take.
        endSelecting()
        await store.remove(ids: ids)
    }

    private func beginScan(mode: ScanStore.ScanMode) {
        scanStore = ScanStore(
            photoLibrary: environment.photoLibrary,
            detector: environment.garmentDetector,
            wardrobe: environment.wardrobe,
            history: environment.scanHistory,
            faceIdentity: environment.faceIdentity,
            faceSeed: environment.faceSeed,
            // Rescanning shouldn't offer back the photos already in the
            // wardrobe — seeing your own clothes presented as new is the kind
            // of small friction that makes an app feel careless.
            existingSourceAssetIDs: Set(store.pieces.compactMap(\.sourceAssetID)),
            mode: mode
        )
        isScanning = true
    }

    /// Any exit from the scan sheet, including a swipe down mid-scan.
    private func dismissScan() {
        // Cancel explicitly: the task driving the scan holds its own strong
        // reference to the store, so dropping ours would leave a dismissed
        // sheet's pipeline running the full library in the background.
        scanStore?.cancelScanning()
        scanStore = nil
        Task {
            await store.refresh()
            // The scan just moved the watermark; the menu should say so
            // without waiting for the screen to be visited again.
            await loadScanWatermark()
        }
    }

    private func loadScanWatermark() async {
        scannedThroughDate = await environment.scanHistory.load()?.oldestScannedDate
    }

    private func add(_ items: [PhotosPickerItem]) async {
        addingPhotoCount = items.count
        defer { addingPhotoCount = 0 }

        var imageDatas: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                imageDatas.append(data)
            }
        }
        await store.addFromPickedImages(imageDatas)
    }
}

#Preview("With pieces") {
    WardrobeView()
        .environment(\.appEnvironment, .preview)
}

#Preview("Empty") {
    WardrobeView()
        .environment(\.appEnvironment, AppEnvironment(auth: InMemoryAuthService()))
}
