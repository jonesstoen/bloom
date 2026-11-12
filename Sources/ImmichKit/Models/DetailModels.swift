import Foundation

/// Filters for `ImmichService.mapMarkers(_:)` (`GET /map/markers`).
public struct MapMarkerOptions: Sendable, Hashable {
    /// `true` also includes archived assets; `nil`/`false` only the main timeline.
    public var includeArchived: Bool?
    /// `true` only favorites, `false` only non-favorites, `nil` both.
    public var isFavorite: Bool?
    /// Only assets taken at or after this moment.
    public var takenAfter: Date?
    /// Only assets taken at or before this moment.
    public var takenBefore: Date?
    public var withPartners: Bool?
    public var withSharedAlbums: Bool?

    public init(
        includeArchived: Bool? = nil, isFavorite: Bool? = nil,
        takenAfter: Date? = nil, takenBefore: Date? = nil,
        withPartners: Bool? = nil, withSharedAlbums: Bool? = nil
    ) {
        self.includeArchived = includeArchived
        self.isFavorite = isFavorite
        self.takenAfter = takenAfter
        self.takenBefore = takenBefore
        self.withPartners = withPartners
        self.withSharedAlbums = withSharedAlbums
    }

    /// True when `asset` passes these filters (the mock uses the same rules as the server).
    func matches(_ asset: Asset) -> Bool {
        if asset.isTrashed { return false }
        if asset.isArchived, includeArchived != true { return false }
        if let isFavorite, asset.isFavorite != isFavorite { return false }
        if let takenAfter, asset.takenAt < takenAfter { return false }
        if let takenBefore, asset.takenAt > takenBefore { return false }
        return true
    }
}

/// Filters for `ImmichService.memories(_:)` (`GET /memories`).
public struct MemoryQuery: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case onThisDay = "on_this_day"
        case birthday
    }

    /// Only memories shown on this calendar day (`year`, `month`, `day`); `nil` for all memories.
    public var day: DateComponents?
    public var isSaved: Bool?
    public var kind: Kind?

    public init(day: DateComponents? = nil, isSaved: Bool? = nil, kind: Kind? = nil) {
        self.day = day
        self.isSaved = isSaved
        self.kind = kind
    }

    /// The memories to show on `date`'s day in `calendar` (the user's local day by default).
    public static func shown(on date: Date, calendar: Calendar = .current) -> MemoryQuery {
        MemoryQuery(day: calendar.dateComponents([.year, .month, .day], from: date))
    }

    /// `day` as the spec's `YYYY-MM-DD` date string, or `nil` if it is incomplete.
    var dayString: String? {
        guard let day, let year = day.year, let month = day.month, let dayOfMonth = day.day,
              (1...12).contains(month), (1...31).contains(dayOfMonth)
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }

    /// `day` as midnight UTC, which is how the server compares it with `showAt`/`hideAt`.
    var dayStart: Date? {
        guard let day, let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        return Asset.localCalendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
    }

    func matches(_ memory: Memory) -> Bool {
        if let isSaved, memory.isSaved != isSaved { return false }
        if let kind {
            switch (kind, memory.kind) {
            case (.onThisDay, .onThisDay), (.birthday, .birthday): break
            default: return false
            }
        }
        if let start = dayStart {
            if let showAt = memory.showAt, showAt > start { return false }
            if let hideAt = memory.hideAt, hideAt <= start { return false }
        }
        return true
    }
}

/// An authenticated HTTP request for media that should be streamed rather than loaded into memory,
/// such as a video for `AVPlayer` or a large original.
///
/// Carries the API key header, so `description` redacts header values. Never log `headers`.
public struct MediaRequest: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `GET /assets/{id}/original`: the original file as uploaded.
        case original
        /// `GET /assets/{id}/video/playback`: the (transcoded) video stream, supports range requests.
        case videoPlayback
    }

    public var kind: Kind
    public var assetID: String
    public var url: URL
    /// Headers to send with the request (the API key for a live server).
    public var headers: [String: String]

    public init(kind: Kind, assetID: String, url: URL, headers: [String: String] = [:]) {
        self.kind = kind
        self.assetID = assetID
        self.url = url
        self.headers = headers
    }

    /// A `URLRequest` with `headers` set, for `URLSession` downloads.
    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Options for `AVURLAsset(url:options:)` so AVFoundation sends the headers with every
    /// (range) request: `AVURLAsset(url: request.url, options: request.avURLAssetOptions)`.
    public var avURLAssetOptions: [String: Any] {
        headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    public var description: String {
        let names = headers.keys.sorted().map { "\($0): <redacted>" }.joined(separator: ", ")
        return "MediaRequest(\(kind.rawValue), \(url.absoluteString)\(names.isEmpty ? "" : ", headers: [\(names)]"))"
    }

    public var debugDescription: String { description }
}
