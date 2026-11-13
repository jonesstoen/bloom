import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The generated client collects JSON bodies without a limit (`upTo: .max`), so a hostile or
/// broken server could stream an endless body until the app runs out of memory. This middleware
/// collects every non-media response body up to `maxBytes` first and fails with
/// `invalidResponse` beyond it. Media operations already collect with their own limits.
struct ResponseSizeLimitMiddleware: ClientMiddleware {
    let maxBytes: Int

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard let responseBody, !BinaryContentTypeMiddleware.operationIDs.contains(operationID) else {
            return (response, responseBody)
        }
        let data: Data
        do {
            data = try await Data(collecting: responseBody, upTo: maxBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw error
        } catch {
            // Too many bytes (or a body that can't be read): never hand it to the decoder.
            throw ImmichServiceError.invalidResponse
        }
        return (response, HTTPBody(data))
    }
}
