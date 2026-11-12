import Foundation

/// Why a login attempt failed, worded for the login screen. Never contains the API key.
public enum LoginError: Error, Sendable, Equatable, LocalizedError {
    /// The server field is empty.
    case missingServer
    /// The API key field is empty.
    case missingAPIKey
    /// The server address cannot be turned into an http(s) URL.
    case invalidServerURL
    /// The request did not reach the server (offline, DNS, TLS, timeout, ...).
    case serverUnreachable(String)
    /// Something answered, but not an Immich API (wrong URL, wrong port, a web page).
    case notImmichServer
    /// The server is Immich, but it rejected the API key.
    case invalidAPIKey
    /// The server answered with an error status.
    case serverError(Int)
    /// The server redirected to another address, which Bloom doesn't follow (the API key would go along).
    case redirected
    /// Plain http to a host outside the user's own network or Tailscale: the key would travel unencrypted.
    case insecureServer
    /// The connection worked, but the credentials could not be saved to the Keychain.
    case saveFailed

    /// A short headline for an alert or the error row.
    public var title: String {
        switch self {
        case .missingServer, .invalidServerURL: return tr("Invalid Server URL")
        case .missingAPIKey: return tr("API Key Required")
        case .serverUnreachable: return tr("Cannot Connect to Server")
        case .notImmichServer: return tr("Not an Immich Server")
        case .invalidAPIKey: return tr("Wrong API Key")
        case .serverError: return tr("Server Error")
        case .redirected: return tr("Server Redirected")
        case .insecureServer: return tr("Unencrypted Address")
        case .saveFailed: return tr("Could Not Save Login")
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingServer:
            return tr("Enter the address of your Immich server, for example https://photos.example.com.")
        case .missingAPIKey:
            return tr("Enter an API key. Create one on the web under Account Settings › API Keys.")
        case .invalidServerURL:
            return tr("The server address is not a valid URL. Use a form like https://photos.example.com or http://192.168.1.10:2283.")
        case .serverUnreachable(let detail):
            return tr("The server could not be reached. Check the address and your network connection. (%@)", detail)
        case .notImmichServer:
            return tr("The address answered, but it is not an Immich server. Check the URL and port.")
        case .invalidAPIKey:
            return tr("The server rejected the API key. Check that it is correct, has not been deleted, and has access to your library.")
        case .serverError(let status):
            return tr("The server answered with HTTP status %lld. Try again later.", Int64(status))
        case .saveFailed:
            return tr("The connection works, but the login could not be saved to the Keychain.")
        case .insecureServer:
            return tr("Bloom only uses http on your own network or Tailscale. Use https for this server.")
        case .redirected:
            return tr("The server sent Bloom to a different address. Bloom doesn't follow it, so your API key stays with this server. Enter the address the server uses, for example with https://.")
        }
    }

    /// Maps a service error from a request that needs no API key (ping, version).
    static func fromUnauthenticated(_ error: any Error) -> LoginError {
        switch error {
        case let error as LoginError:
            return error
        case ImmichServiceError.invalidServerURL:
            return .invalidServerURL
        case ImmichServiceError.network(let detail):
            return .serverUnreachable(detail)
        case ImmichServiceError.insecureConnection:
            return .insecureServer
        case ImmichServiceError.unexpectedStatus(let status) where (300..<400).contains(status):
            return .redirected
        case ImmichServiceError.unexpectedStatus(let status) where status >= 500:
            return .serverError(status)
        default:
            // 401/403 on an open endpoint, 404 or a non-JSON answer: something else lives at that URL.
            return .notImmichServer
        }
    }

    /// Maps a service error from a request that needs the API key.
    static func fromAuthenticated(_ error: any Error) -> LoginError {
        switch error {
        case ImmichServiceError.unauthorized:
            return .invalidAPIKey
        case ImmichServiceError.unexpectedStatus(let status) where (300..<400).contains(status):
            return .redirected
        case ImmichServiceError.unexpectedStatus(let status) where status < 500:
            return .serverError(status)
        default:
            return fromUnauthenticated(error)
        }
    }
}

/// The outcome of a successful connection test.
public struct ConnectionInfo: Sendable, Hashable {
    public var credentials: ServerCredentials
    public var version: ServerVersion

    public init(credentials: ServerCredentials, version: ServerVersion) {
        self.credentials = credentials
        self.version = version
    }
}

/// Checks a server address and API key before they are saved.
///
/// Ping and version need no key, so after them it loads the album list, which does,
/// to tell a wrong key apart from a wrong URL.
public struct ConnectionTester: Sendable {
    public typealias ServiceFactory = @Sendable (ServerCredentials) -> any ImmichService

    private let makeService: ServiceFactory

    /// - Parameter makeService: builds the service for the entered credentials.
    ///   Defaults to `LiveImmichService`; tests and previews pass a mock.
    public init(makeService: @escaping ServiceFactory = { LiveImmichService(credentials: $0) }) {
        self.makeService = makeService
    }

    /// Validates the input and tests the connection. Throws `LoginError`.
    public func test(server: String, apiKey: String) async throws -> ConnectionInfo {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { throw LoginError.missingServer }
        guard !apiKey.isEmpty else { throw LoginError.missingAPIKey }
        let credentials: ServerCredentials
        do {
            credentials = try ServerCredentials(server: server, apiKey: apiKey)
        } catch {
            throw LoginError.invalidServerURL
        }
        return try await test(credentials)
    }

    /// Tests the connection with already-built credentials. Throws `LoginError`.
    public func test(_ credentials: ServerCredentials) async throws -> ConnectionInfo {
        // Checked before anything is sent: the first request already carries the key.
        guard credentials.protectsAPIKey else { throw LoginError.insecureServer }
        let service = makeService(credentials)
        let version: ServerVersion
        do {
            try await service.ping()
            version = try await service.serverVersion()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LoginError.fromUnauthenticated(error)
        }
        do {
            _ = try await service.albums(shared: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LoginError.fromAuthenticated(error)
        }
        return ConnectionInfo(credentials: credentials, version: version)
    }

    /// Tests the connection and, if it works, saves the credentials in `store`. Throws `LoginError`.
    public func connect(server: String, apiKey: String, store: CredentialStore) async throws -> ConnectionInfo {
        let info = try await test(server: server, apiKey: apiKey)
        do {
            try store.save(info.credentials)
        } catch {
            throw LoginError.saveFailed
        }
        return info
    }
}
