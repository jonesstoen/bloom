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
}
