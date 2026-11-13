import Foundation

extension LiveImmichService {
    /// Deprecated in the spec since v3.2.0, but the replacement (`/public/config`) has no flags for
    /// faces or smart search, and v3.3.6 still serves it. Callers treat a failure as "unknown".
    public func serverFeatures() async throws -> ServerFeatures {
        let data = try await rawGET(path: "/server/features", operationID: "getServerFeatures", maxBytes: 64 * 1024)
        do { return try JSONDecoder().decode(ServerFeatures.self, from: data) } catch {
            throw ImmichServiceError.invalidResponse
        }
    }
}
