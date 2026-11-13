import CoreGraphics
import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class ThumbnailImageCacheTests: XCTestCase {
    func testNormalImageCanBeReadAndRemoved() throws {
        let cache = ThumbnailImageCache(memoryCostLimit: 4096)
        let image = try bitmap(side: 8)
        let key = ImageKey(assetID: "normal", size: .thumbnail)
        cache.insert(image, for: key)
        XCTAssertTrue(cache.image(for: key) === image)
        cache.removeAll()
        XCTAssertNil(cache.image(for: key))
    }

    func testOversizedReplacementIsNotRetainedOrAllowedToEvictOtherImage() throws {
        let cache = ThumbnailImageCache(memoryCostLimit: 2048)
        let small = try bitmap(side: 8)
        let large = try bitmap(side: 32)
        let key = ImageKey(assetID: "replacement", size: .thumbnail)
        let other = ImageKey(assetID: "other", size: .thumbnail)
        cache.insert(small, for: key)
        cache.insert(small, for: other)
        cache.insert(large, for: key)
        XCTAssertNil(cache.image(for: key))
        XCTAssertTrue(cache.image(for: other) === small)
    }

    func testRowPaddingCountsTowardImageCost() throws {
        let image = try bitmap(side: 8, bytesPerRow: 128)
        let unpaddedBytes = image.width * image.height * 4
        XCTAssertGreaterThan(image.bytesPerRow * image.height, unpaddedBytes)
        let cache = ThumbnailImageCache(memoryCostLimit: unpaddedBytes)
        let key = ImageKey(assetID: "padded", size: .thumbnail)
        cache.insert(image, for: key)
        XCTAssertNil(cache.image(for: key))
    }

    func testZeroCostLimitAllowsImagesWithoutByteBudget() throws {
        let cache = ThumbnailImageCache(memoryCostLimit: 0)
        let image = try bitmap(side: 32)
        let key = ImageKey(assetID: "unlimited", size: .thumbnail)
        cache.insert(image, for: key)
        XCTAssertTrue(cache.image(for: key) === image)
    }

    private func bitmap(side: Int, bytesPerRow: Int = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }
}
