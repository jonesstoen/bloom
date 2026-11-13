import Foundation

/// The Immich API key permissions Bloom needs. A key with only these (instead of "all") limits
/// what a leaked key can do: a read-only key can't delete, edit or share anything.
/// `APIKeyPermissionTests` checks every operation Bloom calls against the OpenAPI spec.
public enum APIKeyPermissions {
    /// Browsing, search, map, memories, playing videos and sharing originals.
    public static let readOnly = [
        "asset.read", "asset.view", "asset.download", "album.read", "person.read", "map.read", "memory.read",
    ]

    /// Added for Allow Changes: favorites, moving to and restoring from trash, new albums and adding to them.
    public static let changes = ["asset.update", "asset.delete", "album.create", "albumAsset.create"]

    /// Added for backing up this iPhone: uploading, and asking the server which photos it already has.
    public static let backup = ["asset.upload"]
}

/// The access a user chooses to give Bloom when creating the key. New levels (for example
/// backing up) add their permissions here, and the sign-in screen lists them.
public enum APIKeyAccess: String, CaseIterable, Identifiable, Sendable {
    /// Browse, search, play and share. The key can't change anything on the server.
    case view
    /// Also favorites, moving to and restoring from trash, and albums (with Allow Changes).
    case organize
    /// Also uploading photos from this iPhone.
    case backup

    public var id: String { rawValue }

    public var permissions: [String] {
        switch self {
        case .view: APIKeyPermissions.readOnly
        case .organize: APIKeyPermissions.readOnly + APIKeyPermissions.changes
        case .backup: APIKeyPermissions.readOnly + APIKeyPermissions.changes + APIKeyPermissions.backup
        }
    }
}
