import Foundation

/// The operations ImmichKit needs from an Immich server.
///
/// `LiveImmichService` talks to a real server; a mock implementation backs tests and previews.
/// More operations are added as features land (timeline, albums, people, search, ...).
public protocol ImmichService: Sendable {
    /// `GET /server/ping`. Returns normally if the server answered `pong`.
    func ping() async throws

    /// `GET /server/version`.
    func serverVersion() async throws -> ServerVersion

    /// `GET /timeline/buckets`: month buckets with asset counts, in `options` order.
    func timeBuckets(options: TimelineOptions) async throws -> [TimeBucket]

    /// `GET /timeline/bucket`: the assets in one month bucket, in `options` order.
    /// - Parameter bucketID: `TimeBucket.id` as returned by `timeBuckets(options:)`.
    func timeBucketAssets(bucketID: String, options: TimelineOptions) async throws -> [Asset]
}

/// Server release version, independent of the generated API types.
public struct ServerVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: Int?
    /// Only reported by newer servers; `nil` if the server does not send it.
    public var featureLevel: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil, featureLevel: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.featureLevel = featureLevel
    }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if let prerelease { text += "-rc\(prerelease)" }
        return text
    }
}

/// Errors surfaced by `ImmichService` implementations. Never contains the API key.
public enum ImmichServiceError: Error, Sendable, Equatable, LocalizedError {
    /// The server URL could not be turned into an API base URL.
    case invalidServerURL
    /// The server rejected the API key (HTTP 401/403).
    case unauthorized
    /// The server answered with an unexpected HTTP status.
    case unexpectedStatus(Int)
    /// The response body did not have the expected shape.
    case invalidResponse
    /// The request did not reach the server (offline, DNS, TLS, timeout, ...).
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The server URL is not valid."
        case .unauthorized:
            return "The server rejected the API key."
        case .unexpectedStatus(let status):
            return "The server answered with HTTP status \(status)."
        case .invalidResponse:
            return "The server sent a response that is not an Immich API response. Check the server URL."
        case .network(let message):
            return "Could not reach the server: \(message)"
        }
    }
}
