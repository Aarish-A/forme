import Foundation
import OSLog
import SwiftUI

/// The app's dependency graph, assembled once at launch.
///
/// Everything the app needs to talk to the outside world hangs off this object,
/// and it reaches views through the SwiftUI environment. Adding a service means
/// adding a stored property here and a line in `live()` and `preview` — no
/// singletons, and nothing a test or preview can't replace.
@Observable
final class AppEnvironment {
    let auth: any AuthService
    let wardrobe: any WardrobeService
    let photoLibrary: any PhotoLibraryService
    let garmentDetector: any GarmentDetector
    let scanHistory: any ScanHistoryService
    let faceIdentity: any FaceIdentityService
    let faceSeed: any FaceSeedService
    let session: SessionStore
    let wardrobeStore: WardrobeStore

    /// The service defaults are offline on purpose: a preview that only cares
    /// about auth shouldn't have to name a wardrobe. `live()` passes them all.
    init(
        auth: any AuthService,
        wardrobe: any WardrobeService = InMemoryWardrobeService(),
        photoLibrary: any PhotoLibraryService = InMemoryPhotoLibraryService(authorization: .notDetermined),
        garmentDetector: any GarmentDetector = StubGarmentDetector(),
        scanHistory: any ScanHistoryService = InMemoryScanHistoryService(),
        faceIdentity: any FaceIdentityService = StubFaceIdentityService(),
        faceSeed: any FaceSeedService = InMemoryFaceSeedService(),
        initialPhase: SessionStore.Phase = .loading
    ) {
        self.auth = auth
        self.wardrobe = wardrobe
        self.photoLibrary = photoLibrary
        self.garmentDetector = garmentDetector
        self.scanHistory = scanHistory
        self.faceIdentity = faceIdentity
        self.faceSeed = faceSeed
        self.session = SessionStore(auth: auth, initialPhase: initialPhase)
        self.wardrobeStore = WardrobeStore(wardrobe: wardrobe, detector: garmentDetector)
    }

    /// The real graph, used by `FormeApp`.
    ///
    /// Falls back to in-memory auth when Supabase isn't configured, so a fresh
    /// clone builds and runs. See `Config/Secrets.example.xcconfig`.
    static func live() -> AppEnvironment {
        let wardrobe = LocalWardrobeService()
        let photoLibrary = PhotoKitLibraryService()
        let garmentDetector = VisionGarmentDetector()
        let scanHistory = DefaultsScanHistoryService()
        let faceIdentity = VisionFaceIdentityService()
        let faceSeed = LocalFaceSeedService()

        guard let config = SupabaseConfig() else {
            Log.app.warning(
                """
                Supabase is not configured — running with in-memory auth. \
                Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig to connect.
                """
            )
            return AppEnvironment(
                auth: InMemoryAuthService(),
                wardrobe: wardrobe,
                photoLibrary: photoLibrary,
                garmentDetector: garmentDetector,
                scanHistory: scanHistory,
                faceIdentity: faceIdentity,
                faceSeed: faceSeed
            )
        }

        Log.app.info("Supabase configured for host \(config.url.host() ?? "unknown", privacy: .public)")
        return AppEnvironment(
            auth: SupabaseAuthService(config: config),
            wardrobe: wardrobe,
            photoLibrary: photoLibrary,
            garmentDetector: garmentDetector,
            scanHistory: scanHistory,
            faceIdentity: faceIdentity,
            faceSeed: faceSeed
        )
    }

    /// A signed-in graph with no network behind it, for `#Preview` blocks.
    static var preview: AppEnvironment {
        let session = UserSession(id: UUID(), email: "sam@example.com")
        return AppEnvironment(
            auth: InMemoryAuthService(session: session),
            wardrobe: InMemoryWardrobeService.previewSeeded(),
            photoLibrary: InMemoryPhotoLibraryService.previewSeeded(),
            garmentDetector: StubGarmentDetector(),
            initialPhase: .signedIn(session)
        )
    }
}

extension EnvironmentValues {
    /// Injected by `FormeApp`; read with `@Environment(\.appEnvironment)`.
    @Entry var appEnvironment: AppEnvironment = .preview
}
