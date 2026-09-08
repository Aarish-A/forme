import CoreGraphics
import Foundation
import os
import Photos
import UIKit

/// The real photo library, behind `PhotoLibraryService`.
///
/// Stateless on purpose: PhotoKit itself is the store and its types are
/// thread-safe, so this is a plain Sendable class rather than an actor —
/// nothing here needs serialising.
final nonisolated class PhotoKitLibraryService: PhotoLibraryService, Sendable {
    func currentAuthorization() -> PhotoLibraryAuthorization {
        Self.authorization(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        await Self.authorization(from: PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// `@concurrent` because the caller is a main-actor store, and under
    /// `NonisolatedNonsendingByDefault` a plain `nonisolated` async method runs
    /// on its caller's actor — enumerating a big library is real work that must
    /// not stall the UI right as the scan starts.
    @concurrent
    func imageAssets(before: Date?, limit: Int) async -> [PhotoAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Don't materialise a 60,000-asset library to hand over a few thousand.
        options.fetchLimit = limit
        // Screenshot exclusion. This exact NOT-form is the one that works;
        // the intuitive `(mediaSubtypes & %d) == 0` form is documented-flaky.
        // The `isScreenshot` flag below is the belt-and-braces for callers.
        var predicates = [
            NSPredicate(
                format: "NOT ((mediaSubtypes & %d) != 0)",
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
        ]
        if let before {
            predicates.append(NSPredicate(format: "creationDate < %@", before as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let fetched = PHAsset.fetchAssets(with: .image, options: options)

        var assets: [PhotoAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            assets.append(Self.photoAsset(from: asset))
        }
        return assets
    }

    /// Selfies come from the system's front-camera smart album rather than a
    /// predicate — PhotoKit already curates it, and it's the same set the
    /// Photos app shows under "Selfies".
    @concurrent
    func selfieAssets(limit: Int) async -> [PhotoAsset] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumSelfPortraits,
            options: nil
        )
        guard let album = collections.firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(in: album, options: options)

        var assets: [PhotoAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            assets.append(Self.photoAsset(from: asset))
        }
        return assets
    }

    private static func photoAsset(from asset: PHAsset) -> PhotoAsset {
        PhotoAsset(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    /// `@concurrent` for the same reason as `imageAssets()`: the asset fetch,
    /// orientation redraw and callers' downstream work must not inherit the
    /// main actor from a main-actor store.
    @concurrent
    func loadImage(assetID: String, maxPixelSize: Int) async throws -> CGImage? {
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else {
            return nil
        }

        let options = PHImageRequestOptions()
        // High-quality delivery hands over the final image in one callback
        // instead of streaming degraded previews first.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let edge = CGFloat(maxPixelSize)
        // One lock owns the request's whole lifecycle. Degraded, error and
        // cancellation deliveries are the classic double-resume trap, so the
        // continuation lives inside the lock and whoever takes it out resumes
        // it — exactly once, whichever of PhotoKit's callback and Swift's
        // cancellation handler gets there first. Cancellation also has to
        // reach PhotoKit itself: an iCloud download would otherwise keep
        // running long after the scan that wanted it was torn down.
        let state = OSAllocatedUnfairLock(initialState: LoadRequestState())
        let image: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = state.withLock { state in
                    guard !state.isCancelled else { return true }
                    state.continuation = continuation
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(returning: nil)
                    return
                }

                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: edge, height: edge),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                        return
                    }
                    let continuation = state.withLock { state in
                        let taken = state.continuation
                        state.continuation = nil
                        return taken
                    }
                    // A nil image here means cancelled or failed — callers
                    // treat nil as "skip this asset", so no error mapping is
                    // needed.
                    continuation?.resume(returning: image)
                }

                // Cancellation may have raced the request starting; if it did,
                // the handler above already resumed and we only need to tell
                // PhotoKit to stop.
                let cancelledMeanwhile = state.withLock { state in
                    state.requestID = requestID
                    return state.isCancelled
                }
                if cancelledMeanwhile {
                    PHImageManager.default().cancelImageRequest(requestID)
                }
            }
        } onCancel: {
            let (continuation, requestID) = state.withLock { state in
                state.isCancelled = true
                let taken = state.continuation
                state.continuation = nil
                return (taken, state.requestID)
            }
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
            continuation?.resume(returning: nil)
        }

        guard let image else { return nil }
        return Self.normalizedCGImage(from: image)
    }

    /// Everything one in-flight `loadImage` needs to resume exactly once and
    /// cancel promptly, guarded by a single lock.
    private struct LoadRequestState {
        var continuation: CheckedContinuation<UIImage?, Never>?
        var requestID: PHImageRequestID?
        var isCancelled = false
    }

    // MARK: - Helpers

    private static func authorization(from status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted, .denied: .denied
        case .limited: .limited
        case .authorized: .full
        @unknown default: .denied
        }
    }

    /// `UIImage.cgImage` is the raw bitmap: portrait photos come back stored
    /// sideways with an orientation flag. Everything downstream (Vision,
    /// thumbnails, saved cutouts) consumes bare `CGImage`s, so bake the
    /// rotation in here, once.
    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return redrawn.cgImage
    }
}
