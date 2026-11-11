import Foundation

/// Filters shared by smart (CLIP) search and metadata search. `nil` / empty means "any".
///
/// Sent as the flat request fields (`takenAfter`, `city`, `make`, ...). The v3.4.0 spec marks those
/// deprecated in favour of a nested `filter` object, but older servers only understand the flat
/// fields, and v3.4.0 still accepts them.
public struct SearchFilters: Sendable, Hashable, Codable {
    /// Taken at or after this moment.
    public var takenAfter: Date?
    /// Taken at or before this moment.
    public var takenBefore: Date?
    public var city: String?
    public var state: String?
    public var country: String?
    /// Camera make, e.g. `"Apple"`.
    public var make: String?
    /// Camera model, e.g. `"iPhone 15 Pro"`.
    public var model: String?
    public var lensModel: String?
    /// Assets showing all of these people.
    public var personIds: [String]
    /// Assets in all of these albums.
    public var albumIds: [String]
    public var kind: Asset.Kind?
    public var isFavorite: Bool?
    /// `.timeline` (default) hides archived assets, like the Photos app; `nil` searches everything.
    public var visibility: TimelineOptions.Visibility?
    /// `true`: Live Photos only (photos with a motion part).
    public var isMotion: Bool?

    public init(
        takenAfter: Date? = nil, takenBefore: Date? = nil,
        city: String? = nil, state: String? = nil, country: String? = nil,
        make: String? = nil, model: String? = nil, lensModel: String? = nil,
        personIds: [String] = [], albumIds: [String] = [],
        kind: Asset.Kind? = nil, isFavorite: Bool? = nil,
        visibility: TimelineOptions.Visibility? = .timeline,
        isMotion: Bool? = nil
    ) {
        self.takenAfter = takenAfter
        self.takenBefore = takenBefore
        self.city = city
        self.state = state
        self.country = country
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.personIds = personIds
        self.albumIds = albumIds
        self.kind = kind
        self.isFavorite = isFavorite
        self.visibility = visibility
        self.isMotion = isMotion
    }

    /// A filter for the half-open date range `range` (start inclusive, end inclusive to the second before).
    public static func taken(in range: Range<Date>) -> SearchFilters {
        SearchFilters(takenAfter: range.lowerBound, takenBefore: range.upperBound.addingTimeInterval(-0.001))
    }

    /// Whether `asset` passes these filters. Used by the mock; mirrors the server semantics.
    func matches(_ asset: Asset, albumAssetIDs: [String: Set<String>] = [:], personAssetIDs: [String: Set<String>] = [:]) -> Bool {
        if asset.isTrashed { return false }
        switch visibility {
        case .timeline?: if asset.isArchived { return false }
        case .archive?: if !asset.isArchived { return false }
        case nil: break
        }
        if let takenAfter, asset.takenAt < takenAfter { return false }
        if let takenBefore, asset.takenAt > takenBefore { return false }
        if let kind, asset.kind != kind { return false }
        if let isFavorite, asset.isFavorite != isFavorite { return false }
        if let isMotion, (asset.livePhotoVideoId != nil) != isMotion { return false }
        let exif = asset.exif
        for (wanted, actual) in [(city, exif?.city), (state, exif?.state), (country, exif?.country),
                                 (make, exif?.make), (model, exif?.model), (lensModel, exif?.lensModel)] {
            if let wanted, actual != wanted { return false }
        }
        for id in personIds where personAssetIDs[id]?.contains(asset.id) != true { return false }
        for id in albumIds where albumAssetIDs[id]?.contains(asset.id) != true { return false }
        return true
    }
}

/// Smart (CLIP) search: assets ranked by similarity to a natural-language description.
public struct SmartSearchQuery: Sendable, Hashable, Codable {
    /// E.g. `"dog on a beach"`.
    public var text: String
    public var filters: SearchFilters
    /// Language of `text` (e.g. `"nb"`), for servers with a multilingual CLIP model.
    public var language: String?

    public init(text: String, filters: SearchFilters = SearchFilters(), language: String? = nil) {
        self.text = text
        self.filters = filters
        self.language = language
    }
}

/// Metadata search: assets matching the filters, ordered by date.
public struct MetadataSearchQuery: Sendable, Hashable, Codable {
    public var filters: SearchFilters
    /// Substring of the original file name.
    public var originalFileName: String?
    /// Substring of the asset description.
    public var description: String?
    public var newestFirst: Bool
    /// Ask the server to include EXIF in the results.
    public var withExif: Bool

    public init(
        filters: SearchFilters = SearchFilters(),
        originalFileName: String? = nil,
        description: String? = nil,
        newestFirst: Bool = true,
        withExif: Bool = false
    ) {
        self.filters = filters
        self.originalFileName = originalFileName
        self.description = description
        self.newestFirst = newestFirst
        self.withExif = withExif
    }
}

/// Where to continue a search. Opaque to callers: pass `SearchResults.next` back unchanged.
public enum SearchPageToken: Sendable, Hashable, Codable {
    /// Page number (smart search, and metadata search on servers before v3.2.0).
    case page(Int)
    /// Cursor (metadata search on v3.2.0 and later).
    case cursor(String)
}

/// One page of search results.
public struct SearchResults: Sendable, Hashable {
    public var assets: [Asset]
    /// Total matches as reported by the server (deprecated in the spec; may be just this page's count).
    public var total: Int
    /// `nil` when there are no more pages.
    public var next: SearchPageToken?

    public init(assets: [Asset], total: Int? = nil, next: SearchPageToken? = nil) {
        self.assets = assets
        self.total = total ?? assets.count
        self.next = next
    }

    public static let empty = SearchResults(assets: [])

    /// Picks the continuation from a response: the cursor if present, else the page number.
    static func nextToken(cursor: String?, page: String?) -> SearchPageToken? {
        if let cursor = cursor?.nilIfBlank { return .cursor(cursor) }
        if let page = page?.nilIfBlank, let number = Int(page) { return .page(number) }
        return nil
    }
}

/// Fields that `ImmichService.searchSuggestions` can complete, e.g. for filter pickers.
public enum SearchSuggestionKind: String, Sendable, Hashable, CaseIterable, Codable {
    case country
    case state
    case city
    case cameraMake
    case cameraModel
    case lensModel
}

/// Narrows suggestions, e.g. cities in one country or models of one make.
public struct SearchSuggestionContext: Sendable, Hashable, Codable {
    public var country: String?
    public var state: String?
    public var make: String?
    public var model: String?

    public init(country: String? = nil, state: String? = nil, make: String? = nil, model: String? = nil) {
        self.country = country
        self.state = state
        self.make = make
        self.model = model
    }
}
