import Foundation

/// One photo to look up on the server by its SHA1 checksum (`POST /assets/bulk-upload-check`).
public struct BulkUploadCheckItem: Sendable, Hashable {
    /// Chosen by the caller and echoed back, to match results to inputs.
    public let id: String
    /// The SHA1 of the original file, as the server expects it (hex or base64).
    public let checksum: String

    public init(id: String, checksum: String) {
        self.id = id
        self.checksum = checksum
    }
}

/// What the server knows about one `BulkUploadCheckItem`.
public struct BulkUploadCheckResult: Sendable, Equatable {
    public let id: String
    /// The server already has this exact file. Rejections for other reasons (unsupported format) are not duplicates.
    public let isDuplicate: Bool
    /// The existing server asset, for duplicates.
    public let serverAssetID: String?
    /// The existing server asset is in the trash.
    public let isTrashed: Bool

    public init(id: String, isDuplicate: Bool, serverAssetID: String?, isTrashed: Bool) {
        self.id = id
        self.isDuplicate = isDuplicate
        self.serverAssetID = serverAssetID
        self.isTrashed = isTrashed
    }
}
