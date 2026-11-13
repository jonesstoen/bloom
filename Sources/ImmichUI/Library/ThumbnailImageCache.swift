import CoreGraphics
import Foundation
import ImageIO
import ImmichKit

/// Decoded thumbnails for the grid, so a cell scrolling back into view shows its image
/// synchronously instead of flashing a placeholder. `ImageLoader` keeps the encoded bytes.
@MainActor
public final class ThumbnailImageCache {
    private let cache = NSCache<NSString, CGImage>()

    public init(countLimit: Int = 600) {
        cache.countLimit = countLimit
    }

    public func image(for key: ImageKey) -> CGImage? {
        cache.object(forKey: key.description as NSString)
    }

    public func insert(_ image: CGImage, for key: ImageKey) {
        cache.setObject(image, forKey: key.description as NSString)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}

/// Decodes encoded image data (JPEG/WebP/HEIC) off the main actor.
public enum ThumbnailDecoder {
    /// Decodes `data`, downsampling so the long side is at most `maxPixelSize`
    /// (applying the EXIF orientation). `nil` for invalid images or cancelled callers.
    public static func decode(_ data: Data, maxPixelSize: Int = 512) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as CGImage? }
            let image = decodeNow(data, maxPixelSize: maxPixelSize)
            // ImageIO's synchronous decode cannot be interrupted once it has begun.
            return Task.isCancelled ? nil : image
        }
        return await withTaskCancellationHandler {
            let image = await worker.value
            return Task.isCancelled ? nil : image
        } onCancel: {
            worker.cancel()
        }
    }

    static func decodeNow(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
