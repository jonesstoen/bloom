import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Adds the `x-api-key` header (the spec's `api_key` security scheme) to every request.
public struct APIKeyMiddleware: ClientMiddleware {
    public static let headerName = HTTPField.Name("x-api-key")!

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Never put the key on the wire as plain text across the internet.
        guard ServerCredentials.protectsAPIKey(baseURL) else { throw ImmichServiceError.insecureConnection }
        var request = request
        request.headerFields[Self.headerName] = apiKey
        return try await next(request, body, baseURL)
    }
}
