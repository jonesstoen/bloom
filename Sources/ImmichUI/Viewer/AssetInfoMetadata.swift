import Foundation
import ImmichKit

/// Presentation values shared by the inline information cards. Unknown metadata stays absent.
struct AssetInfoMetadata {
    let asset: Asset
    var caption: String? { nonblank(asset.exif?.description) }
    var filename: String? { nonblank(asset.originalFileName) }
    var camera: String? { asset.exif?.cameraName }
    var lens: String? { nonblank(asset.exif?.lensModel) }
    var location: String? { asset.exif?.locationName }

    var dimensions: String? {
        guard let size = validSize else { return nil }
        return "\(size.width) × \(size.height)"
    }
    var megapixels: Double? {
        guard let size = validSize else { return nil }
        return Double(size.width) * Double(size.height) / 1_000_000
    }
    var fileSize: String? {
        guard let bytes = asset.exif?.fileSizeInBytes, bytes >= 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    var fileFormat: String? {
        let formats = [
            "image/jpeg": "JPEG", "image/heic": "HEIC", "image/heif": "HEIF",
            "image/png": "PNG", "image/gif": "GIF", "image/webp": "WebP",
            "image/tiff": "TIFF", "image/avif": "AVIF", "image/x-adobe-dng": "DNG",
            "video/quicktime": "MOV", "video/mp4": "MP4", "video/webm": "WebM",
            "video/x-matroska": "MKV"
        ]
        if let mime = asset.mimeType?.lowercased().split(separator: ";").first,
           let format = formats[String(mime).trimmingCharacters(in: .whitespaces)] {
            return format
        }
        guard let filename else { return nil }
        let suffix = (filename as NSString).pathExtension
        guard !suffix.isEmpty, suffix.count <= 10,
              suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
        return suffix.uppercased()
    }
    private var validSize: PixelSize? {
        guard let size = asset.size, size.width > 0, size.height > 0 else { return nil }
        return size
    }
    private func nonblank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
