import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// The scan's image work: producing the picture a piece keeps, and the
/// downscaled copies every other stage runs on.
///
/// Separated from the analysis stages because it is the only part of the
/// pipeline that touches UIKit — SwiftUI has no PNG encoder — and because
/// "which pixels do we keep" is a different concern from "is this photo worth
/// keeping at all".
nonisolated extension ScanPipeline {
    /// The image that actually gets stored: the source photo at cutout
    /// resolution, subject lifted onto transparency, aimed at `focus` so a
    /// crowded photo cuts out the right person.
    ///
    /// Every step degrades instead of failing. A cutout that finds no subject
    /// falls back to the whole photo, and a photo that won't reload falls back
    /// to the thumbnail the user already approved — they said yes to something,
    /// so something has to land in their wardrobe.
    ///
    /// `@concurrent` because its caller is the main-actor store: a plain
    /// `nonisolated` async function would run every reload, cutout and PNG
    /// encode on the main thread.
    @concurrent
    static func pieceImagePNG(
        assetID: String,
        fallback: CGImage,
        focus: CGPoint?,
        photoLibrary: any PhotoLibraryService,
        detector: any GarmentDetector
    ) async -> Data? {
        let source = await (try? photoLibrary.loadImage(assetID: assetID, maxPixelSize: cutoutPixelSize)) ?? fallback
        let image = await (try? detector.cutout(from: source, focus: focus)) ?? source

        // UIKit for one line, because SwiftUI has no PNG encoder and this
        // preserves the cutout's alpha channel.
        return UIImage(cgImage: image).pngData()
    }

    /// A display-sized copy of `image`; the original when it's already small
    /// enough or a scaling context can't be made — an oversized thumbnail is a
    /// better failure than a missing one.
    static func downscaled(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }

        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
