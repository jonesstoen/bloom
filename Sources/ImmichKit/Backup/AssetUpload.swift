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

/// The server refused this file for a reason retrying won't fix (HTTP 4xx other than 401, 403, 408 and 429).
public enum BackupUploadError: Error, Equatable, Sendable {
    case rejected(status: Int, message: String)
}

/// The form fields of one upload (the part of `AssetUploadRequest` that isn't the file or the transport).
public struct MultipartFields: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let isFavorite: Bool
    /// Videos only.
    public let duration: TimeInterval?
    /// The server ID of the motion video, for the photo half of a Live Photo.
    public let livePhotoVideoID: String?
    /// Adds `visibility=hidden`: for a Live Photo's motion half, so it stays out of the timeline
    /// until the photo is linked to it.
    public let hidden: Bool

    public init(
        filename: String, mimeType: String, createdAt: Date, modifiedAt: Date, isFavorite: Bool,
        duration: TimeInterval?, livePhotoVideoID: String?, hidden: Bool
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isFavorite = isFavorite
        self.duration = duration
        self.livePhotoVideoID = livePhotoVideoID
        self.hidden = hidden
    }

    init(_ request: AssetUploadRequest) {
        self.init(
            filename: request.filename, mimeType: request.mimeType, createdAt: request.createdAt,
            modifiedAt: request.modifiedAt, isFavorite: request.isFavorite, duration: request.duration,
            livePhotoVideoID: request.livePhotoVideoID, hidden: false)
    }
}

/// Writes the `multipart/form-data` body of an upload to a file, so `URLSession` can stream it.
public enum MultipartBody {
    /// How much of the resource is read at a time.
    static let chunkSize = 256 * 1024

    /// Only the fields the upload needs; no `metadata` or `sidecarData`, and `visibility` only for a
    /// Live Photo's motion half (see `MultipartFields.hidden`).
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

        try output.write(contentsOf: prefix(MultipartFields(request), boundary: boundary))
        let input = try FileHandle(forReadingFrom: request.fileURL)
        defer { try? input.close() }
        // Each read hands back autoreleased bridged data; without a pool per chunk they pile up toward
        // the size of the file, as nothing drains the pool while this synchronous loop runs.
        var finished = false
        while !finished {
            try autoreleasepool {
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else {
                    finished = true
                    return
                }
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
        }
        try output.write(contentsOf: suffix(boundary: boundary))
    }

    /// Everything before the file's bytes: the form fields, then the header of the `assetData` part.
    /// Fields first and the file last: the server reads the fields while it receives the file.
    static func prefix(_ fields: MultipartFields, boundary: String) -> Data {
        var text = ""
        func field(_ name: String, _ value: String) {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        field("fileCreatedAt", SearchRequestBody.format(fields.createdAt))
        field("fileModifiedAt", SearchRequestBody.format(fields.modifiedAt))
        field("filename", fields.filename)
        field("isFavorite", fields.isFavorite ? "true" : "false")
        if let duration = fields.duration { field("duration", durationField(duration)) }
        if let livePhotoVideoID = fields.livePhotoVideoID { field("livePhotoVideoId", livePhotoVideoID) }
        if fields.hidden { field("visibility", "hidden") }
        text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; "
            + "filename=\"\(headerSafe(fields.filename))\"\r\nContent-Type: \(headerSafe(fields.mimeType))\r\n\r\n"
        return Data(text.utf8)
    }

    /// Everything after the file's bytes.
    static func suffix(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// The one place `duration` is encoded: whole milliseconds, as the spec says ("Duration in
    /// milliseconds (for videos)"), never negative.
    static func durationField(_ duration: TimeInterval) -> String {
        String(max(0, Int((duration * 1000).rounded())))
    }

    /// A value inside a quoted header parameter: no line breaks, `\` as `%5C` and `"` as `%22`, so it
    /// can't end the quoted string, escape its closing quote, or add another header.
    private static func headerSafe(_ value: String) -> String {
        // By scalar: "\r\n" is a single Character that equals neither "\r" nor "\n".
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
