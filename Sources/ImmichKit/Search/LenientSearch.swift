import Foundation

/// Decodes `/search/smart` and `/search/metadata` responses without the asset fields the v3.4.0 spec
/// requires but older servers do not send (`isEdited`, `visibility`, `facets`, `nextCursor`, ...).
/// Used by `LiveImmichService` when the strict generated decoder fails.
enum LenientSearch {
    struct ExifDTO: Decodable {
        var make: String?
        var model: String?
        var lensModel: String?
        var fNumber: Double?
        var focalLength: Double?
        var iso: Int?
        var exposureTime: String?
        var dateTimeOriginal: String?
        var timeZone: String?
        var latitude: Double?
        var longitude: Double?
        var city: String?
        var state: String?
        var country: String?
        var description: String?
        var fileSizeInByte: Int?
        var exifImageWidth: Int?
        var exifImageHeight: Int?
        var orientation: String?
        var rating: Int?
        var projectionType: String?

        var exif: ExifInfo {
            ExifInfo(
                make: make, model: model, lensModel: lensModel,
                fNumber: fNumber, focalLength: focalLength, iso: iso, exposureTime: exposureTime,
                dateTimeOriginal: dateTimeOriginal.flatMap(ImmichDate.parse), timeZone: timeZone,
                latitude: latitude, longitude: longitude, city: city, state: state, country: country,
                description: description, fileSizeInBytes: fileSizeInByte,
                imageWidth: exifImageWidth, imageHeight: exifImageHeight, orientation: orientation,
                rating: rating, projectionType: projectionType
            )
        }
    }

    struct AssetDTO: Decodable {
        var id: String
        var type: String?
        var fileCreatedAt: String?
        var localDateTime: String?
        var width: Int?
        var height: Int?
        var isFavorite: Bool?
        var isArchived: Bool?
        var visibility: String?
        var isTrashed: Bool?
        /// Milliseconds as a number (current servers) or `"H:MM:SS.mmm"` (older servers).
        var duration: Duration?
        var livePhotoVideoId: String?
        var originalFileName: String?
        var originalMimeType: String?
        var thumbhash: String?
        var exifInfo: ExifDTO?

        enum Duration: Decodable {
            case milliseconds(Int)
            case text(String)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    self = .milliseconds(Int(number))
                } else {
                    self = .text(try container.decode(String.self))
                }
            }

            var seconds: TimeInterval? {
                switch self {
                case .milliseconds(let ms): return Asset.seconds(fromMilliseconds: ms)
                case .text(let text): return LenientSearch.seconds(fromClock: text)
                }
            }
        }

        func asset() throws -> Asset {
            guard let takenAt = fileCreatedAt.flatMap(ImmichDate.parse) else {
                throw ImmichServiceError.invalidResponse
            }
            let exif = exifInfo?.exif
            return Asset(
                id: id,
                kind: Asset.Kind(rawValue: (type ?? "").lowercased()) ?? .other,
                takenAt: takenAt,
                localDateTime: localDateTime.flatMap(ImmichDate.parse),
                size: Asset.pixelSize(width: width, height: height, exif: exif),
                isFavorite: isFavorite ?? false,
                isArchived: (isArchived ?? false) || visibility == "archive",
                isTrashed: isTrashed ?? false,
                duration: duration?.seconds,
                livePhotoVideoId: livePhotoVideoId?.nilIfBlank,
                originalFileName: originalFileName,
                mimeType: originalMimeType,
                thumbhash: thumbhash,
                exif: exif
            )
        }
    }

    struct AssetsDTO: Decodable {
        var items: [AssetDTO]
        var total: Int?
        var nextPage: String?
        var nextCursor: String?
    }

    struct ResponseDTO: Decodable {
        var assets: AssetsDTO
    }

    static func results(from data: Data, preferCursor: Bool) throws -> SearchResults {
        do {
            let response = try JSONDecoder().decode(ResponseDTO.self, from: data).assets
            return SearchResults(
                assets: try response.items.map { try $0.asset() },
                total: response.total,
                next: SearchResults.nextToken(cursor: preferCursor ? response.nextCursor : nil, page: response.nextPage)
            )
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }

    /// `"0:01:23.456"` → 83.456 seconds; `nil` for zero or unparseable values.
    static func seconds(fromClock text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = TimeInterval(part) else { return nil }
            total = total * 60 + value
        }
        return total > 0 ? total : nil
    }
}
