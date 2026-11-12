import Foundation

extension LiveImmichService {
    public func moveToTrash(assetIDs: [String]) async throws -> TrashResult {
        let ids = try TrashRequestIDs.validated(assetIDs)
        guard !ids.isEmpty else { return TrashResult(confirmedIDs: [], failedIDs: []) }
        try Task.checkCancellation()
        // Never promise recovery when trash is disabled or has no retention period.
        let features = try await rawGET(path: "/server/features", operationID: "getServerFeatures", maxBytes: 64 * 1024)
        guard let flags = try? JSONDecoder().decode(TrashFeatures.self, from: features), flags.trash else {
            throw TrashError.unavailable
        }
        let config = try await rawGET(path: "/server/config", operationID: "getServerConfig", maxBytes: 64 * 1024)
        guard let policy = try? JSONDecoder().decode(TrashConfig.self, from: config), policy.trashDays > 0 else {
            throw TrashError.unavailable
        }
        try Task.checkCancellation()
        var confirmed: [String] = []
        var failed: [String] = []
        for (index, id) in ids.enumerated() {
            if Task.isCancelled {
                failed.append(contentsOf: ids[index...])
                break
            }
            do {
                let current = try await asset(id: id)
                guard current.id == id else { throw ImmichServiceError.invalidResponse }
                // An earlier response may have been lost. Avoid resetting its trash date.
                if current.isTrashed {
                    confirmed.append(id)
                    continue
                }
                try Task.checkCancellation()
                let body = try JSONSerialization.data(withJSONObject: ["ids": [id], "force": false])
                do {
                    try await sendTrashRequest(json: body)
                    // An accepted write must be recorded even if cancellation arrived meanwhile.
                    confirmed.append(id)
                } catch {
                    // A lost response does not prove the write failed. Read once; never resend.
                    if let actual = try? await asset(id: id), actual.id == id, actual.isTrashed {
                        confirmed.append(id)
                    } else {
                        failed.append(id)
                    }
                }
            } catch {
                failed.append(id)
            }
        }
        return TrashResult(confirmedIDs: confirmed, failedIDs: failed)
    }
}

private struct TrashFeatures: Decodable { let trash: Bool }
private struct TrashConfig: Decodable { let trashDays: Int }
