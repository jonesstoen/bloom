import Foundation

// Plain domain models used by the rest of ImmichKit and ImmichUI.
// They are independent of the generated `ImmichAPI` types; mapping lives in `DTOMapping.swift`.

/// Pixel dimensions of an asset, already corrected for EXIF orientation where known.
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Width divided by height, or 1 if either side is zero.
    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

/// A photo, video or other media item in the library.
public struct Asset: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case image, video, audio, other
    }

    public var id: String
    public var kind: Kind
    /// The exact moment the photo was taken (UTC). Use for chronological sorting.
    public var takenAt: Date
    /// The wall-clock time where the photo was taken, encoded as if it were UTC.
    /// Group by month/day with a UTC calendar (`Asset.localCalendar`) to get the photographer's local day.
    public var localDateTime: Date
    /// Pixel size, if the server knows it.
    public var size: PixelSize?
    public var isFavorite: Bool
    public var isArchived: Bool
    public var isTrashed: Bool
    /// Video/GIF duration in seconds; `nil` for still images.
    public var duration: TimeInterval?
    /// For a Live Photo, the id of the motion (video) part.
    public var livePhotoVideoId: String?
    public var originalFileName: String?
    public var mimeType: String?
    /// Base64 thumbhash; also used as cache buster for thumbnails.
    public var thumbhash: String?
    /// Only present when fetched through asset info / search responses that include it.
    public var exif: ExifInfo?
    /// Width / height reported by the timeline when the pixel size is unknown.
    public var ratio: Double?

    public init(
        id: String,
        kind: Kind,
        takenAt: Date,
        localDateTime: Date? = nil,
        size: PixelSize? = nil,
        ratio: Double? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        duration: TimeInterval? = nil,
        livePhotoVideoId: String? = nil,
        originalFileName: String? = nil,
        mimeType: String? = nil,
        thumbhash: String? = nil,
        exif: ExifInfo? = nil
    ) {
        self.id = id
        self.kind = kind
        self.takenAt = takenAt
        self.localDateTime = localDateTime ?? takenAt
        self.size = size
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.duration = duration
        self.livePhotoVideoId = livePhotoVideoId
        self.originalFileName = originalFileName
        self.mimeType = mimeType
        self.thumbhash = thumbhash
        self.exif = exif
        self.ratio = ratio
    }

    /// Width divided by height: from `size` if known, else the timeline `ratio`, else 1.
    public var aspectRatio: Double {
        if let size { return size.aspectRatio }
        if let ratio, ratio.isFinite, ratio > 0 { return ratio }
        return 1
    }

    public var isVideo: Bool { kind == .video }
    public var isLivePhoto: Bool { livePhotoVideoId != nil }

    /// Gregorian calendar in UTC, for interpreting `localDateTime`.
    public static let localCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// EXIF metadata for an asset.
public struct ExifInfo: Sendable, Hashable, Codable {
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var fNumber: Double?
    public var focalLength: Double?
    public var iso: Int?
    /// As reported by the server, e.g. `"1/250"`.
    public var exposureTime: String?
    public var dateTimeOriginal: Date?
    public var timeZone: String?
    public var latitude: Double?
    public var longitude: Double?
    public var city: String?
    public var state: String?
    public var country: String?
    public var description: String?
    public var fileSizeInBytes: Int?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var orientation: String?
    public var rating: Int?
    public var projectionType: String?

    public init(
        make: String? = nil, model: String? = nil, lensModel: String? = nil,
        fNumber: Double? = nil, focalLength: Double? = nil, iso: Int? = nil, exposureTime: String? = nil,
        dateTimeOriginal: Date? = nil, timeZone: String? = nil,
        latitude: Double? = nil, longitude: Double? = nil,
        city: String? = nil, state: String? = nil, country: String? = nil,
        description: String? = nil, fileSizeInBytes: Int? = nil,
        imageWidth: Int? = nil, imageHeight: Int? = nil, orientation: String? = nil,
        rating: Int? = nil, projectionType: String? = nil
    ) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.fNumber = fNumber
        self.focalLength = focalLength
        self.iso = iso
        self.exposureTime = exposureTime
        self.dateTimeOriginal = dateTimeOriginal
        self.timeZone = timeZone
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.state = state
        self.country = country
        self.description = description
        self.fileSizeInBytes = fileSizeInBytes
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.orientation = orientation
        self.rating = rating
        self.projectionType = projectionType
    }

    /// `"Apple iPhone 15 Pro"`, de-duplicating the make if the model already contains it.
    public var cameraName: String? {
        switch (make?.nilIfBlank, model?.nilIfBlank) {
        case let (make?, model?):
            return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        case let (make?, nil): return make
        case let (nil, model?): return model
        case (nil, nil): return nil
        }
    }

    /// `"Oslo, Norway"`, or whatever parts are known.
    public var locationName: String? {
        let parts = [city, state, country].compactMap { $0?.nilIfBlank }
        guard !parts.isEmpty else { return nil }
        if parts.count == 3 { return "\(parts[0]), \(parts[2])" }
        return parts.joined(separator: ", ")
    }

    /// True when EXIF orientation means the stored image is rotated 90° (values 5–8).
    var swapsDimensions: Bool {
        guard let orientation, let value = Int(orientation) else { return false }
        return (5...8).contains(value)
    }
}

/// An album.
public struct Album: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var description: String
    public var assetCount: Int
    public var thumbnailAssetId: String?
    /// Date of the oldest and newest asset in the album.
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var isShared: Bool
    /// `true` when the newest assets come first.
    public var isNewestFirst: Bool

    public init(
        id: String, name: String, description: String = "", assetCount: Int,
        thumbnailAssetId: String? = nil, startDate: Date? = nil, endDate: Date? = nil,
        createdAt: Date, updatedAt: Date? = nil, isShared: Bool = false, isNewestFirst: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.assetCount = assetCount
        self.thumbnailAssetId = thumbnailAssetId
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isShared = isShared
        self.isNewestFirst = isNewestFirst
    }
}

/// A recognized person (face cluster).
public struct Person: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// Empty when the person has not been named.
    public var name: String
    /// Date-only birthday (year, month, day), if set.
    public var birthDate: DateComponents?
    public var isHidden: Bool
    public var isFavorite: Bool
    public var updatedAt: Date?

    public init(
        id: String, name: String, birthDate: DateComponents? = nil,
        isHidden: Bool = false, isFavorite: Bool = false, updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.isHidden = isHidden
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
    }

    public var isNamed: Bool { name.nilIfBlank != nil }
}

/// A memory, e.g. "On this day" photos from a given year.
public struct Memory: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        /// Photos taken on this day `year`.
        case onThisDay(year: Int)
        /// A person's birthday memory.
        case birthday(personId: String?, personName: String?, year: Int)
    }

    public var id: String
    public var kind: Kind
    /// The date the memory is about.
    public var memoryAt: Date
    public var showAt: Date?
    public var hideAt: Date?
    public var seenAt: Date?
    public var isSaved: Bool
    public var assets: [Asset]

    public init(
        id: String, kind: Kind, memoryAt: Date, showAt: Date? = nil, hideAt: Date? = nil,
        seenAt: Date? = nil, isSaved: Bool = false, assets: [Asset]
    ) {
        self.id = id
        self.kind = kind
        self.memoryAt = memoryAt
        self.showAt = showAt
        self.hideAt = hideAt
        self.seenAt = seenAt
        self.isSaved = isSaved
        self.assets = assets
    }

    public var year: Int {
        switch kind {
        case .onThisDay(let year), .birthday(_, _, let year): return year
        }
    }

    /// "1 year ago", "5 years ago" relative to `now`'s year.
    public func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        let years = calendar.component(.year, from: now) - year
        switch kind {
        case .birthday(_, let name?, _) where !name.isEmpty:
            return tr("%@'s birthday", name)
        default:
            return years == 1 ? tr("1 year ago") : tr("%lld years ago", Int64(years))
        }
    }
}

/// A geotagged asset on the map.
public struct MapMarker: Sendable, Hashable, Identifiable, Codable {
    /// Asset id.
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var city: String?
    public var state: String?
    public var country: String?

    public init(id: String, latitude: Double, longitude: Double, city: String? = nil, state: String? = nil, country: String? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.state = state
        self.country = country
    }

    public var assetId: String { id }
}
