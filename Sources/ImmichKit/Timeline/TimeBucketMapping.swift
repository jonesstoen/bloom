import Foundation
import ImmichAPI

extension Asset {
    /// Turns the column-oriented `TimeBucketAssetResponseDto` (one array per field) into assets.
    /// Throws `invalidResponse` if the arrays disagree in length or a timestamp cannot be parsed.
    static func assets(from dto: Schemas.TimeBucketAssetResponseDto) throws -> [Asset] {
        let count = dto.id.count
        let required = [
            dto.fileCreatedAt.count, dto.duration.count, dto.isFavorite.count, dto.isImage.count,
            dto.isTrashed.count, dto.livePhotoVideoId.count, dto.localOffsetHours.count,
            dto.ratio.count, dto.thumbhash.count, dto.visibility.count,
        ]
        let optional = [dto.city?.count, dto.country?.count, dto.latitude?.count, dto.longitude?.count]
        guard required.allSatisfy({ $0 == count }), optional.allSatisfy({ $0 == nil || $0 == count }) else {
            throw ImmichServiceError.invalidResponse
        }

        return try (0..<count).map { i in
            guard let takenAt = ImmichDate.parse(dto.fileCreatedAt[i]) else {
                throw ImmichServiceError.invalidResponse
            }
            let offset = dto.localOffsetHours[i]
            let localDateTime = takenAt.addingTimeInterval(offset.isFinite ? offset * 3600 : 0)

            let city = dto.city?[i]?.nilIfBlank
            let country = dto.country?[i]?.nilIfBlank
            let latitude = dto.latitude?[i]
            let longitude = dto.longitude?[i]
            let projection = dto.projectionType[i]?.nilIfBlank
            let hasExif = city != nil || country != nil || latitude != nil || longitude != nil || projection != nil
            let exif = hasExif
                ? ExifInfo(latitude: latitude, longitude: longitude, city: city, country: country, projectionType: projection)
                : nil

            return Asset(
                id: dto.id[i],
                kind: dto.isImage[i] ? .image : .video,
                takenAt: takenAt,
                localDateTime: localDateTime,
                ratio: dto.ratio[i],
                isFavorite: dto.isFavorite[i],
                isArchived: dto.visibility[i] == .archive,
                isTrashed: dto.isTrashed[i],
                duration: seconds(fromMilliseconds: dto.duration[i]),
                livePhotoVideoId: dto.livePhotoVideoId[i]?.nilIfBlank,
                thumbhash: dto.thumbhash[i],
                exif: exif
            )
        }
    }
}

/// Parses the timestamp strings the timeline returns. The spec only says "string"; servers send ISO 8601
/// with `Z` or `+00:00`, with 0–6 fractional digits, sometimes without a zone (taken as UTC).
enum ImmichDate {
    static func parse(_ string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespaces)
        guard text.count >= 19 else { return nil }
        if text.contains(" ") { text = text.replacingOccurrences(of: " ", with: "T") }

        // Split off the fractional seconds, which ISO8601DateFormatter handles poorly beyond 3 digits.
        var fraction: TimeInterval = 0
        let secondsEnd = text.index(text.startIndex, offsetBy: 19)
        if secondsEnd < text.endIndex, text[secondsEnd] == "." {
            var digitsEnd = text.index(after: secondsEnd)
            while digitsEnd < text.endIndex, text[digitsEnd].isASCII, text[digitsEnd].isNumber {
                digitsEnd = text.index(after: digitsEnd)
            }
            fraction = TimeInterval("0" + text[secondsEnd..<digitsEnd]) ?? 0
            text.removeSubrange(secondsEnd..<digitsEnd)
        }
        if text.count == 19 { text += "Z" }

        guard let date = Formatter.shared.date(from: text) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// `ISO8601DateFormatter` is thread-safe for parsing; the wrapper only exists to share one instance.
    private final class Formatter: @unchecked Sendable {
        static let shared = Formatter()
        private let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func date(from string: String) -> Date? { formatter.date(from: string) }
    }
}
