import Foundation

/// Which PhotoKit resources of an asset get uploaded. Matches what the Immich app uploads
/// (established by an on-device spike): the edited full-size file when there is one, else the original;
/// for Live Photos the motion part as well.
public enum BackupResourcePolicy {
    public static func upload(from resources: [DeviceResource]) -> [DeviceResource] {
        func first(_ type: DeviceResourceType) -> DeviceResource? { resources.first { $0.type == type } }
        let picks = [
            first(.fullSizePhoto) ?? first(.photo),
            first(.fullSizePairedVideo) ?? first(.pairedVideo),
            first(.fullSizeVideo) ?? first(.video),
        ]
        return picks.compactMap { $0 }
    }
}

/// What the short background refresh may read: small items already on the phone. It never downloads from
/// iCloud (reads are made with `allowNetwork == false`) and never reads a video.
///
/// The limit is a photo and its motion clip by the staging estimates (`BackupStaging.estimate`: 30 MB + 20 MB).
/// A refresh task gets about 30 seconds on battery; a local photo or Live Photo is hashed and staged in about
/// a second, while a video's size has no upper bound (and the estimate for even a short one is 50 MB). Videos,
/// and anything estimated larger, wait for the app or the nightly processing task (on power).
public enum BackupRefreshPolicy {
    public static let maxItemBytes = BackupStaging.photoEstimate + BackupStaging.motionEstimate

    /// Whether a refresh may hash and stage `asset`.
    public static func allows(_ asset: DeviceAsset) -> Bool {
        guard !asset.isVideo else { return false }
        let resources = BackupResourcePolicy.upload(from: asset.resources)
        guard !resources.isEmpty else { return false }
        return resources.reduce(Int64(0)) { $0 + BackupStaging.estimate($1, of: asset) } <= maxItemBytes
    }
}
