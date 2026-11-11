import Foundation
import HTTPTypes
import ImmichAPI
import OpenAPIRuntime

/// The spec declares the image and video endpoints as `application/octet-stream`, but the server
/// answers with the real media type (`image/jpeg`, `image/webp`, `video/mp4`, ...). The generated
/// client rejects any other content type, so this middleware relabels successful media responses
/// of those operations as `application/octet-stream`. JSON and text bodies (errors, or an HTML page
/// from a wrong URL) are left alone so they still fail as invalid responses.
struct BinaryContentTypeMiddleware: ClientMiddleware {
    static let operationIDs: Set<String> = [
        Operations.ViewAsset.id,
        Operations.DownloadAsset.id,
        Operations.PlayAssetVideo.id,
        Operations.GetPersonThumbnail.id,
    ]

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var (response, responseBody) = try await next(request, body, baseURL)
        if Self.operationIDs.contains(operationID), (200..<300).contains(response.status.code),
           Self.isMedia(response.headerFields[.contentType]) {
            response.headerFields[.contentType] = "application/octet-stream"
        }
        return (response, responseBody)
    }

    /// `true` for a missing content type or any type that is not JSON or text.
    static func isMedia(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces), !type.isEmpty
        else { return true }
        return !(type.hasPrefix("text/") || type == "application/json" || type.hasSuffix("+json"))
    }
}
