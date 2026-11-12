import Foundation

extension LiveImmichService {
    public func restoreAssets(assetIDs: [String]) async throws -> RestoreResult {
        let ids = try TrashRequestIDs.validated(assetIDs)
        var confirmed: [String] = []
        var failed: [String] = []
        for (index, id) in ids.enumerated() {
            if Task.isCancelled {
                failed.append(contentsOf: ids[index...])
                break
            }
            do {
                let current = try await restoreState(id: id)
                guard current.id == id else { throw ImmichServiceError.invalidResponse }
                // Safe retry of an uncertain result must not send another write unnecessarily.
                if !current.isTrashed {
                    confirmed.append(id)
                    continue
                }
                try Task.checkCancellation()
                let body = try JSONSerialization.data(withJSONObject: ["ids": [id]])
                do {
                    let data = try await rawPOST(path: "/trash/restore/assets", json: body,
                                                 operationID: "restoreAssets", maxBytes: 64 * 1024)
                    let response = try JSONDecoder().decode(RestoreResponse.self, from: data)
                    guard response.count >= 0 else { throw ImmichServiceError.invalidResponse }
                } catch {
                    // A failed response can follow a successful write. Reconcile below without
                    // ever repeating the POST, or relying on count as an identity receipt.
                }
                if let actual = try? await restoreState(id: id), actual.id == id, !actual.isTrashed {
                    confirmed.append(id)
                } else {
                    failed.append(id)
                }
            } catch {
                failed.append(id)
            }
        }
        return RestoreResult(confirmedIDs: confirmed, failedIDs: failed)
    }

    private func restoreState(id: String) async throws -> RestoreAssetState {
        let data = try await rawGET(path: "/assets/\(Self.pathComponent(id))", operationID: "getAssetInfo")
        // General asset compatibility decoding permits omitted flags. Mutation verification
        // requires an explicit state; a missing isTrashed must never become a false success.
        return try JSONDecoder().decode(RestoreAssetState.self, from: data)
    }
}

private struct RestoreResponse: Decodable { let count: Int }
private struct RestoreAssetState: Decodable {
    let id: String
    let isTrashed: Bool
}
