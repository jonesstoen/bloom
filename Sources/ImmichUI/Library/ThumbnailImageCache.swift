import CoreGraphics
import Foundation
import ImageIO
import ImmichKit

/// Decoded thumbnails for the grid, so a cell scrolling back into view shows its image
/// synchronously instead of flashing a placeholder. `ImageLoader` keeps the encoded bytes.
@MainActor
public final class ThumbnailImageCache {
    private let cache = NSCache<NSString, CGImage>()
    private let memoryCostLimit: Int

    /// The byte budget is an eviction hint for decoded buffers, not a hard limit on app memory.
    /// A nonpositive `memoryCostLimit` disables the byte budget.
    public init(countLimit: Int = 600, memoryCostLimit: Int = 96 * 1024 * 1024) {
        self.memoryCostLimit = max(0, memoryCostLimit)
        cache.countLimit = countLimit
        cache.totalCostLimit = self.memoryCostLimit
    }

    public func image(for key: ImageKey) -> CGImage? {
        cache.object(forKey: key.description as NSString)
    }

    public func insert(_ image: CGImage, for key: ImageKey) {
        let cacheKey = key.description as NSString
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        // An oversized image can still be displayed by its cell without evicting useful thumbnails.
        guard !overflow, memoryCostLimit == 0 || cost <= memoryCostLimit else {
            cache.removeObject(forKey: cacheKey)
            return
        }
        cache.setObject(image, forKey: cacheKey, cost: cost)
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
