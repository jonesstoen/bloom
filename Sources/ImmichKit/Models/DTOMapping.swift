import Foundation
import ImmichAPI

// Mapping from generated API types (`Components.Schemas.*`) to domain models.
// Kept internal so the generated types do not leak into ImmichKit's public API.

typealias Schemas = Components.Schemas

extension Asset.Kind {
    init(_ dto: Schemas.AssetTypeEnum) {
        switch dto {
        case .image: self = .image
        case .video: self = .video
        case .audio: self = .audio
        case .other: self = .other
        }
    }
}

extension Asset {
    init(dto: Schemas.AssetResponseDto) {
        let exif = dto.exifInfo.map(ExifInfo.init(dto:))
        self.init(
            id: dto.id,
            kind: Kind(dto._type),
            takenAt: dto.fileCreatedAt,
            localDateTime: dto.localDateTime,
            size: Self.pixelSize(width: dto.width, height: dto.height, exif: exif),
            isFavorite: dto.isFavorite,
            isArchived: dto.isArchived || dto.visibility == .archive,
            isTrashed: dto.isTrashed,
            duration: Self.seconds(fromMilliseconds: dto.duration),
            livePhotoVideoId: dto.livePhotoVideoId?.nilIfBlank,
            originalFileName: dto.originalFileName,
            mimeType: dto.originalMimeType,
            thumbhash: dto.thumbhash,
            exif: exif
        )
    }

    /// Asset `width`/`height` are already oriented. Fall back to EXIF dimensions, swapped for rotated images.
    static func pixelSize(width: Int?, height: Int?, exif: ExifInfo?) -> PixelSize? {
        if let width, let height, width > 0, height > 0 {
            return PixelSize(width: width, height: height)
        }
        guard let exif, let w = exif.imageWidth, let h = exif.imageHeight, w > 0, h > 0 else { return nil }
        return exif.swapsDimensions ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
    }

    /// The spec reports durations in milliseconds; `nil` or `0` means a still image.
    static func seconds(fromMilliseconds milliseconds: Int?) -> TimeInterval? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return TimeInterval(milliseconds) / 1000
    }
}

extension ExifInfo {
    init(dto: Schemas.ExifResponseDto) {
        self.init(
            make: dto.make,
            model: dto.model,
            lensModel: dto.lensModel,
            fNumber: dto.fNumber,
            focalLength: dto.focalLength,
            iso: dto.iso,
            exposureTime: dto.exposureTime,
            dateTimeOriginal: dto.dateTimeOriginal,
            timeZone: dto.timeZone,
            latitude: dto.latitude,
            longitude: dto.longitude,
            city: dto.city,
            state: dto.state,
            country: dto.country,
            description: dto.description,
            fileSizeInBytes: dto.fileSizeInByte,
            imageWidth: dto.exifImageWidth,
            imageHeight: dto.exifImageHeight,
            orientation: dto.orientation,
            rating: dto.rating,
            projectionType: dto.projectionType
        )
    }
}

extension Album {
    init(dto: Schemas.AlbumResponseDto) {
        self.init(
            id: dto.id,
            name: dto.albumName,
            description: dto.description,
            assetCount: dto.assetCount,
            thumbnailAssetId: dto.albumThumbnailAssetId,
            startDate: dto.startDate,
            endDate: dto.endDate,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            isShared: dto.shared,
            isNewestFirst: dto.order != .asc
        )
    }
}

extension Person {
    init(dto: Schemas.PersonResponseDto) {
        self.init(
            id: dto.id,
            name: dto.name,
            birthDate: dto.birthDate.flatMap(Self.parseBirthDate),
            isHidden: dto.isHidden,
            isFavorite: dto.isFavorite ?? false,
            updatedAt: dto.updatedAt
        )
    }

    /// Parses the spec's date-only `"YYYY-MM-DD"` string (a longer ISO timestamp is accepted too).
    static func parseBirthDate(_ string: String) -> DateComponents? {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

extension Memory {
    init(dto: Schemas.MemoryResponseDto) {
        let kind: Kind
        switch dto._type {
        case .onThisDay:
            kind = .onThisDay(year: dto.data.year)
        case .birthday:
            kind = .birthday(personId: dto.data.personId, personName: dto.data.personName, year: dto.data.year)
        }
        self.init(
            id: dto.id,
            kind: kind,
            memoryAt: dto.memoryAt,
            showAt: dto.showAt,
            hideAt: dto.hideAt,
            seenAt: dto.seenAt,
            isSaved: dto.isSaved,
            assets: dto.assets.map(Asset.init(dto:))
        )
    }
}

extension MapMarker {
    init(dto: Schemas.MapMarkerResponseDto) {
        self.init(
            id: dto.id,
            latitude: dto.lat,
            longitude: dto.lon,
            city: dto.city,
            state: dto.state,
            country: dto.country
        )
    }
}
