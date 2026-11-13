import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ImmichKit

/// Talks to a real server. Skips unless `IMMICH_URL` and `IMMICH_API_KEY` are set.
///
/// The uploaded 1×1 PNG stays on the server (the app never deletes): remove it by hand in Immich.
/// Its filename starts with `bloom-upload-test-`.
final class UploadIntegrationTests: XCTestCase {
    private func liveService() throws -> LiveImmichService {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["IMMICH_URL"], !url.isEmpty,
              let key = env["IMMICH_API_KEY"], !key.isEmpty
        else {
            throw XCTSkip("IMMICH_URL and IMMICH_API_KEY not set")
        }
        return LiveImmichService(credentials: try ServerCredentials(server: url, apiKey: key))
    }

    /// A 1×1 PNG with a random pixel, so every run is a file the server has not seen.
    private func randomPNG() throws -> Data {
        var pixel: [UInt8] = [.random(in: 0...255), .random(in: 0...255), .random(in: 0...255), 255]
        let image = try pixel.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let image = context.makeImage()
            else { throw XCTSkip("cannot draw a test image") }
            return image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("cannot encode a test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode a test image") }
        return data as Data
    }

    func testUploadCreatesThenReportsDuplicate() async throws {
        let service = try liveService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UploadIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = try randomPNG()
        let file = directory.appendingPathComponent("resource.png")
        try png.write(to: file)
        var sha = SHA1Stream()
        sha.update(png)
        let now = Date()
        let request = AssetUploadRequest(
            fileURL: file, filename: "bloom-upload-test-\(UUID().uuidString.prefix(8)).png", mimeType: "image/png",
            checksum: sha.base64(), createdAt: now, modifiedAt: now, isFavorite: false, duration: nil,
            livePhotoVideoID: nil, allowsCellular: true)

        let first = try await service.uploadAsset(request)
        XCTAssertEqual(first.status, .created)
        XCTAssertFalse(first.id.isEmpty)

        let second = try await service.uploadAsset(request)
        XCTAssertEqual(second.status, .duplicate)
        XCTAssertEqual(second.id, first.id)

        // The body files are gone; only the resource is left.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["resource.png"])
    }
}
