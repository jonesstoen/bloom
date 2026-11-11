import Foundation
import HTTPTypes
import ImmichAPI
import OpenAPIRuntime
import OpenAPIURLSession

/// `ImmichService` backed by the generated client. Every request carries the API key header.
public struct LiveImmichService: ImmichService {
    public let credentials: ServerCredentials
    let client: Client
    private let transport: any ClientTransport

    /// - Parameter transport: defaults to `URLSessionTransport`; tests inject a stub.
    public init(credentials: ServerCredentials, transport: any ClientTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
        self.client = Client(
            serverURL: credentials.apiBaseURL,
            configuration: Configuration(dateTranscoder: ImmichDateTranscoder()),
            transport: transport,
            middlewares: [APIKeyMiddleware(apiKey: credentials.apiKey), BinaryContentTypeMiddleware()]
        )
    }

    public func ping() async throws {
        let output = try await Self.mapErrors { try await client.pingServer() }
        switch output {
        case .ok(let ok):
            guard case .json(let body) = ok.body, body.res == "pong" else {
                throw ImmichServiceError.invalidResponse
            }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    public func serverVersion() async throws -> ServerVersion {
        do {
            let output = try await Self.mapErrors { try await client.getServerVersion() }
            switch output {
            case .ok(let ok):
                guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
                return ServerVersion(
                    major: dto.major, minor: dto.minor, patch: dto.patch,
                    prerelease: dto.prerelease, featureLevel: dto.featureLevel
                )
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            // The v3.4.0 spec marks `featureLevel` as required, but older servers omit it.
            // Retry with a lenient decoder so those servers still connect.
            return try await lenientServerVersion()
        }
    }

    public func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket] {
        let o = options
        let query = Operations.GetTimeBuckets.Input.Query(
            albumId: o.albumId, isFavorite: o.isFavorite, isTrashed: o.isTrashed,
            order: o.newestFirst ? .desc : .asc, personId: o.personId,
            visibility: o.visibility.map(Self.visibility), withPartners: o.withPartners, withStacked: o.withStacked
        )
        let output = try await Self.mapErrors { try await client.getTimeBuckets(query: query) }
        switch output {
        case .ok(let ok):
            guard case .json(let dtos) = ok.body else { throw ImmichServiceError.invalidResponse }
            return try dtos.map { dto in
                guard let bucket = TimeBucket(key: dto.timeBucket, count: dto.count) else {
                    throw ImmichServiceError.invalidResponse
                }
                return bucket
            }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    public func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset] {
        let o = options
        let query = Operations.GetTimeBucket.Input.Query(
            albumId: o.albumId, isFavorite: o.isFavorite, isTrashed: o.isTrashed,
            order: o.newestFirst ? .desc : .asc, personId: o.personId, timeBucket: bucketID,
            visibility: o.visibility.map(Self.visibility), withPartners: o.withPartners, withStacked: o.withStacked
        )
        let output = try await Self.mapErrors { try await client.getTimeBucket(query: query) }
        switch output {
        case .ok(let ok):
            guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
            return try Asset.assets(from: dto)
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    /// Largest image body accepted from the thumbnail endpoint.
    static let maxImageBytes = 64 * 1024 * 1024

    public func thumbnail(assetID: String, size: ImageSize) async throws -> Data {
        let mediaSize: Components.Schemas.AssetMediaSize = switch size {
        case .thumbnail: .thumbnail
        case .preview: .preview
        }
        let output = try await Self.mapErrors {
            try await client.viewAsset(path: .init(id: assetID), query: .init(size: mediaSize))
        }
        switch output {
        case .ok(let ok):
            guard case .binary(let body) = ok.body else { throw ImmichServiceError.invalidResponse }
            return try await Self.mapErrors { try await Data(collecting: body, upTo: Self.maxImageBytes) }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    // MARK: Albums

    public func albums(shared: Bool?) async throws -> [Album] {
        let output = try await Self.mapErrors { try await client.getAllAlbums(query: .init(isShared: shared)) }
        switch output {
        case .ok(let ok):
            guard case .json(let dtos) = ok.body else { throw ImmichServiceError.invalidResponse }
            return dtos.map(Album.init(dto:))
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    public func album(id: String) async throws -> Album {
        let output = try await Self.mapErrors { try await client.getAlbumInfo(path: .init(id: id)) }
        switch output {
        case .ok(let ok):
            guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
            return Album(dto: dto)
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    // MARK: People

    /// Page size for `GET /people` (spec maximum is 1000).
    static let peoplePageSize = 500
    /// Safety stop in case a server keeps reporting `hasNextPage`.
    static let maxPeoplePages = 100

    public func people(withHidden: Bool) async throws -> [Person] {
        var people: [Person] = []
        var seen = Set<String>()
        for page in 1...Self.maxPeoplePages {
            let (batch, hasNextPage) = try await peoplePage(page, withHidden: withHidden)
            for person in batch where seen.insert(person.id).inserted { people.append(person) }
            if !hasNextPage || batch.isEmpty { break }
        }
        return people
    }

    private func peoplePage(_ page: Int, withHidden: Bool) async throws -> ([Person], Bool) {
        let query = Operations.GetAllPeople.Input.Query(page: page, size: Self.peoplePageSize, withHidden: withHidden)
        do {
            let output = try await Self.mapErrors { try await client.getAllPeople(query: query) }
            switch output {
            case .ok(let ok):
                guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
                return (dto.people.map(Person.init(dto:)), dto.hasNextPage ?? false)
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            // Older servers omit fields the v3.4.0 spec requires (`otherPeople`, `sharedBy`, ...).
            let path = "/people?page=\(page)&size=\(Self.peoplePageSize)&withHidden=\(withHidden)"
            let data = try await rawGET(path: path, operationID: Operations.GetAllPeople.id)
            return try LenientPeople.page(from: data)
        }
    }

    public func person(id: String) async throws -> Person {
        do {
            let output = try await Self.mapErrors { try await client.getPerson(path: .init(id: id)) }
            switch output {
            case .ok(let ok):
                guard case .json(let dto) = ok.body else { throw ImmichServiceError.invalidResponse }
                return Person(dto: dto)
            case .undocumented(let status, _):
                throw Self.error(forStatus: status)
            }
        } catch ImmichServiceError.invalidResponse {
            let path = "/people/\(Self.pathComponent(id))"
            let data = try await rawGET(path: path, operationID: Operations.GetPerson.id)
            return try LenientPeople.person(from: data)
        }
    }

    public func personThumbnail(personID: String) async throws -> Data {
        let output = try await Self.mapErrors { try await client.getPersonThumbnail(path: .init(id: personID)) }
        switch output {
        case .ok(let ok):
            guard case .binary(let body) = ok.body else { throw ImmichServiceError.invalidResponse }
            return try await Self.mapErrors { try await Data(collecting: body, upTo: Self.maxImageBytes) }
        case .undocumented(let status, _):
            throw Self.error(forStatus: status)
        }
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value
    }

    static func visibility(_ value: TimelineOptions.Visibility) -> Components.Schemas.AssetVisibility {
        switch value {
        case .timeline: return .timeline
        case .archive: return .archive
        }
    }

    /// `GET /server/version` decoded into `ServerVersion`, where `featureLevel` is optional.
    private func lenientServerVersion() async throws -> ServerVersion {
        let data = try await rawGET(path: "/server/version", operationID: "getServerVersion", maxBytes: 64 * 1024)
        do {
            return try JSONDecoder().decode(ServerVersion.self, from: data)
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }

    /// A JSON `GET` through the same transport, bypassing the generated decoder.
    /// Used for lenient decoding of responses from servers older than the spec.
    /// - Parameter path: relative to the API base URL, may include a query string.
    func rawGET(path: String, operationID: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        try await rawRequest(method: .get, path: path, json: nil, operationID: operationID, maxBytes: maxBytes)
    }

    /// A JSON `POST` through the same transport, bypassing the generated decoder.
    func rawPOST(path: String, json: Data, operationID: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        try await rawRequest(method: .post, path: path, json: json, operationID: operationID, maxBytes: maxBytes)
    }

    /// A JSON `PUT` through the same transport, bypassing the generated decoder.
    func rawPUT(path: String, json: Data, operationID: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        try await rawRequest(method: .put, path: path, json: json, operationID: operationID, maxBytes: maxBytes)
    }

    private func rawRequest(
        method: HTTPRequest.Method, path: String, json: Data?, operationID: String, maxBytes: Int
    ) async throws -> Data {
        var request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
        request.headerFields[.accept] = "application/json"
        if json != nil { request.headerFields[.contentType] = "application/json; charset=utf-8" }
        request.headerFields[APIKeyMiddleware.headerName] = credentials.apiKey
        let (response, body) = try await Self.mapErrors {
            try await transport.send(
                request, body: json.map { HTTPBody($0) }, baseURL: credentials.apiBaseURL, operationID: operationID
            )
        }
        guard response.status.code == 200 else { throw Self.error(forStatus: response.status.code) }
        guard let body else { throw ImmichServiceError.invalidResponse }
        return try await Self.mapErrors { try await Data(collecting: body, upTo: maxBytes) }
    }

    static func error(forStatus status: Int) -> ImmichServiceError {
        switch status {
        case 401, 403: return .unauthorized
        default: return .unexpectedStatus(status)
        }
    }

    /// Runs `operation` and translates generated-client and transport errors into `ImmichServiceError`.
    static func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as ImmichServiceError {
            throw error
        } catch let error as ClientError {
            throw map(error.underlyingError)
        } catch {
            throw map(error)
        }
    }

    private static func map(_ error: any Error) -> ImmichServiceError {
        switch error {
        case let error as ImmichServiceError:
            return error
        case let error as URLError:
            return .network(error.localizedDescription)
        case is DecodingError:
            return .invalidResponse
        default:
            // Remaining runtime errors are e.g. an unexpected content type
            // (an HTML page instead of JSON, usually a wrong URL).
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return .network(nsError.localizedDescription)
            }
            return .invalidResponse
        }
    }
}
