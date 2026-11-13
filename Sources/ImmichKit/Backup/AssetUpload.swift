import Foundation

/// One file to upload with `POST /assets`. The bytes come from `fileURL` (a staged resource) and are
/// streamed from disk, never held whole in memory.
public struct AssetUploadRequest: Sendable {
    public let fileURL: URL
    public let filename: String
    public let mimeType: String
    /// The SHA1 of the file's bytes, base64. Sent as `x-immich-checksum` so the server can refuse a duplicate early.
    public let checksum: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let isFavorite: Bool
    /// Videos only.
    public let duration: TimeInterval?
    /// The server ID of the motion video, for the photo half of a Live Photo.
    public let livePhotoVideoID: String?
    /// `false` keeps the request off cellular (the system then waits for Wi-Fi or fails).
    public let allowsCellular: Bool

    public init(
        fileURL: URL, filename: String, mimeType: String, checksum: String, createdAt: Date, modifiedAt: Date,
        isFavorite: Bool, duration: TimeInterval?, livePhotoVideoID: String?, allowsCellular: Bool
    ) {
        self.fileURL = fileURL
        self.filename = filename
        self.mimeType = mimeType
        self.checksum = checksum
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isFavorite = isFavorite
        self.duration = duration
        self.livePhotoVideoID = livePhotoVideoID
        self.allowsCellular = allowsCellular
    }
}

public enum AssetUploadStatus: Sendable, Equatable {
    /// The server stored a new asset (HTTP 201).
    case created
    /// The server already had this file (HTTP 200); `id` is the existing asset.
    case duplicate
}

public struct AssetUploadResult: Sendable, Equatable {
    public let id: String
    public let status: AssetUploadStatus

    public init(id: String, status: AssetUploadStatus) {
        self.id = id
        self.status = status
    }
}

/// The server refused this file for a reason retrying won't fix (HTTP 4xx other than 401, 403 and 429).
public enum BackupUploadError: Error, Equatable, Sendable {
    case rejected(status: Int, message: String)
}

/// Writes the `multipart/form-data` body of an upload to a file, so `URLSession` can stream it.
public enum MultipartBody {
    /// How much of the resource is read at a time.
    static let chunkSize = 256 * 1024

    /// Fields first and the file last: the server reads the fields while it receives the file.
    /// Only the fields the upload needs; no `visibility`, `metadata` or `sidecarData`.
    public static func write(_ request: AssetUploadRequest, boundary: String, to url: URL) throws {
        var attributes: [FileAttributeKey: Any]?
        #if os(iOS)
        attributes = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        func field(_ name: String, _ value: String) throws {
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try field("fileCreatedAt", SearchRequestBody.format(request.createdAt))
        try field("fileModifiedAt", SearchRequestBody.format(request.modifiedAt))
        try field("filename", request.filename)
        try field("isFavorite", request.isFavorite ? "true" : "false")
        if let duration = request.duration { try field("duration", durationField(duration)) }
        if let livePhotoVideoID = request.livePhotoVideoID { try field("livePhotoVideoId", livePhotoVideoID) }

        try output.write(contentsOf: Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; "
            + "filename=\"\(headerSafe(request.filename))\"\r\nContent-Type: \(headerSafe(request.mimeType))\r\n\r\n").utf8))
        let input = try FileHandle(forReadingFrom: request.fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// The one place `duration` is encoded. The spec says integer without naming the unit: whole seconds.
    static func durationField(_ duration: TimeInterval) -> String {
        String(max(0, Int(duration.rounded())))
    }

    /// A value inside a quoted header parameter: no line breaks, and `"` as `%22`, so it can't end the
    /// header or add another.
    private static func headerSafe(_ value: String) -> String {
        // By scalar: "\r\n" is a single Character that equals neither "\r" nor "\n".
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
