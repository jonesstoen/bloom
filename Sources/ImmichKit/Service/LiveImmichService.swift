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
            transport: transport,
            middlewares: [APIKeyMiddleware(apiKey: credentials.apiKey)]
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

    private static func visibility(_ value: TimelineOptions.Visibility) -> Components.Schemas.AssetVisibility {
        switch value {
        case .timeline: return .timeline
        case .archive: return .archive
        }
    }

    /// `GET /server/version` decoded into `ServerVersion`, where `featureLevel` is optional.
    private func lenientServerVersion() async throws -> ServerVersion {
        var request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/server/version")
        request.headerFields[.accept] = "application/json"
        request.headerFields[APIKeyMiddleware.headerName] = credentials.apiKey
        let (response, body) = try await Self.mapErrors {
            try await transport.send(
                request, body: nil, baseURL: credentials.apiBaseURL, operationID: "getServerVersion"
            )
        }
        guard response.status.code == 200 else { throw Self.error(forStatus: response.status.code) }
        guard let body else { throw ImmichServiceError.invalidResponse }
        let data = try await Self.mapErrors { try await Data(collecting: body, upTo: 64 * 1024) }
        do {
            return try JSONDecoder().decode(ServerVersion.self, from: data)
        } catch {
            throw ImmichServiceError.invalidResponse
        }
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
