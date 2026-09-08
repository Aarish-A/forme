import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// How much of the photo library we're allowed to look at.
///
/// Deliberately smaller than `PHAuthorizationStatus`: the app only ever asks
/// "can I read photos, and all of them or some?", so `.restricted` collapses
/// into `.denied` at the service boundary.
nonisolated enum PhotoLibraryAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case limited
    case full
}

/// A photo in the user's library, as the app cares about it. No image bytes —
/// those are loaded on demand and downsampled, because a scan touches thousands
/// of assets and can't hold them.
nonisolated struct PhotoAsset: Identifiable, Sendable, Equatable {
    let id: String
    let creationDate: Date?
    /// PhotoKit's screenshot-exclusion predicate is documented-flaky, so the
    /// flag rides along and the scan filters again in memory.
    var isScreenshot = false
}

/// Read-only access to the photo library.
///
/// Stores depend on this rather than PhotoKit so the scan pipeline can be
/// tested and previewed with scripted assets, offline and without permissions.
nonisolated protocol PhotoLibraryService: Sendable {
    func currentAuthorization() -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    /// Image assets newest-first, taken strictly before `before` when given.
    func imageAssets(before: Date?, limit: Int) async -> [PhotoAsset]
    /// Front-camera (Selfies smart album) assets, newest first.
    func selfieAssets(limit: Int) async -> [PhotoAsset]
    /// Downsampled image for an asset; nil if unavailable. maxPixelSize is
    /// the longest edge.
    func loadImage(assetID: String, maxPixelSize: Int) async throws -> CGImage?
}

// MARK: - In-memory implementation

/// A scripted photo library for previews and tests.
///
/// Authorization lives behind a `Mutex` rather than in actor state because
/// `currentAuthorization()` is synchronous — the UI asks for it while drawing,
/// which can't await.
actor InMemoryPhotoLibraryService: PhotoLibraryService {
    private let authorizationState: Mutex<PhotoLibraryAuthorization>
    private let grantsOnRequest: PhotoLibraryAuthorization
    private let assets: [PhotoAsset]
    private let selfies: [PhotoAsset]
    private let images: [String: CGImage]

    init(
        authorization: PhotoLibraryAuthorization,
        grantsOnRequest: PhotoLibraryAuthorization = .full,
        assets: [PhotoAsset] = [],
        selfies: [PhotoAsset] = [],
        images: [String: CGImage] = [:]
    ) {
        self.authorizationState = Mutex(authorization)
        self.grantsOnRequest = grantsOnRequest
        self.assets = assets.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        self.selfies = selfies.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        self.images = images
    }

    nonisolated func currentAuthorization() -> PhotoLibraryAuthorization {
        authorizationState.withLock { $0 }
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        authorizationState.withLock { state in
            if state == .notDetermined {
                state = grantsOnRequest
            }
            return state
        }
    }

    /// Honors `before` and `limit` like the real service. Screenshots stay in
    /// the result with their flag set — the real predicate excludes them, but
    /// returning them here is what lets tests exercise the store's own
    /// belt-and-braces `isScreenshot` filter.
    func imageAssets(before: Date?, limit: Int) async -> [PhotoAsset] {
        var matched = assets
        if let before {
            matched = matched.filter { asset in
                guard let creationDate = asset.creationDate else { return false }
                return creationDate < before
            }
        }
        return Array(matched.prefix(max(0, limit)))
    }

    func selfieAssets(limit: Int) async -> [PhotoAsset] {
        Array(selfies.prefix(max(0, limit)))
    }

    /// `maxPixelSize` is ignored: the seeded images are already tiny, and the
    /// scan pipeline only cares that it gets *an* image back.
    func loadImage(assetID: String, maxPixelSize _: Int) async throws -> CGImage? {
        images[assetID]
    }

    /// A handful of dated assets with distinct solid-colour images, so a scan
    /// flow previews end to end without touching PhotoKit.
    nonisolated static func previewSeeded(count: Int = 6) -> InMemoryPhotoLibraryService {
        var assets: [PhotoAsset] = []
        var images: [String: CGImage] = [:]

        for index in 0 ..< count {
            let id = "preview-asset-\(index)"
            assets.append(
                PhotoAsset(id: id, creationDate: Date(timeIntervalSinceNow: TimeInterval(-index * 86400)))
            )
            if let image = TestImageFactory.image(color: TestImageFactory.Color.palette(index)) {
                images[id] = image
            }
        }

        return InMemoryPhotoLibraryService(authorization: .full, assets: assets, images: images)
    }
}

// MARK: - Test images

/// Solid-colour `CGImage`s and PNG data, built with CoreGraphics and ImageIO so
/// previews and tests can fabricate images without UIKit or asset files.
nonisolated enum TestImageFactory {
    nonisolated struct Color: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        static let red = Color(red: 0.80, green: 0.24, blue: 0.24)
        static let orange = Color(red: 0.88, green: 0.55, blue: 0.24)
        static let yellow = Color(red: 0.90, green: 0.79, blue: 0.32)
        static let green = Color(red: 0.32, green: 0.62, blue: 0.42)
        static let teal = Color(red: 0.24, green: 0.58, blue: 0.60)
        static let blue = Color(red: 0.27, green: 0.42, blue: 0.72)
        static let purple = Color(red: 0.48, green: 0.36, blue: 0.68)
        static let pink = Color(red: 0.85, green: 0.52, blue: 0.62)
        static let brown = Color(red: 0.47, green: 0.36, blue: 0.28)
        static let gray = Color(red: 0.55, green: 0.55, blue: 0.55)
        static let black = Color(red: 0.10, green: 0.10, blue: 0.10)
        static let white = Color(red: 0.95, green: 0.95, blue: 0.95)

        private static let all: [Color] = [
            .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .brown, .gray, .black, .white
        ]

        /// A distinct colour per index, wrapping around. Keeps seeded fixtures
        /// visually tellable apart without hand-picking colours at each site.
        static func palette(_ index: Int) -> Color {
            all[abs(index) % all.count]
        }
    }

    static func image(color: Color, size: Int = 64) -> CGImage? {
        let edge = max(1, size)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: edge,
                height: edge,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
        context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        return context.makeImage()
    }

    static func png(color: Color, size: Int = 64) -> Data? {
        guard let image = image(color: color, size: size) else { return nil }
        return png(image)
    }

    /// PNG-encodes any `CGImage`, preserving alpha — cutouts are transparent.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
