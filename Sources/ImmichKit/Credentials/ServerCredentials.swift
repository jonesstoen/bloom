import Foundation

/// Server URL plus API key. `description` redacts the key so it never ends up in logs.
public struct ServerCredentials: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The server root as entered by the user, normalized (no trailing slash, no `/api` suffix).
    public var serverURL: URL
    public var apiKey: String

    /// Creates credentials from a user-entered server address.
    ///
    /// Accepts `https://photos.example.com`, `photos.example.com` (https assumed),
    /// `http://192.168.1.10:2283/` and addresses ending in `/api`.
    /// Throws `ImmichServiceError.invalidServerURL` for anything else.
    public init(server: String, apiKey: String) throws {
        guard let url = Self.normalizedServerURL(from: server) else {
            throw ImmichServiceError.invalidServerURL
        }
        self.serverURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(serverURL: URL, apiKey: String) throws {
        try self.init(server: serverURL.absoluteString, apiKey: apiKey)
    }

    /// Base URL for the generated client. Spec paths have no `/api` prefix, so it lives here.
    public var apiBaseURL: URL {
        serverURL.appendingPathComponent("api", isDirectory: false)
    }

    public var description: String {
        "ServerCredentials(serverURL: \(serverURL.absoluteString), apiKey: <redacted>)"
    }

    public var debugDescription: String { description }

    public static func normalizedServerURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              // "https://photos.example.com@evil.com" is the host evil.com; never accept userinfo.
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }
}
