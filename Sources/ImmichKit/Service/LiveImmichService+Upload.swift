import Foundation

extension LiveImmichService {
    /// The answer to an upload is a few bytes of JSON; anything larger is not an Immich answer.
    static let maxUploadResponseBytes = 64 * 1024

    /// `POST /assets`, streaming the body from a file written next to the resource.
    /// Uses `SameOriginRedirects.session` directly: the generated client would buffer the body.
    public func uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult {
        guard credentials.protectsAPIKey else { throw ImmichServiceError.insecureConnection }
        let boundary = "bloom-\(UUID().uuidString)"
        let bodyFile = request.fileURL.deletingLastPathComponent()
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        // A failure to write is a local disk problem, not a server answer: it keeps its own error.
        try MultipartBody.write(request, boundary: boundary, to: bodyFile)
        try Task.checkCancellation()
        let urlRequest = makeUploadRequest(request, boundary: boundary, bodyFile: bodyFile)
        let (data, response) = try await Self.mapErrors {
            try await SameOriginRedirects.session.upload(for: urlRequest, fromFile: bodyFile)
        }
        guard let http = response as? HTTPURLResponse else { throw ImmichServiceError.invalidResponse }
        return try Self.result(status: http.statusCode, data: data)
    }

    /// `PUT /assets/{photoID}` with only `livePhotoVideoId`: ties the motion video to its photo.
    public func linkLivePhoto(photoID: String, motionID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["livePhotoVideoId": motionID])
        _ = try await rawPUT(path: "/assets/\(Self.pathComponent(photoID))", json: body,
                             operationID: "updateAsset", maxBytes: 4 * 1024 * 1024)
    }

    /// The upload request without its body. The key only goes in the `x-api-key` header.
    func makeUploadRequest(_ request: AssetUploadRequest, boundary: String, bodyFile: URL) -> URLRequest {
        var urlRequest = URLRequest(url: credentials.apiBaseURL.appendingPathComponent("assets", isDirectory: false))
        urlRequest.httpMethod = "POST"
        urlRequest.allowsCellularAccess = request.allowsCellular
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.checksum, forHTTPHeaderField: "x-immich-checksum")
        urlRequest.setValue(credentials.apiKey, forHTTPHeaderField: APIKeyMiddleware.headerName.canonicalName)
        return urlRequest
    }

    /// 201 created and 200 duplicate are both success; the body's `id` is the server asset.
    static func result(status: Int, data: Data) throws -> AssetUploadResult {
        switch status {
        case 200, 201:
            // The cap applies to success bodies only: an oversize error page from a proxy is still
            // reported by its status, not as an invalid response.
            guard data.count <= maxUploadResponseBytes,
                  let body = try? JSONDecoder().decode(UploadResponse.self, from: data), !body.id.isEmpty,
                  let kind = AssetUploadStatus(serverValue: body.status) else {
                throw ImmichServiceError.invalidResponse
            }
            return AssetUploadResult(id: body.id, status: kind)
        case 401, 403:
            throw ImmichServiceError.unauthorized
        case 408, 429:
            // A timeout or rate limit: retried, not a refusal of the file.
            throw ImmichServiceError.unexpectedStatus(status)
        case 400..<500:
            throw BackupUploadError.rejected(status: status, message: serverMessage(in: data))
        default:
            throw ImmichServiceError.unexpectedStatus(status)
        }
    }

    private struct UploadResponse: Decodable {
        let id: String
        let status: String
    }

    /// `message` of an Immich error body: a string, or a list of strings for validation errors.
    private static func serverMessage(in data: Data) -> String {
        guard data.count <= maxUploadResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let message: String
        if let text = object["message"] as? String {
            message = text
        } else if let list = object["message"] as? [String] {
            message = list.joined(separator: "; ")
        } else {
            return ""
        }
        return String(message.prefix(500))
    }
}

private extension AssetUploadStatus {
    init?(serverValue: String) {
        switch serverValue {
        case "created": self = .created
        case "duplicate": self = .duplicate
        default: return nil
        }
    }
}
