import Foundation
import ImmichAPI
import OpenAPIRuntime

extension LiveImmichService {
    public func smartSearch(_ query: SmartSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        var body = SearchRequestBody(filters: query.filters, size: size)
        body.query = query.text
        body.language = query.language?.nilIfBlank
        // Smart search pages by number only; the request has no cursor field.
        if case .page(let number)? = page { body.page = number }
        let json = try body.json()

        do {
            let dto = try body.decode(Components.Schemas.SmartSearchDto.self, from: json)
            let output = try await Self.mapErrors { try await client.searchSmart(body: .json(dto)) }
            switch output {
            case .ok(let ok):
                guard case .json(let response) = ok.body else { throw ImmichServiceError.invalidResponse }
                return SearchResults(dto: response.assets, preferCursor: false)
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            // Older servers omit asset fields the v3.4.0 spec requires (`isEdited`, `visibility`, ...).
            let data = try await rawPOST(path: "/search/smart", json: json, operationID: Operations.SearchSmart.id)
            return try LenientSearch.results(from: data, preferCursor: false)
        }
    }

    public func metadataSearch(_ query: MetadataSearchQuery, page: SearchPageToken?, size: Int) async throws -> SearchResults {
        var body = SearchRequestBody(filters: query.filters, size: size)
        body.originalFileName = query.originalFileName?.nilIfBlank
        body.description = query.description?.nilIfBlank
        body.order = query.newestFirst ? "desc" : "asc"
        body.withExif = query.withExif ? true : nil
        switch page {
        case .page(let number)?: body.page = number
        case .cursor(let cursor)?: body.cursor = cursor
        case nil: break
        }
        let json = try body.json()

        do {
            let dto = try body.decode(Components.Schemas.MetadataSearchDto.self, from: json)
            let output = try await Self.mapErrors { try await client.searchAssets(body: .json(dto)) }
            switch output {
            case .ok(let ok):
                guard case .json(let response) = ok.body else { throw ImmichServiceError.invalidResponse }
                return SearchResults(dto: response.assets, preferCursor: true)
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            let data = try await rawPOST(path: "/search/metadata", json: json, operationID: Operations.SearchAssets.id)
            return try LenientSearch.results(from: data, preferCursor: true)
        }
    }

    public func searchSuggestions(_ kind: SearchSuggestionKind, context: SearchSuggestionContext) async throws -> [String] {
        let type: Components.Schemas.SearchSuggestionType = switch kind {
        case .country: .country
        case .state: .state
        case .city: .city
        case .cameraMake: .cameraMake
        case .cameraModel: .cameraModel
        case .lensModel: .cameraLensModel
        }
        let query = Operations.GetSearchSuggestions.Input.Query(
            country: context.country, includeNull: false, make: context.make,
            model: context.model, state: context.state, _type: type
        )
        let output = try await Self.mapErrors { try await client.getSearchSuggestions(query: query) }
        switch output {
        case .ok(let ok):
            guard case .json(let values) = ok.body else { throw ImmichServiceError.invalidResponse }
            var seen = Set<String>()
            return values.compactMap(\.nilIfBlank).filter { seen.insert($0).inserted }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }
}

extension SearchResults {
    init(dto: Components.Schemas.SearchAssetResponseDto, preferCursor: Bool) {
        self.init(
            assets: dto.items.map(Asset.init(dto:)),
            total: dto.total,
            // `nextPage` is deprecated in the spec but is the only continuation older servers
            // (and smart search, which has no request cursor) send.
            next: Self.nextToken(cursor: preferCursor ? dto.nextCursor : nil, page: dto.nextPage)
        )
    }
}

/// The JSON body for `/search/smart` and `/search/metadata`, using the flat filter fields
/// (deprecated in v3.4.0 but the only ones older servers accept). The same bytes feed the generated
/// client (decoded into its DTO) and the lenient raw fallback, so both send the identical request.
struct SearchRequestBody: Encodable {
    var query: String?
    var language: String?
    var takenAfter: String?
    var takenBefore: String?
    var city: String?
    var state: String?
    var country: String?
    var make: String?
    var model: String?
    var lensModel: String?
    var personIds: [String]?
    var albumIds: [String]?
    var type: String?
    var isFavorite: Bool?
    var visibility: String?
    var originalFileName: String?
    var description: String?
    var order: String?
    var withExif: Bool?
    var page: Int?
    var cursor: String?
    var size: Int

    init(filters f: SearchFilters, size: Int) {
        self.size = max(1, min(size, 1000))
        takenAfter = f.takenAfter.map(Self.format)
        takenBefore = f.takenBefore.map(Self.format)
        city = f.city?.nilIfBlank
        state = f.state?.nilIfBlank
        country = f.country?.nilIfBlank
        make = f.make?.nilIfBlank
        model = f.model?.nilIfBlank
        lensModel = f.lensModel?.nilIfBlank
        personIds = f.personIds.isEmpty ? nil : f.personIds
        albumIds = f.albumIds.isEmpty ? nil : f.albumIds
        type = f.kind.map { kind in
            switch kind {
            case .image: Components.Schemas.AssetTypeEnum.image.rawValue
            case .video: Components.Schemas.AssetTypeEnum.video.rawValue
            case .audio: Components.Schemas.AssetTypeEnum.audio.rawValue
            case .other: Components.Schemas.AssetTypeEnum.other.rawValue
            }
        }
        isFavorite = f.isFavorite
        visibility = f.visibility.map { LiveImmichService.visibility($0).rawValue }
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do { return try encoder.encode(self) } catch { throw ImmichServiceError.invalidResponse }
    }

    /// Decodes `json` into a generated request DTO.
    func decode<T: Decodable>(_ type: T.Type, from json: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = ImmichDate.parse(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date"))
            }
            return date
        }
        return try decoder.decode(T.self, from: json)
    }

    /// `2024-07-01T10:00:00.000Z`, like the server writes dates.
    static func format(_ date: Date) -> String {
        (try? ISO8601DateTranscoder.iso8601WithFractionalSeconds.encode(date)) ?? ISO8601DateFormatter().string(from: date)
    }
}
