import Foundation

extension LiveImmichService {
    /// `POST /assets/bulk-upload-check`. Batching is the caller's job. Needs `asset.upload`.
    public func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
        guard !items.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: [
            "assets": items.map { ["id": $0.id, "checksum": $0.checksum] },
        ])
        let data = try await rawPOST(path: "/assets/bulk-upload-check", json: body, operationID: "checkBulkUpload")
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw ImmichServiceError.invalidResponse
        }
        return response.results.map {
            BulkUploadCheckResult(
                id: $0.id,
                isDuplicate: $0.action == "reject" && $0.reason == "duplicate",
                serverAssetID: $0.assetId,
                isTrashed: $0.isTrashed ?? false)
        }
    }

    private struct Response: Decodable {
        struct Entry: Decodable {
            let id: String
            let action: String
            let reason: String?
            let assetId: String?
            let isTrashed: Bool?
        }
        let results: [Entry]
    }
}
