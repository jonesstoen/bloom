import XCTest
import ImmichKit
@testable import ImmichUI

final class AssetInfoMetadataTests: XCTestCase {
    func testSparseMetadataDoesNotInventValues() {
        let metadata = AssetInfoMetadata(asset: asset(exif: ExifInfo(iso: 100)))
        XCTAssertNil(metadata.caption)
        XCTAssertNil(metadata.fileFormat)
        XCTAssertNil(metadata.dimensions)
        XCTAssertNil(metadata.megapixels)
        XCTAssertNil(metadata.fileSize)
        XCTAssertNil(metadata.camera)
        XCTAssertNil(metadata.location)
    }

    func testPixelSizeIsAvailableWithoutExif() {
        let metadata = AssetInfoMetadata(asset: asset(size: PixelSize(width: 4032, height: 3024)))
        XCTAssertEqual(metadata.dimensions, "4032 × 3024")
        XCTAssertEqual(metadata.megapixels ?? 0, 12.192768, accuracy: 0.000001)
    }

    func testFormatUsesMimeTypeThenFileExtension() {
        var value = asset()
        value.mimeType = "image/heic"
        XCTAssertEqual(AssetInfoMetadata(asset: value).fileFormat, "HEIC")
        value.mimeType = "application/octet-stream"
        value.originalFileName = "IMG_1234.MOV"
        XCTAssertEqual(AssetInfoMetadata(asset: value).fileFormat, "MOV")
        value.originalFileName = "IMG_1234"
        XCTAssertNil(AssetInfoMetadata(asset: value).fileFormat)
    }

    func testBlankCaptionAndLensAreOmitted() {
        let metadata = AssetInfoMetadata(asset: asset(exif: ExifInfo(lensModel: " \n ", description: "\n  ")))
        XCTAssertNil(metadata.caption)
        XCTAssertNil(metadata.lens)
    }

    func testCaptionAndCameraPreserveRealDetails() {
        let metadata = AssetInfoMetadata(asset: asset(exif: ExifInfo(make: "Apple", model: "iPhone 15 Pro", description: "  Summer evening  ", fileSizeInBytes: 2_000_000)))
        XCTAssertEqual(metadata.caption, "Summer evening")
        XCTAssertEqual(metadata.camera, "Apple iPhone 15 Pro")
        XCTAssertNotNil(metadata.fileSize)
    }

    func testInvalidDimensionsAndFileSizeAreOmitted() {
        let metadata = AssetInfoMetadata(asset: asset(size: PixelSize(width: 0, height: 200), exif: ExifInfo(fileSizeInBytes: -1)))
        XCTAssertNil(metadata.dimensions)
        XCTAssertNil(metadata.megapixels)
        XCTAssertNil(metadata.fileSize)
    }

    private func asset(size: PixelSize? = nil, exif: ExifInfo? = nil) -> Asset {
        Asset(id: "info-test", kind: .image, takenAt: Date(timeIntervalSince1970: 0), size: size, exif: exif)
    }
}
